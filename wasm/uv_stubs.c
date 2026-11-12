/*
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti

Stand-ins for the libuv functions that Lean's runtime calls for file system operations. The
browser build has no file system for Haze to use, and Haze only checks the source text it is
given, so these are never reached in practice; if one is, it reports that the operation isn't
supported instead of crashing.
*/
#include <uv.h>

const char* uv_strerror(int err) {
    (void)err;
    return "not supported in the browser";
}

void uv_fs_req_cleanup(uv_fs_t* req) { (void)req; }

int uv_fs_stat(uv_loop_t* loop, uv_fs_t* req, const char* path, uv_fs_cb cb) {
    (void)loop; (void)req; (void)path; (void)cb;
    return UV_ENOSYS;
}

int uv_fs_lstat(uv_loop_t* loop, uv_fs_t* req, const char* path, uv_fs_cb cb) {
    (void)loop; (void)req; (void)path; (void)cb;
    return UV_ENOSYS;
}

int uv_fs_link(uv_loop_t* loop, uv_fs_t* req, const char* path, const char* new_path, uv_fs_cb cb) {
    (void)loop; (void)req; (void)path; (void)new_path; (void)cb;
    return UV_ENOSYS;
}

int uv_fs_unlink(uv_loop_t* loop, uv_fs_t* req, const char* path, uv_fs_cb cb) {
    (void)loop; (void)req; (void)path; (void)cb;
    return UV_ENOSYS;
}

int uv_fs_mkdtemp(uv_loop_t* loop, uv_fs_t* req, const char* tpl, uv_fs_cb cb) {
    (void)loop; (void)req; (void)tpl; (void)cb;
    return UV_ENOSYS;
}

int uv_fs_mkstemp(uv_loop_t* loop, uv_fs_t* req, const char* tpl, uv_fs_cb cb) {
    (void)loop; (void)req; (void)tpl; (void)cb;
    return UV_ENOSYS;
}

int uv_os_tmpdir(char* buffer, size_t* size) {
    (void)buffer; (void)size;
    return UV_ENOSYS;
}
