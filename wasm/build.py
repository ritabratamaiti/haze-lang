"""
Builds Haze for WebAssembly, for the playground on the website.

Lean doesn't publish a WebAssembly build of its runtime and standard library any more, so this
script builds the pieces itself:

1. It finds every module that `Haze.Web` depends on, including the modules of Lean's `Init` and
   `Std` libraries.
2. It generates C for the `Init` and `Std` modules with the native Lean compiler, from the sources
   that ship with the toolchain, and takes Haze's own C from `lake build`.
3. It compiles Lean's runtime (fetched at the matching version) with Emscripten in its
   `LEAN_EMSCRIPTEN` configuration, single-threaded and without GMP or mimalloc. Without the task
   manager, `Task.spawn` runs its work immediately, so Haze needs no threads in the browser.
4. It links everything with a small C shim (`shim.c`) into `haze.mjs` and `haze.wasm`.

Every step is cached in `wasm/.cache`, so rebuilding after a change to Haze is quick. Run it from
the repository root after `lake build`, with Emscripten's `emcc` on the PATH:

    python wasm/build.py [--out site/public/engine] [--jobs N]
"""
import argparse, concurrent.futures as cf, json, os, pathlib, re, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HERE = ROOT / "wasm"
CACHE = HERE / ".cache"


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", **kw)
    if r.returncode != 0:
        raise RuntimeError(f"command failed ({r.returncode}): {' '.join(map(str, cmd))[:300]}\n{r.stdout[-3000:]}\n{r.stderr[-3000:]}")
    return r.stdout


def toolchain():
    prefix = pathlib.Path(run(["lean", "--print-prefix"], cwd=ROOT).strip())
    version = re.search(r"version (\d+\.\d+\.\d+)", run(["lean", "--version"], cwd=ROOT)).group(1)
    return prefix, version


def emcc_cmd(cxx=False):
    exe = shutil.which("em++" if cxx else "emcc")
    if not exe:
        sys.exit("emcc isn't on the PATH; install Emscripten (emsdk) and activate it first")
    # call the Python script directly: on Windows, emcc is a batch file that mangles arguments
    script = pathlib.Path(exe).with_name("em++.py" if cxx else "emcc.py")
    return [sys.executable, str(script)] if script.exists() else [exe]


# ---- 1. modules ------------------------------------------------------------------------------
IMPORT = re.compile(r"^\s*(?:public\s+)?(?:meta\s+)?import\s+(?:all\s+)?(.*)$")


def source_of(module, prefix):
    base = ROOT if module.split(".")[0] == "Haze" else prefix / "src" / "lean"
    return base / (module.replace(".", "/") + ".lean")


def imports(path):
    out, prelude, depth = [], False, 0
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.split("--")[0].strip() if depth == 0 else line.strip()
        if depth:
            depth += s.count("/-") - s.count("-/")
            continue
        if s.startswith("/-"):
            depth = s.count("/-") - s.count("-/")
            continue
        if not s or s == "module":
            continue
        if s == "prelude":
            prelude = True
            continue
        m = IMPORT.match(s)
        if not m:
            break
        out += m.group(1).split()
    return out if prelude else out + ["Init"]


def closure(root, prefix):
    seen, stack = set(), [root]
    while stack:
        m = stack.pop()
        if m not in seen:
            seen.add(m)
            stack += imports(source_of(m, prefix))
    return sorted(seen)


# ---- 2. C sources ----------------------------------------------------------------------------
def library_c(module, prefix, version):
    """Generates the C for a module of Lean's own libraries, once per toolchain version."""
    out = CACHE / f"c-{version}" / f"{module}.c"
    if not out.exists():
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_suffix(".tmp")
        env = dict(os.environ, LEAN_PATH=str(prefix / "lib" / "lean"))
        run([str(prefix / "bin" / "lean"), "-R", str(prefix / "src" / "lean"), "-c", str(tmp),
             str(source_of(module, prefix))], env=env)
        tmp.replace(out)
    return out


def haze_c(module):
    path = ROOT / ".lake" / "build" / "ir" / (module.replace(".", "/") + ".c")
    if not path.exists():
        sys.exit(f"{path} is missing; run `lake build` first")
    return path


# ---- 3. the runtime --------------------------------------------------------------------------
RUNTIME = """debug thread mpz utf8 object apply exception interrupt memory stackinfo compact init_module
io hash byteslice platform alloc allocprof sharecommon stack_overflow process object_ref mpn mutex
libuv uv/net_addr uv/event_loop uv/timer uv/tcp uv/udp uv/dns uv/system uv/signal openssl""".split()


def lean_source(version):
    src = CACHE / f"lean4-{version}"
    if not (src / "src" / "runtime" / "object.cpp").exists():
        shutil.rmtree(src, ignore_errors=True)
        run(["git", "clone", "--quiet", "--depth", "1", "--branch", f"v{version}", "--filter=blob:none",
             "--sparse", "https://github.com/leanprover/lean4.git", str(src)])
        run(["git", "sparse-checkout", "set", "--no-cone", "/src/runtime/", "/src/include/", "/src/util/"], cwd=src)
    return src


LIBUV_VERSION = "v1.51.0"

# Lean's WebAssembly configuration hasn't been built since Lean 4.15, and a few of its stubs no
# longer match their declarations. These edits fix them in the cached copy of the runtime.
RUNTIME_FIXES = [
    ("runtime/uv/system.cpp", "lean_uv_os_get_group() {", "lean_uv_os_get_group(uint64_t gid) {"),
]


