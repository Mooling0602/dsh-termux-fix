# dsh-termux-fix

**Run [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh) on Termux / Android.**

[简体中文](README.zh.md) · English

---

`dsh` is published for Linux, macOS and Windows. On Android it starts, then falls over — differently at each layer. This repository collects the patches that make it work, as one re-runnable, idempotent installer.

> [!IMPORTANT]
> This project only guarantees compatibility with the **latest** release of `@deepseek-ai/dsh`; older versions are not supported. Patches are applied by exact-text anchors inside the installed package, and those anchors move between releases. After dsh is updated, run `git pull` to get the matching patches, or wait until they have been adapted. When an anchor no longer matches, the affected step exits with `upstream layout changed` instead of patching the wrong place.

```
$ git clone https://github.com/Mooling0602/dsh-termux-fix
$ cd dsh-termux-fix
$ ./scripts/install-dsh.sh            # install dsh, then patch it
$ dsh web                             # now boots
```

> **Install with `--ignore-scripts`, not plain `npm install -g`.** A bare `npm install -g @deepseek-ai/dsh` **fails on Termux/Android** — koffi's install script compiles C++ whose `statx()` branch does not build against bionic, exits 1, and npm then rolls back the entire global install, leaving you with no dsh at all. `scripts/install-dsh.sh` installs with `--ignore-scripts` and then runs `./install.sh`, which supplies every native binding the skipped scripts would have produced. Add `--with-tui` to install `@deepseek-harness-tui/dsh-tui` in the same transaction.

## Why it breaks

Android is close enough to Linux to pass every superficial check, and different enough to fail at eight separate points. None of them are configuration problems — each is a mismatch between what dsh assumes and what Android provides.

| # | Component | Assumption that breaks | Fix |
|---|---|---|---|
| 1 | `koffi` | `statx()` is declared in `<sys/stat.h>` | Exclude Android from the `statx` branch in a prebuilt binding; compile only if it does not fit |
| 2 | `node-addon-require-builtin` | A prebuilt `android-arm64` binary exists | Compile it from upstream source |
| 3 | `node-addon-system` | A prebuilt `android-arm64` binary exists | Substitute our own minimal N-API binding |
| 4 | session persistence, attachments | `link(2)` works | Replace every `link()` publish with `renameat2` / `copyFile` |
| 5 | verifying the above | — | Load every binding and exercise it |
| 6 | local speech-to-text | An `android-arm64` sherpa-onnx binary exists | Build the N-API addon against upstream's official Termux release |
| 7 | persistent terminal (pty) | `process.platform` is only ever linux/darwin/win32, and an `android-arm64` node-pty exists | Route the inspector through its Linux branch; ship a prebuilt `pty.node` |
| 8 | `grep` / `glob`, file writes | A prebuilt `android-arm64` ripgrep exists, and `link(2)` works | Symlink the Android ripgrep package at the system `rg`; publish new files with `renameat2` instead of `link()` |

Step 0 is different in kind: it installs the toolchain (`clang`, `cmake`, `git`, …) those steps need. It exists because a missing `cmake` used to surface as `koffi build failed` with the real cause buried in a stack trace — see issue #1.

### Speech: two bugs behind one error

Voice input fails with a single unhelpful line:

```
Error: Local speech is unavailable for android-arm64
```

That message comes from a hardcoded platform allowlist in `dsh-experimental-speech-to-text-sensevoice`, listing darwin/linux/win32 only. Adding `android-arm64` to that list is necessary but **not sufficient** — the next failure is the native dependency:

`sherpa-onnx-node` ships prebuilt binaries for Linux, darwin and win32. Its `linux-arm64` build is dynamically linked against **glibc** (`libc.so.6`, `ld-linux-aarch64.so.1`, `libstdc++.so.6`). Android uses **bionic**, so that binary cannot load at all — not a path problem, a different libc.

The way out: upstream publishes an `android-aarch64-termux-shared` release built against bionic, it just is not distributed through npm. Step 6 downloads that release, compiles only the thin N-API wrapper against it, and drops both next to the JS package.

