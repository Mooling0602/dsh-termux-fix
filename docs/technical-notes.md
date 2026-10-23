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

## Why the install has to skip lifecycle scripts

The patch above only helps if koffi gets a chance to be patched. A plain `npm install -g @deepseek-ai/dsh` never gets there, and the reason is a control-flow trap rather than a compile error.

koffi declares `scripts.install = "node ./cnoke.cjs -P . -D src/koffi --prebuild --release"`. CNoke's flow is:

1. `checkCompatibility()` — only node and NAPI version checks; it passes.
2. `checkPrebuild()` — decides whether a usable binding already exists by asking Node to load the package: `spawnSync(process.execPath, ["-e", "require(process.argv[1])", package_dir])`, and testing `proc.status === 0`.
3. On false, print `Failed to load prebuilt binary, rebuilding from source`, then `checkCMake()`, `configure()` and `cmake --build`.
4. Any failure in the build rethrows as `Failed to run build step`, and the top-level handler calls `process.exit(1)`.

`checkPrebuild()` can only return true when a binding is already present. On a fresh install there is none, because koffi publishes no `android-arm64` prebuilt (its `optionalDependencies` have entries for Linux, darwin, win32, freebsd, openbsd and loongarch, but not android). So the hook always falls through to step 3, always attempts the compile, and always fails at `base.cc:2967` — the exact line the patch fixes, in a file the patch cannot reach yet, because nothing is installed for it to patch.

npm's contribution is to make that fatal rather than cosmetic: a non-zero `install` script fails the package install, and a failed package in a global install rolls back the whole transaction. The observed end state is therefore *no dsh at all*, not a dsh with a broken koffi.

Verified directly, on a clean prefix with a pristine koffi tree:

```
$ npm install -g --prefix $TMPDIR/plain @deepseek-ai/dsh
...
Failed to load prebuilt binary, rebuilding from source
... base.cc:2967: error: cannot initialize a member subobject of type '__u32'
    (aka 'unsigned int') with an lvalue of type 'const char *'
make: *** [Makefile:91: all] Error 2
Failed to run build step
$ echo $?
1
```

and the two ways to break the loop:

- make the compile succeed (patch `base.cc`, then build) — impossible before install, chicken and egg;
- skip the hook entirely, then supply the binding afterwards.

`scripts/install-dsh.sh` takes the second: `--ignore-scripts`, then `./install.sh`. The end state is the same or better — step 1 prefers a prebuilt binding over a source build, so CNoke is not needed at all on a normal machine.

Two consequences worth knowing:

- **The same hook fires when any global package pulls dsh in.** Installing `@deepseek-harness-tui/dsh-tui` alongside dsh runs koffi's hook again, because koffi is a hard dependency of `@deepseek-ai/dsh-fs-local`. Pass `--ignore-scripts` to that install too. (`--omit=optional` is not a way out: koffi is a regular dependency, and dsh's own `optionalDependencies` is empty.)
- **`--ignore-scripts` is tree-wide, not global-install-wide.** It also silences `node-pty`'s `install` script, whose prebuild fetcher produces nothing usable on Android either — upstream publishes no `android-arm64` prebuild, which is what step 7 supplies. Steps 2, 3 and 6 cover the remaining native packages.

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

## The terminal inspector's platform gate

`dsh-subprocess-local` builds its process inspector through a small switch:

```js
function createProcessInspector(platform = process.platform, arch = process.arch, internals = DEFAULT_INTERNALS) {
	if (platform === "linux") return new LinuxProcessInspector(arch, internals);
	if (platform === "darwin") return new MacProcessInspector(internals);
	if (platform === "win32") return createWindowsProcessInspector();
	throw new Error(`subprocess-local: terminal inspection is unsupported on platform ${platform}`);
}
```

On Termux `process.platform` is `"android"`, so this throws — and it is thrown while the plugin is being loaded, not when a terminal is opened, which is why the whole terminal service disappears rather than degrading.

`LinuxProcessInspector` reads `/proc/<pid>/stat` and, to decide whether a process is waiting on stdin, `/proc/<pid>/task/<tid>/syscall`. Both are Linux-kernel interfaces that Android exposes unchanged. The one arch-specific part is a syscall-number table:

| | `read` | `select` | `pselect` | `poll` | `ppoll` | `epoll_wait` | `epoll_pwait` |
|---|---|---|---|---|---|---|---|
| x64 | 0 | 23 | 270 | 7 | 271 | 232 | 281 |
| arm64 | 63 | — | 72 | — | 73 | — | 22 |

`arm64` is present and correct for Android, so the only thing standing between `android` and a working inspector is the string comparison. Note that an unknown architecture already degrades gracefully — `linuxSyscallTables()` returns `undefined` and `isStdinWaiting()` answers `false` — so the syscall table was never the hard gate.

## Persistent terminals: glibc's `libutil` vs bionic

`node-pty` resolves its native binding by looking for `prebuilds/<platform>-<arch>/pty.node`, so on Android it wants `prebuilds/android-arm64/pty.node`, which upstream does not ship. The tempting fix is to reuse `prebuilds/linux-arm64/pty.node`, and it fails immediately:

```
dlopen failed: library "libutil.so.1" not found
```

`forkpty(3)` and `openpty(3)` live in glibc's separate `libutil`; on bionic they are part of libc. That is also why `binding.gyp` lists `'-lutil'` only for Linux — and why a binding built for bionic must not link it at all. The two other glibc-isms to avoid are the same ones that bite the sherpa addon: no rpath (the Android linker ignores `DT_RPATH`/`DT_RUNPATH`) and no `libstdc++` expectation (Termux uses libc++).

Because the slot is already in the loader's candidate list, this is purely a placement problem: put a bionic build at `prebuilds/android-arm64/pty.node` and nothing else has to change. `pty.cc` is used unmodified, and `patch/patch-terminal-android.mjs` touches only the inspector gate in `dsh-subprocess-local` — node-pty itself is not patched.

An earlier revision of that patch also appended `prebuilds/linux-arm64` to the candidate list. It was pointless, because `prebuilds/android-arm64` is already in the array, and it made failures harder to read: the loader reports the last error it hit, so a missing binding surfaced as `Cannot find module './prebuilds/linux-arm64/pty.node'` instead of naming the path that was actually absent.

## Porting to another architecture

Four places assume aarch64:

1. `src/node-addon-system/system.node` — prebuilt binary. Recompile `system.cc`.
2. `src/node-pty/pty.node` — prebuilt binary. Recompile with `scripts/build-node-pty.sh`; the loader picks `prebuilds/android-<arch>` from `process.arch`, so no patch change is needed.
3. `SYS_renameat2` fallback constant `276` — see the table above.
4. `node-addon-system-android-arm64` — the package name must match `${platform}-${arch}` because `flock.js` resolves it by that exact string.

Steps 1, 2, 4 and 7 are otherwise architecture-independent.