def include_dir(prefix, version):
    """The toolchain's headers, with a `config.h` for the WebAssembly build (no mimalloc), a
    `githash.h`, and libuv's headers, which `io.cpp` includes even when libuv isn't used."""
    inc = CACHE / "include"
    (inc / "lean").mkdir(parents=True, exist_ok=True)
    for h in (prefix / "include" / "lean").iterdir():
        if h.name != "config.h":
            shutil.copy2(h, inc / "lean" / h.name)
    (inc / "lean" / "config.h").write_text(
        "#pragma once\n#include <lean/version.h>\n#define LEAN_IS_STAGE0 0\n", encoding="utf-8")
    (inc / "githash.h").write_text(f'#define LEAN_GITHASH "v{version}"\n', encoding="utf-8")
    uv = CACHE / f"libuv-{LIBUV_VERSION}"
    if not (uv / "include" / "uv.h").exists():
        shutil.rmtree(uv, ignore_errors=True)
        run(["git", "clone", "--quiet", "--depth", "1", "--branch", LIBUV_VERSION, "--filter=blob:none",
             "--sparse", "https://github.com/libuv/libuv.git", str(uv)])
        run(["git", "sparse-checkout", "set", "--no-cone", "/include/"], cwd=uv)
    return [inc, uv / "include"]


def fix_runtime(src):
    for rel, old, new in RUNTIME_FIXES:
        f = src / "src" / rel
        text = f.read_text(encoding="utf-8")
        if old in text:
            f.write_text(text.replace(old, new), encoding="utf-8")


COMMON = ["-O2", "-DNDEBUG", "-DLEAN_EMSCRIPTEN", "-fwasm-exceptions"]


def compile_one(src, obj, cxx, includes):
    if obj.exists() and obj.stat().st_mtime >= src.stat().st_mtime:
        return obj
    obj.parent.mkdir(parents=True, exist_ok=True)
    flags = COMMON + [f"-I{i}" for i in includes]
    if cxx:
        # the single-threaded runtime uses std::adopt_lock_t without including <mutex>
        flags += ["-std=c++20", "-DLEAN_EXPORTING", "-Wno-deprecated-declarations", "-include", "mutex"]
    else:
        flags += ["-Wno-unused-label", "-Wno-unused-but-set-variable", "-Wno-unused-parameter"]
    try:
        run(emcc_cmd(cxx) + flags + ["-c", str(src), "-o", str(obj)])
    except RuntimeError as e:
        return e
    return obj


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", default=str(ROOT / "site" / "public" / "engine"))
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()
    prefix, version = toolchain()
    mods = closure("Haze.Web", prefix)
    lib = [m for m in mods if m.split(".")[0] != "Haze"]
    own = [m for m in mods if m.split(".")[0] == "Haze"]
    print(f"Lean {version}: {len(lib)} library modules and {len(own)} Haze modules")

    with cf.ThreadPoolExecutor(args.jobs) as pool:
        print("generating C for the library modules (cached after the first build)")
        c_lib = list(pool.map(lambda m: library_c(m, prefix, version), lib))
        c_own = [haze_c(m) for m in own]

        src = lean_source(version)
        fix_runtime(src)
        includes = include_dir(prefix, version) + [src / "src", src / "src" / "include"]
        objdir = CACHE / f"obj-{version}"
        jobs = [(c, objdir / "lib" / (c.stem + ".o"), False) for c in c_lib]
        jobs += [(c, objdir / "haze" / (c.stem + ".o"), False) for c in c_own]
        jobs += [(src / "src" / "runtime" / f"{f}.cpp", objdir / "runtime" / (f.replace("/", "_") + ".o"), True)
                 for f in RUNTIME]
        jobs += [(HERE / "shim.c", objdir / "shim.o", False), (HERE / "uv_stubs.c", objdir / "uv_stubs.o", False)]
        print(f"compiling {len(jobs)} files with Emscripten")
        objs = list(pool.map(lambda j: compile_one(j[0], j[1], j[2], includes), jobs))
    failed = [o for o in objs if isinstance(o, Exception)]
    if failed:
        for e in failed[:6]:
            print("\n".join(l for l in str(e).splitlines() if "error" in l)[:1500])
        sys.exit(f"{len(failed)} file(s) failed to compile")

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    rsp = CACHE / "objects.rsp"
    rsp.write_text("\n".join(str(o).replace("\\", "/") for o in objs), encoding="utf-8")
    print("linking")
    run(emcc_cmd(True) + COMMON + [
        f"@{rsp}", "-o", str(out / "haze.mjs"),
        "-sMODULARIZE=1", "-sEXPORT_ES6=1", "-sEXPORT_NAME=createHaze",
        "-sENVIRONMENT=web,worker,node", "-sALLOW_MEMORY_GROWTH=1", "-sINITIAL_MEMORY=64MB",
        "-sMAXIMUM_MEMORY=2GB", "-sSTACK_SIZE=32MB",
        "-sEXPORTED_FUNCTIONS=_haze_init,_haze_json,_haze_text,_free",
        "-sEXPORTED_RUNTIME_METHODS=ccall,UTF8ToString,stringToNewUTF8",
    ])
    sizes = {p.name: p.stat().st_size for p in out.iterdir() if p.name.startswith("haze.")}
    print("built", json.dumps({k: f"{v / 1e6:.1f} MB" for k, v in sizes.items()}))


if __name__ == "__main__":
    main()
