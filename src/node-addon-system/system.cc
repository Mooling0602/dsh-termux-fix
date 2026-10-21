// Minimal N-API replacement for @deepseek-ai/node-addon-system's flock binding,
// plus a renameat2(RENAME_NOREPLACE) helper used by the dsh-termux-fix patch of
// dsh-session-persistence-jsonl (Android SELinux blocks link() entirely).
//
// Contract (see node-addon-system/lib/flock.js): tryLock(fd, cb) calls cb(errno)
// where errno is 0 on success. flock() with LOCK_EX|LOCK_NB never blocks, so a
// synchronous call is correct here. flock.js calls getSystemErrorName(-errno),
// and Node's getSystemErrorName only accepts negative integers — so cb must
// receive the POSITIVE errno (e.g. EAGAIN=11).
//
// renameNoReplace(oldPath, newPath, cb) calls cb(0) on success or cb(positive
// errno) on failure. It performs renameat2(AT_FDCWD, old, AT_FDCWD, new,
// RENAME_NOREPLACE): an atomic exclusive-create move that fails with EEXIST
// when newPath already exists — the exact semantics of link-when-absent.
#include <node_api.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif
// asm-generic syscall number (aarch64); SYS_renameat2 normally exists already.
#ifndef SYS_renameat2
#define SYS_renameat2 276
#endif

static napi_value TryLock(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "tryLock(fd, cb) requires 2 arguments");
        return nullptr;
    }
    int64_t fd = -1;
    if (napi_get_value_int64(env, args[0], &fd) != napi_ok) {
        napi_throw_type_error(env, nullptr, "fd must be a number");
        return nullptr;
    }
    int rc = flock((int)fd, LOCK_EX | LOCK_NB);
    int32_t result = (rc == 0) ? 0 : errno;
    napi_value r;
    napi_create_int32(env, result, &r);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, args[1], 1, &r, nullptr);
    return undefined;
}

static napi_value RenameNoReplace(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_type_error(env, nullptr, "renameNoReplace(oldPath, newPath, cb) requires 3 arguments");
        return nullptr;
    }
    char oldpath[4096];
    char newpath[4096];
    size_t len = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &len) != napi_ok || len >= sizeof(oldpath) ||
        napi_get_value_string_utf8(env, args[0], oldpath, sizeof(oldpath), &len) != napi_ok) {
        napi_throw_type_error(env, nullptr, "oldPath must be a string");
        return nullptr;
    }
    if (napi_get_value_string_utf8(env, args[1], nullptr, 0, &len) != napi_ok || len >= sizeof(newpath) ||
        napi_get_value_string_utf8(env, args[1], newpath, sizeof(newpath), &len) != napi_ok) {
        napi_throw_type_error(env, nullptr, "newPath must be a string");
        return nullptr;
    }
    int rc = (int)syscall(SYS_renameat2, AT_FDCWD, oldpath, AT_FDCWD, newpath, RENAME_NOREPLACE);
    int32_t result = (rc == 0) ? 0 : errno;
    napi_value r;
    napi_create_int32(env, result, &r);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_call_function(env, undefined, args[2], 1, &r, nullptr);
    return undefined;
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_value fn;
    napi_create_function(env, "tryLock", NAPI_AUTO_LENGTH, TryLock, nullptr, &fn);
    napi_set_named_property(env, exports, "tryLock", fn);
    napi_create_function(env, "renameNoReplace", NAPI_AUTO_LENGTH, RenameNoReplace, nullptr, &fn);
    napi_set_named_property(env, exports, "renameNoReplace", fn);
    return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
