// Checks the WebAssembly build against the native `haze` binary: every example and test file must
// produce the same output, byte for byte, apart from the file name in each message.
//
//   node wasm/test_node.mjs [--skip=name,...] [files...]
//
// --skip leaves out files whose path contains one of the names (chip_design takes many minutes
// without GMP).
import { readFileSync, readdirSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join, relative } from "node:path";
import createHaze from "../site/public/engine/haze.mjs";

const root = new URL("..", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const native = join(root, ".lake", "build", "bin", process.platform === "win32" ? "haze.exe" : "haze");

function walk(dir) {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p) : p.endsWith(".hz") ? [p] : [];
  });
}

const haze = await createHaze();
const t0 = performance.now();
if (haze._haze_init() !== 0) throw new Error("haze_init failed");
console.log(`initialized in ${(performance.now() - t0).toFixed(0)} ms`);

function check(fn, src) {
  const p = haze.stringToNewUTF8(src);
  const out = haze[fn](p);
  haze._free(p);
  const s = haze.UTF8ToString(out);
  haze._free(out);
  return s;
}

const args = process.argv.slice(2);
const skip = args.filter((a) => a.startsWith("--skip=")).flatMap((a) => a.slice(7).split(",")).filter(Boolean);
const named = args.filter((a) => !a.startsWith("--"));
const files = (named.length ? named : [...walk(join(root, "tests")), ...walk(join(root, "examples"))])
  .filter((f) => !skip.some((s) => f.replaceAll("\\", "/").includes(s)));
let ok = 0, slowest = [0, ""];
for (const f of files) {
  const src = readFileSync(f, "utf8");
  const name = relative(root, f).replaceAll("\\", "/");
  let want;
  try {
    want = execFileSync(native, [name], { cwd: root, encoding: "utf8" });
  } catch (e) {
    want = e.stdout; // haze exits with 1 when a declaration is rejected
  }
  const t = performance.now();
  const got = check("_haze_text", src).replaceAll("main.hz:", `${name}:`);
  const dt = performance.now() - t;
  if (dt > slowest[0]) slowest = [dt, name];
  const same = got.trim() === want.trim();
  ok += same;
  console.log(`${same ? "same " : "DIFF "} ${(dt / 1000).toFixed(2).padStart(6)} s  ${name}`);
  if (!same) {
    const a = want.trim().split("\n"), b = got.trim().split("\n");
    const i = a.findIndex((l, k) => l !== b[k]);
    console.log(`  first difference at line ${i + 1}:\n  native: ${a[i]}\n  wasm:   ${b[i]}`);
  }
}
console.log(`${ok}/${files.length} files match the native build; slowest ${(slowest[0] / 1000).toFixed(2)} s (${slowest[1]})`);
process.exit(ok === files.length ? 0 : 1);