One wrinkle worth knowing: **Android's linker ignores `DT_RPATH` and `DT_RUNPATH`** — it prints `unused DT entry: DT_RPATH ... (ignoring)` and carries on. So the addon cannot find its sibling `.so` files by rpath, and the dsh process does not export `LD_LIBRARY_PATH`. The patch therefore preloads the two shared libraries with `process.dlopen` before requiring the addon, which puts them in the global symbol scope where `OrtGetApiBase` can be resolved.

### koffi ships a prebuilt binding

`src/koffi/koffi.node` is a compiled aarch64 binding, built once from the patched source. Step 1 installs it and checks that it actually loads — the same test cnoke uses (`node -e "require('koffi')"`).

The reason is not speed. **Having a working binding means cmake is never invoked**, and cmake is the least reliable part of this whole setup on Termux: issues #1 and #2 were both cmake failures (absent, then built against a newer libc++ than the one installed), and neither had anything to do with koffi. cnoke short-circuits on a valid prebuilt through `checkPrebuild()`, so with one in place neither the compiler nor cmake runs at all.

The binding is N-API and therefore not tied to a Node major version, but it *is* tied to the koffi release: `koffi.json` records the version, architecture and checksum. Step 1 falls back to compiling from source when any of them does not match, so a different koffi still works — it just needs the toolchain.

### Terminal: two gates, both fatal

Opening a persistent terminal reports exactly one line, `terminal inspection is unsupported on platform android`, but two unrelated problems sit underneath it. Fixing either one alone still leaves the terminal closed.

**First gate: `process.platform` is `android`, not `linux`.** dsh's `createProcessInspector()` accepts only `linux`/`darwin`/`win32` and throws for everything else — and it is called at plugin load, so the whole terminal service fails to register. But Android *is* the Linux kernel: `/proc` has the same layout, and the arm64 syscall numbers the inspector reads (`read`=63, `pselect`=72, `ppoll`=73, `epoll_pwait`=22) are identical. Routing it to `LinuxProcessInspector` is therefore correct on the merits, not a workaround.

**Second gate: node-pty ships no Android prebuild.** Its loader looks for `prebuilds/<platform>-<arch>/pty.node`, i.e. `prebuilds/android-arm64/`, which upstream does not publish. The bundled `linux-arm64` build **cannot** be reused: it dynamically links glibc's `libutil.so.1`, and Android uses bionic, where `libutil` was folded into libc:

```
dlopen failed: library "libutil.so.1" not found
```

So it has to be built against bionic. `src/node-pty/pty.node` is such an aarch64 binding, compiled from **unmodified** upstream `src/unix/pty.cc` — `forkpty(3)` exists in bionic, so no source change is needed. It links without `-lutil` (unnecessary on bionic) and without an rpath (the Android linker ignores it).

As with koffi, the prebuilt is preferred: `pty.json` records the node-pty version, architecture and checksum, and step 7 falls back to `scripts/build-node-pty.sh` when any of them does not match — which is when `clang` becomes necessary. The step then actually forks a shell and reads its echo back, because a successful `require()` alone does not prove `forkpty` works on bionic.

### The interesting one: SELinux blocks `link()`

This is the failure that eats the most time, because it is not an error about capabilities or filesystems — **Android's SELinux policy denies `link(2)` outright**, returning `EACCES`/`EPERM` for every call.

dsh uses `link()` in three places, and in all three it is doing something specific: an **atomic exclusive-create publish**. Linking a staged file to its final path either succeeds (the file now exists under both names, then the staged name is dropped) or fails with `EEXIST` because the target is already there. That is a compare-and-swap, not a copy.

So the replacement cannot be a plain `rename()` — that would silently clobber a concurrent writer. The two fallbacks preserve the original contract:

