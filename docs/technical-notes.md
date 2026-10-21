# Technical notes

Implementation details worth knowing if you are modifying these patches or porting them to another architecture.

[简体中文](technical-notes.zh.md) · English

## The N-API contracts in `system.cc`

Both functions are reverse-engineered from `node-addon-system/lib/flock.js`, and both have non-obvious details. Getting them wrong produces silent misbehaviour rather than a crash.

### `tryLock(fd, cb)`

```c
int rc = flock((int)fd, LOCK_EX | LOCK_NB);
int32_t result = (rc == 0) ? 0 : errno;
// cb(result)
```

Two things matter:

1. **Non-blocking.** `LOCK_NB` means the call never waits, so a synchronous implementation is correct. No async work is needed.
2. **Positive errno.** The callback must receive `EAGAIN` as `11`, not `-11`. `flock.js` converts with `getSystemErrorName(-errno)`, and Node's `getSystemErrorName` accepts only negative integers. Passing a negative value through would double-negate and produce garbage.

### `renameNoReplace(oldPath, newPath, cb)`

```c
int rc = (int)syscall(SYS_renameat2, AT_FDCWD, oldpath,
                      AT_FDCWD, newpath, RENAME_NOREPLACE);
int32_t result = (rc == 0) ? 0 : errno;
// cb(result)
```

This replaces `link()` as an atomic exclusive-create publish:

| Outcome | `link(when absent)` | `renameat2(RENAME_NOREPLACE)` |
|---|---|---|
| Target absent | creates the link | moves the file, atomically |
| Target present | `EEXIST` | `EEXIST` |
| Partial write visible | never | never |

`SYS_renameat2` falls back to `276` when the macro is undefined, which is the asm-generic number for aarch64. **Other architectures need their own number** (x86_64: 316, arm: 382). The `#ifndef` guard means a correct definition from the headers always wins, so this only matters on targets whose libc does not export it.

Paths are copied into 4096-byte stack buffers; longer paths throw a TypeError rather than truncating.

## Why `link()` is not just "unsupported"

It is worth being precise, because the failure mode misleads people into looking for a filesystem fix.

Android's SELinux policy denies `link(2)` for app processes with `EACCES`. This happens before the filesystem is consulted — the same `link()` call succeeds on a normal Linux install on the very same filesystem layout. `errno` may be `EACCES` or `EPERM` depending on the exact policy rule hit, so the patches test for both.

Consequence: there is no mount option, no `chmod`, no path change that fixes this. The only options are "don't use `link()`" or "lose the atomicity".

## Why attachments use `copyFile` and not `renameat2`

The attachment paths are content-addressed: the target filename is derived from the sha256 of the content. Two racing writers therefore produce byte-identical targets, so a plain `copyFile` race is safe — the loser overwrites the same bytes. The digest check that follows the publish still runs and still guards against corruption.

Session persistence has no such property: the staged files differ per session update, so `copyFile` there would be a genuine last-writer-wins clobber. That is why it gets the syscall-backed path instead.

## Anchor-based patching

`patch-session-persistence.mjs` locates each rewrite point by an exact substring and requires it to appear exactly once:

```js
if (count(src, anchor) !== 1) {
    console.error(`anchor found ${count(src, anchor)} times (expected 1), upstream layout changed`);
    process.exit(1);
}
```

This is deliberately brittle. A regex or fuzzy match would keep "working" across upstream changes while silently patching the wrong thing — and in this area, a wrong patch corrupts session files only under concurrency, long after the install appeared to succeed.

Each patch also has an `applied()` predicate, so re-running is a no-op.

## The `flock.js` guard trap

Upstream:

```js
if (platform !== 'linux' && platform !== 'darwin') { throw ... }
```

The obvious `sed`:

```bash
sed -i "s/platform !== 'linux' && platform !== 'darwin'/& && platform !== 'android'/" file
```

is **not idempotent**. The replacement still contains the original text as a prefix, so each run matches again and appends another clause:

```js
// after three runs
if (platform !== 'linux' && platform !== 'darwin'
    && platform !== 'android' && platform !== 'android' && platform !== 'android') {
```

Functionally harmless, cosmetically awful, and it makes `--check` unable to distinguish "patched once" from "patched repeatedly". The current implementation checks for the marker first and skips if present.

## The koffi anchor trap

The original script used:

```awk
/^static StatResult\(/ { infn=1 }
infn && !done && /^#if defined\(__linux__\)$/ { ... }
```

