/*
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti

The C side of the WebAssembly build. JavaScript calls `haze_init` once, then `haze_json` or
`haze_text` with a UTF-8 source text, and frees the returned string with `free`.

The native `haze` command starts Lean's task manager and runs `main` on a separate thread. This
shim does neither: without the task manager, `Task.spawn` runs its work immediately on the
calling thread, so the browser build needs no threads.
*/
#include <lean/lean.h>
#include <stdlib.h>
#include <string.h>
#include <emscripten/emscripten.h>

lean_object* initialize_haze_Haze_Web(uint8_t builtin);
lean_object* haze_check_json(lean_object* src);
lean_object* haze_check_text(lean_object* src);

static int initialized = 0;

/* Initializes the Lean runtime and Haze's modules. Returns 0 on success. */
EMSCRIPTEN_KEEPALIVE int haze_init(void) {
    if (initialized) return 0;
    lean_object* res = initialize_haze_Haze_Web(1);
    lean_io_mark_end_initialization();
    if (!lean_io_result_is_ok(res)) {
        lean_io_result_show_error(res);
        lean_dec_ref(res);
        return 1;
    }
    lean_dec_ref(res);
    initialized = 1;
    return 0;
}

static char* call(lean_object* (*f)(lean_object*), const char* src) {
    if (haze_init() != 0) return NULL;
    lean_object* out = f(lean_mk_string(src));
    size_t n = lean_string_size(out);  /* includes the terminating NUL */
    char* copy = malloc(n);
    memcpy(copy, lean_string_cstr(out), n);
    lean_dec_ref(out);
    return copy;
}

/* Checks a source text and returns `haze --json` output: one JSON record per line. */
EMSCRIPTEN_KEEPALIVE char* haze_json(const char* src) { return call(haze_check_json, src); }

/* Checks a source text and returns the messages `haze` prints. */
EMSCRIPTEN_KEEPALIVE char* haze_text(const char* src) { return call(haze_check_text, src); }
