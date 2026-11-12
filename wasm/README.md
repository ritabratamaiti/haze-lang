# Haze in WebAssembly

The website's playground runs Haze in the browser. This directory builds that version: the same
Lean code as the `haze` command, compiled to WebAssembly with Emscripten.

```sh
lake build
python wasm/build.py                       # writes site/public/engine/haze.mjs and haze.wasm
node wasm/test_node.mjs --skip=chip_design # compares every test and example with native haze
```

You need [emsdk](https://emscripten.org/docs/getting_started/downloads.html), activated so that
`emcc` is on the PATH, and `git`. The first build takes about five minutes; later ones take
seconds, because everything except Haze's own code is cached in `wasm/.cache`.

## How it works

Lean stopped publishing a WebAssembly build of its runtime and standard library after version
4.15, so `build.py` builds them. It:

- finds every module that `Haze.Web` imports, including Lean's `Init` and `Std` (about 800 in all);
- generates C for the `Init` and `Std` modules with the installed Lean toolchain, from the sources
  that come with it, and takes Haze's C from `lake build`;
- fetches Lean's runtime at the same version and compiles it with Emscripten in Lean's own
  `LEAN_EMSCRIPTEN` configuration, with a two-line fix where a function signature has drifted;
- links it all with [`shim.c`](shim.c) into `haze.mjs` and a 2.8 MB `haze.wasm`.

The browser build has no threads. Lean runs `Task.spawn` immediately when its task manager isn't
started, so Haze's parallel checks simply run one after another, and the page needs no special
headers. The build also leaves out libuv (the few file functions the runtime refers to are
stubbed in [`uv_stubs.c`](uv_stubs.c)) and GMP.

Without GMP, arithmetic on very large numbers is slow. Most models check in well under a second,
but [`examples/chip_design.hz`](../examples/chip_design.hz) takes many minutes in the browser
against eight seconds natively. The website shows that example's precomputed output.

## The interface

`haze.mjs` exports `createHaze()`, which loads the module. After `_haze_init()`, `_haze_json(src)`
and `_haze_text(src)` check a model given as a C string and return a new C string with the same
output as `haze --json` and `haze`. Free both strings with `_free`. The source is checked as a file
named `main.hz`. See [`Haze/Web.lean`](../Haze/Web.lean) and
[`site/src/worker.ts`](../site/src/worker.ts), which runs the engine in a web worker.