`/^static StatResult\(/` requires `(` immediately after `StatResult`, but the real signature is:

```c
static StatResult StatAt(int fd, bool fd_is_directory, const char *filename, ...)
```

There is a function name in between. The pattern never matched, `infn` stayed 0, awk copied the file unchanged, and `mv` wrote it back. The script then checked `grep -q "StatAt"` — which asks whether the *function* exists, not whether the *patch* was applied. It always passed.

Fixing only the pattern is still wrong. `StatAt`'s body runs to roughly line 3050 and contains a second `#if defined(__linux__)` (line 3048) that computes `st_mtim`/`st_ctim` manually with `std::chrono`. It does not use `statx` and must not be touched on Android.

The current rewrite:

```awk
BEGIN { infn = 0; done = 0 }
/^static StatResult[[:space:]]+StatAt\(/ { infn = 1 }
infn && !done && /^#if defined\(__linux__\)$/ {
    print "#if defined(__linux__) && !defined(__ANDROID__)"; done = 1; next
}
{ print }
```

- matches the real signature
- sets `done` so the scan stops after the first replacement

The idempotency check is scoped to the function, not the file:

```bash
awk '/^static StatResult[[:space:]]+StatAt\(/ { infn = 1; next }
     infn && /^#if defined/ { print; exit }' "$SRC"
```

Verified both ways: restoring the file to its unpatched state and running the patch reproduces the patched file byte-for-byte, and re-running on an already patched file leaves the md5 unchanged.

## Speech: why rpath does not work on Android

Worth writing down, because the failure looks like a missing library and sends you chasing paths.

The compiled addon needs `libsherpa-onnx-c-api.so` and `libonnxruntime.so`. Standard practice is to emit an rpath so the loader finds siblings:

```bash
c++ ... -Wl,-rpath,'$ORIGIN' -o sherpa-onnx.node
```

On glibc that works. On Android it does not, and the linker says so out loud:

```
WARNING: linker: Warning: "...sherpa-onnx.node" unused DT entry: DT_RPATH
  (type 0xf arg 0x241c) (ignoring)
```

Both `DT_RPATH` and `DT_RUNPATH` are ignored by bionic's loader. Only `LD_LIBRARY_PATH`, `DT_NEEDED` resolution against the default paths, and already-loaded libraries participate. Since dsh does not export `LD_LIBRARY_PATH`, and setting it from inside the process is too late, the practical options are:

1. patch `addon.js` to `process.dlopen` each dependency before requiring the addon — what this repo does;
2. install the `.so` files into a default search path (`$PREFIX/lib`) — works, but pollutes a shared directory and collides across versions;
3. wrap the dsh launch in a shell script that exports `LD_LIBRARY_PATH` — works, but breaks when dsh is started by other means (service, shortcut).

Option 1 is the least invasive. Note that `process.dlopen` on a plain shared library throws `Module did not self-register`. That error is **expected and harmless**: the library has already been mapped into the process by then, which is the entire point. The patch swallows it deliberately.

## Speech: glibc vs bionic

The prebuilt `sherpa-onnx-linux-arm64` binary has:

```
NEEDED  libsherpa-onnx-c-api.so
NEEDED  libonnxruntime.so
NEEDED  libstdc++.so.6
NEEDED  libc.so.6
NEEDED  ld-linux-aarch64.so.1
```

`libc.so.6` and `ld-linux-aarch64.so.1` are glibc. Termux binaries link `libc.so` and `libdl.so` from bionic. There is no compatibility layer, so copying the linux-arm64 build onto Android cannot work — no amount of rpath, `LD_LIBRARY_PATH`, or `patchelf` fixes it.

Upstream's `android-aarch64-termux-shared` release, by contrast, has:

```
NEEDED  libandroid.so
NEEDED  liblog.so
NEEDED  libc.so
NEEDED  libc++_shared.so
```

That is a bionic build, and it loads. The only thing missing from it is the N-API wrapper, which is why step 6 compiles ~18 `.cc` files and links against that release instead of rebuilding sherpa-onnx and onnxruntime from source (which would need CMake, protobuf, and a very long build).

## Porting to another architecture

Three places assume aarch64:

1. `src/node-addon-system/system.node` — prebuilt binary. Recompile `system.cc`.
2. `SYS_renameat2` fallback constant `276` — see the table above.
3. `node-addon-system-android-arm64` — the package name must match `${platform}-${arch}` because `flock.js` resolves it by that exact string.

Steps 1, 2 and 4 are architecture-independent.