| Location | Fallback | Why it is equivalent |
|---|---|---|
| session publish (ESM + CJS) | `renameat2(RENAME_NOREPLACE)` | Kernel-level atomic exclusive create; reports `EEXIST` on collision |
| attachment publish | `copyFile` | Targets are content-addressed (sha256), so a racing duplicate write is byte-identical; the following digest check still guards integrity |

The first needs a syscall that Node's public API does not expose, which is why step 3 exists at all: `src/node-addon-system/system.cc` is a small N-API binding that provides both `flock` (dsh needs it) and `renameNoReplace` (our patch needs it).

## Quick start

```bash
git clone https://github.com/Mooling0602/dsh-termux-fix
cd dsh-termux-fix
./scripts/install-dsh.sh --with-tui   # install dsh + dsh-tui, then patch
./install.sh --check                  # see what is missing (all green = done)
```

Then restart `dsh`. If dsh is already installed and you only want the patches, `./install.sh` alone is still the right command.

### Installing dsh by hand

`scripts/install-dsh.sh` is a convenience wrapper around exactly this:

```bash
npm install -g --ignore-scripts @deepseek-ai/dsh    # --ignore-scripts is required
./install.sh                                        # supply the bindings it skipped
```

The flag is not an optimisation. With scripts enabled, koffi's `install` hook runs CNoke, which tries to compile `lib/native/base/base.cc`, hits `cannot initialize a member subobject of type '__u32' ... with an lvalue of type 'const char *'` at the `statx()` call (line 2967), and exits 1. npm treats one failed lifecycle script as a failed install and undoes the whole tree, so dsh is left uninstalled. Skipping the scripts and patching afterwards is the same end state, without the doomed compile.

The same applies to installing a **second** global package that pulls dsh in as a dependency, e.g. `dsh-tui`: pass `--ignore-scripts` there too, or the koffi hook fires again and rolls that install back as well. Re-run `./install.sh` afterwards, because the new install wiped the existing patches.

## Usage

```
./install.sh              Apply every step. Idempotent — safe to re-run.
./install.sh --check      Report status of each patch. Changes nothing.
./install.sh --step 0     Run one step only (0-8).
./install.sh --list       List steps.
./install.sh --help       Full options.
```

`--check` output looks like this:

```
dsh-termux-fix — status

  commit        52bf9e9
  dsh version   0.2.1-rc.2
  modules       /data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules
  node          v26.4.0
  platform      Linux aarch64

  0 toolchain                        complete
  1 koffi binding                    loads (koffi 3.1.1)
  2 require-builtin binding          present (245736 bytes)
  3 system binding                   present (8488 bytes)
  3 flock.js guard                   allows android
  4 session-persistence              patched (3 refs)
  4 attachment-local                 patched (2 refs)
  6 sherpa addon                     present (616680 bytes)
  6 sensevoice platform gate         allows android
  6 addon library preload            patched
  6 model files                      downloaded
  7 terminal inspector gate          allows android
  7 pty binding                      present, prebuilt (97768 bytes)
  8 ripgrep shim                     present -> /data/data/com.termux/files/usr/bin/rg
  8 fs-local link fallback           patched
```

The `commit` line is the revision that produced the report — include it when filing an issue, see [Reporting an issue](#reporting-an-issue).

When dsh is not installed at all, `--check` reports that instead of failing, so the output is still worth pasting:

```
  commit        <short hash>
  dsh version   not installed
  modules       <not found>
  node          v26.4.0
  platform      Linux aarch64

  dsh                                NOT INSTALLED — no patch can be assessed
```

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `DSH_MODULES` | `npm root -g` + `/@deepseek-ai/dsh/node_modules` | Where dsh is installed |
| `DSH_FIX_WORKDIR` | `~/src` | Scratch space for cloned/built sources |
| `NODE_INC` | `$PREFIX/include/node` | Directory containing `node_api.h` |
| `NO_COLOR` | unset | Disable coloured output |

## After every upgrade

> **The patches live inside the installed package and are wiped by any reinstall or upgrade.** Upgrading means re-running `./scripts/install-dsh.sh` (or, if dsh is already installed, `./install.sh` after your own `npm install -g --ignore-scripts @deepseek-ai/dsh`). Note that a reinstall the normal way — without `--ignore-scripts` — does not just wipe the patches, it fails outright and rolls dsh back.

Only `koffi` needs a real recompile; the other two are N-API v9 and survive Node upgrades. Step 2 skips work when its binding is already present, so a plain re-run is cheap.

**Step 6 is the fragile one.** It writes into `sherpa-onnx-node`, which npm installs as a transitive dependency of the voice-input bundle. A reinstall wipes the compiled `.node` and the `.so` copies. Worse, if you use pnpm (dsh profiles do), `pnpm install` rebuilds the store from scratch and will transport you back to `Local speech is unavailable for android-arm64`. Re-run `./install.sh --step 6` after any dependency change. The build artefacts stay in `$DSH_FIX_WORKDIR/sherpa-onnx/`, so the rebuild is a link step, not a download — unless you cleared that directory.

## Requirements

- Termux on Android, **aarch64** (arm64). The prebuilt `system.node` is aarch64-only; other architectures must recompile from `system.cc`. Step 6 likewise depends on upstream's `android-aarch64` release.
- **`@deepseek-ai/dsh` installed first, without lifecycle scripts.** Run `./scripts/install-dsh.sh` (or `npm install -g --ignore-scripts @deepseek-ai/dsh`) before `./install.sh`; these patches edit the installed package and have nothing to edit otherwise. Plain `npm install -g @deepseek-ai/dsh` aborts on the koffi build and installs nothing — see [Installing dsh by hand](#installing-dsh-by-hand). Check the location with `npm root -g`.
- Node.js ≥ 20 with headers at `$PREFIX/include/node` (`pkg install nodejs` provides both).
- **`ripgrep`**, for the `grep` and `glob` tools. Step 8 points dsh at the system binary with a symlink; without it the step warns and the two tools stay broken. `pkg install ripgrep`.
- `clang`, `cmake`, `make`, `git`, `tar`, `curl`. **Step 0 installs these via `pkg`** and is a no-op when they are present, so you do not normally need to install them by hand. They are still listed here because `--step 1` and later assume them if you skip step 0. `cmake` is only needed if the prebuilt koffi binding cannot be used — see below.
- Network access for steps 2 and 6 (clone/compile sources, fetch the sherpa release). Both are skipped when their output is already present.
- For speech, the voice-input bundle enabled in your dsh profile. `--check` reports `6 speech package  not installed` if it is missing.

## Troubleshooting

**`Error: dsh: plugin tree failed to load`** — usually a plugin, not these patches. Check the full stack trace; a missing npm package is unrelated.

**`no sandbox backend is usable on this host`** — Termux has neither bubblewrap nor a Landlock-enforcing kernel, so dsh's `workspace-write` sandbox mode refuses to run commands. This is **not** something these patches fix. Choose `danger-full-access` for tool execution on this host.

**`EACCES ... cannot write <file>` from dsh's own file tools** — same root cause as step 4: dsh's atomic write uses `link()`. Writing through `bash` redirection works. Step 4 fixes the session/attachment paths; the generic file tool path is upstream's, not patched here.

**Speech still says `Local speech is unavailable for android-arm64`** — step 6 did not run, or a reinstall wiped it. `./install.sh --check` shows three lines for step 6; if any says `MISSING`/`NOT patched`, re-run `--step 6`.

**`dlopen failed: cannot locate symbol "OrtGetApiBase"`** — the addon loaded before its dependencies. The `addon.js` preload patch is missing; re-run `--step 6`.

**Model download stalls or fails** — the plugin tries `huggingface.co` then `hf-mirror.com`. In mainland China the first is usually unreachable; the probe picks whichever answers first within 3s. To force one origin, set `modelOrigin: https://hf-mirror.com` in the plugin config. Models are fetched on first use from the dsh settings page, not by this script.

**`CMake does not seem to be available`** — this message is misleading. cnoke decides cmake is usable from a single test:

```js
let proc = spawnSync("cmake", ["--version"]);
if (proc.status === 0) { cmake_bin = "cmake" } else { throw ... }
```

So it fires in **two different situations**, and only one of them is about a missing package:

1. **cmake is not installed** → `pkg install cmake`, or `./install.sh --step 0`.
2. **cmake is installed but will not run** — a broken upgrade, a missing shared library, or a stale `$PREFIX/bin/cmake` shadowing a working one. `command -v cmake` succeeds here, so presence checks pass and the build fails anyway.

Step 1 now probes exactly what cnoke probes, and prints cmake's own stderr, so the second case is no longer disguised as the first:

```
err cmake is present but not runnable — cnoke will refuse to build.
       'cmake --version' failed with:
         CANNOT LINK EXECUTABLE "cmake": library "libcmake.so" not found

       If it is genuinely missing:  pkg install cmake
       If it is installed but broken: pkg reinstall cmake
```

There is a **third** case, and it needs a different fix. If `cmake --version` fails at load time with a missing C++ symbol:

```
CANNOT LINK EXECUTABLE "cmake": cannot locate symbol
  "_ZNSt6__ndk113__hash_memoryEPKvm" referenced by ".../bin/cmake"
```

then cmake and libc++ are **out of step** — cmake was built against a newer libc++ than the one installed. `__hash_memory` was added to libc++ in release 21, so an older libc++ produces exactly this. **Reinstalling cmake cannot fix it**, because cmake is not the outdated package; libc++ is. Upgrade both:

```bash
pkg upgrade
```

This is a partial upgrade, not a broken package. It is common when a previous `pkg upgrade` was interrupted, or when cmake was installed on its own against a mirror that had moved ahead of the installed libc++.

To diagnose by hand:

```bash
command -v cmake        # where it resolves — watch for a stale copy earlier in PATH
cmake --version         # what cnoke actually checks; non-zero means "unusable"
ldd "$PREFIX/bin/cmake" # which libc++ it will actually load
pkg upgrade             # fix a cmake/libc++ version skew
pkg reinstall cmake     # only if cmake itself is damaged and libc++ is current
```

`--check` distinguishes the two states:

```
0 toolchain                        complete
0 toolchain                        MISSING: cmake
0 toolchain                        BROKEN: cmake (installed, will not run)
```

**`upstream layout changed`** — a step script found its anchor a number of times other than exactly 1. Upstream moved the code. Do not force it; open an issue with the dsh version.

### Known gaps

**`Could not load the "sharp" module using the android-arm64 runtime`** — image attachments, and the one gap left. It is **not** fixed by anything here, and is not caused by installing with `--ignore-scripts`. Like the two gaps step 8 closes, it is a missing-platform-package problem: `sharp` resolves a per-platform binary that npm can only supply through `optionalDependencies`, and no Android entry exists on the registry.

`sharp@0.35.x` ships no JavaScript fallback and selects a `@img/sharp-<platform>-<arch>` package at runtime; `sharp` declares no `os: ["android"]` in any of them, so npm skips them all and only `@img/colour` is installed. Reached lazily from `@deepseek-ai/dsh-attachment-local`, so the plugin loads and text-only use is unaffected — only the first image normalisation throws. There is no fix in this repository: a working image pipeline would need `sharp` or libvips compiled against bionic, which upstream does not publish.

Two gaps of the same shape **are** fixed now, by step 8 (earlier versions of this file listed them as upstream issues left unpatched):

**`Could not find @vscode/ripgrep-android-arm64`** — the `glob` and `grep` tools fail with `SEARCH_FAILED ... ripgrep launch failed`. `dsh-tool-fs-search` resolves ripgrep through `@vscode/ripgrep`, which requires `@vscode/ripgrep-<platform>-<arch>/bin/rg`; the registry publishes twelve such packages and none targets Android. The fix creates `@vscode/ripgrep-android-arm64/bin/rg` as a symlink onto the `rg` Termux already installs: `require.resolve()` only needs the file to exist, and a symlink means `pkg upgrade ripgrep` also upgrades what dsh runs.

**`write` cannot create a file** — `EACCES ... link '....tmpdir/xxx.tmp' -> 'xxx'`. `dsh-fs-local` publishes every write through a private staging file in the same directory, and the *new file* half goes through `link(2)`; Android SELinux denies hard links outright, so any write whose target does not exist yet fails (replacing an existing file uses `rename(2)` and is unaffected). The fix catches `EACCES`/`EPERM` and retries with `renameat2(RENAME_NOREPLACE)` — atomic, `EEXIST` on collision, the same contract `link`-when-absent provided — using the `system.node` binding step 3 already installs.

Both are lazy: the first write and the first search are what trigger them, never boot. A patched install needs a dsh restart to pick either up.

## How it works

Each step is a separate script in [`scripts/`](scripts/) and can run alone. The installer only orchestrates them and reports.

Patches are applied by **exact-text anchors**, not regex. A step refuses to run when its anchor does not appear exactly once, because a silently misplaced patch in this area corrupts session files under concurrency rather than failing loudly. Failing to patch is the safe outcome.

### Repository layout

```
install.sh                  Entry point: --check / --step / --list / --help
scripts/
  install-dsh.sh            Install dsh (--ignore-scripts), then patch it
  lib.sh                    Shared helpers, module discovery
  step0-deps.sh             Install the toolchain via pkg
  step1-koffi.sh            statx -> fstatat
  step2-require-builtin.sh  Clone source, compile the missing binding
  step3-system.sh           Build/install flock + renameNoReplace, fix guard
  step4-selinux.sh          link() fallbacks
  step5-verify.sh           Load and exercise every binding
  step6-speech.sh           Download upstream Termux release, build the addon
  step7-terminal.sh         Terminal platform gate + install/build the pty binding
  step8-platform-gaps.sh    ripgrep android shim + fs-local link() fallback
  build-require-builtin.sh  Clang command line replicating upstream build.ts
  build-sherpa-addon.sh     Clang command line for the sherpa N-API wrapper
  build-node-pty.sh         Compile node-pty's pty.cc against bionic
src/node-addon-system/
  system.cc                 N-API binding: tryLock, renameNoReplace
  system.node               Prebuilt aarch64 binding (fallback)
src/koffi/
  koffi.node                Prebuilt aarch64 koffi binding, statx excluded
  koffi.json                Version, arch and checksum for the above
src/node-pty/
  pty.node                  Prebuilt aarch64 pty binding, built against bionic
  pty.json                  Version, arch and checksum for the above
patch/
  patch-session-persistence.mjs   Anchored patcher for the two JS packages
  patch-sherpa-addon.mjs          Library preload + sensevoice platform gate
  patch-terminal-android.mjs      Inspector platform gate + node-pty load path
  patch-platform-gaps.mjs         ripgrep android shim + fs-local link() fallback
docs/
  technical-notes.md        Deeper notes on the N-API contracts
```

## Status

Verified on Termux / aarch64 / Node v26.4.0 / clang 21.1.8 with dsh 0.2.1-rc.2, koffi 3.1.1 and sherpa-onnx 1.13.8.

**This is not an officially supported path.** Everything here modifies files inside an installed npm package. Upgrades undo it, upstream test suites do not cover it, and dsh internals may change without notice.

## Reporting an issue

The patches track an unstable target: **a step can stop working because dsh changed, not because this repository broke.** Before filing, pull the latest commit — the fix may already be there.

```bash
cd dsh-termux-fix && git pull && ./install.sh --check
```

That is the only command you need. Paste the whole output: its header carries the commit hash, dsh version, Node version and architecture, so nothing has to be collected by hand. `--check` reports even when dsh is not installed — which is the case most worth filing.

The issue template asks for this. Issues without the header may be closed with a request to re-file after pulling.

## License

MIT — see [LICENSE](LICENSE).
