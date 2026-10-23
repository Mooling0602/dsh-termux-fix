# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.12.0] — 2026-10-24

### Added

- **Step 9 (`scripts/step9-vision.sh`): image attachments work — `sharp` now runs as WebAssembly.** `read_image` and every uploaded image are normalised by `dsh-attachment-local`, which requires `sharp` on the first raster operation; on android-arm64 that require died with `Could not load the "sharp" module using the android-arm64 runtime`. `sharp@0.35.x` selects a native binding from a per-platform optional dependency (`@img/sharp-<platform>-<arch>`), the registry publishes 25 of them (15 bindings plus 10 libvips companions), none targets Android, and npm filters out every one that does not match the host — the same missing-platform-package shape step 8 closed for ripgrep, and unaffected either way by `--ignore-scripts`. sharp's loader already ends with a fallback that upstream documents for platforms without a native build, `require("@img/sharp-wasm32/sharp.node")` — libvips compiled to WebAssembly — but that package is not an optional dependency, so npm never installed it. Step 9 fetches `@img/sharp-wasm32` **at exactly the installed sharp version** together with its `@emnapi/runtime` bridge and `tslib`, stages them with `npm install` outside the dsh tree, and copies them in beside `sharp`. Installing in place is deliberately avoided: any npm operation against the dsh tree reconciles it against the lockfile and prunes what it did not install itself, including the compiled bindings from steps 1–3. The step then loads sharp, encodes/decodes/resizes a tiny PNG, and finishes with a full attachment save → verified read round-trip on a throwaway root, which catches a missing step 4 patch here instead of at the first user image.
- **`9 image attachments` in `--check`, and `--step 9` / `--list` entries.** `run_step()`, `--help` and `--list` accept 0-9; the status line reports whether sharp loads and whether it loads through the WebAssembly fallback or a native binding.

### Fixed

- **Every attachment write failed on Termux before `sharp` was ever reached.** `dsh-attachment-local` makes a written attachment durable by fsyncing *every ancestor directory from the attachment home up to the filesystem root*; Android denies opening `/data/data` (mode 0711, system-owned), so the walk threw `EACCES: permission denied, open '/data/data'` and no attachment — image or plain file — could be published at all. The step 4 patcher now wraps that walk: `EACCES`/`EPERM` from an ancestor means the process may not go higher, so the walk stops at the app's private root instead of failing the write. Everything from the attachment home down is already synced, and the unreadable entries above it belong to the package manager. This was invisible while the first image died earlier, inside `sharp`, but it also broke ordinary file uploads.
- **`4 attachment-local` in `--check` is now two lines** — the `link()` fallback and the durable-walk patch are reported separately, so a half-patched attachment store is visible instead of a ref count that only says "patched".

## [1.11.0] — 2026-10-23

### Added

- **Step 8 (`scripts/step8-platform-gaps.sh` + `patch/patch-platform-gaps.mjs`): the two remaining "missing platform package" gaps are now fixed instead of merely documented.** Both had the same shape as the `sharp` gap — a dependency resolves a per-platform binary through `require.resolve()` and the registry publishes no Android entry — but unlike `sharp` both have a working substitute available locally, and both failed lazily at the first tool call, so they read like this project's bug.
- **`@vscode/ripgrep-android-arm64` shim.** `dsh-tool-fs-search` resolves ripgrep out of `@vscode/ripgrep`, which requires `<platform package>/bin/rg`; the twelve published platform packages include no Android one, so `glob` and `grep` died with `SEARCH_FAILED ... ripgrep launch failed`. Step 8 writes `bin/rg` as a **symlink** onto the `rg` Termux already ships (`$PREFIX/bin/rg`, else `/data/data/com.termux/files/usr/bin/rg`), which is all `require.resolve()` needs — and being a symlink means `pkg upgrade ripgrep` upgrades what dsh runs, instead of pinning a stale copy. The patcher then re-resolves through `@vscode/ripgrep`'s own entry point and runs `rg --version`, so a shim that exists but does not execute fails the step rather than the first search.
- **`dsh-fs-local` `link()` fallback.** `writeFileAtomic` publishes every write through a private staging file in the destination directory, and the *new file* half of that is `link(2)`. Android SELinux denies hard links outright, so `write` failed with `EACCES ... link '....tmpdir/xxx.tmp' -> 'xxx'` for **every file that did not already exist** — the tool could edit a file but not create one. Replacing an existing file uses `rename(2)` and was never affected, which is why the failure looked like a permissions problem on one path. The patch catches `EACCES`/`EPERM` and retries with `renameat2(RENAME_NOREPLACE)` through the `system.node` binding step 3 installs: atomic, `EEXIST` on collision — the same contract `link`-when-absent gave the caller — and it reuses the existing `throwGuardedCreateFailure` path so a real race still reports `FS_NOT_OBSERVED`.

### Fixed

- **`--help` and both READMEs advertised `--step N (0-7)`** while step 8 now exists; `run_step()` accepts 0-8.
- **Known-gaps sections in both READMEs rewritten.** `sharp` remains the only unfixable gap; the ripgrep and `write` entries moved from "tracked upstream, not patched here" to the fixes above, with the restart requirement called out — both are patched in the installed package, so a running dsh keeps the old code until it restarts.

## [1.10.0] — 2026-10-22

### Added

- **`scripts/install-dsh.sh`: install dsh and patch it in one command.** `./scripts/install-dsh.sh` runs `npm install -g --ignore-scripts @deepseek-ai/dsh` and then `./install.sh` against the tree it just wrote; `--with-tui` adds `@deepseek-harness-tui/dsh-tui` to the same transaction, `--no-patch` stops after the install, and any remaining argument is passed to npm as a package spec so a version can be pinned (`@deepseek-ai/dsh@0.2.1-rc.2`). It resolves the target through `npm root -g`, so `npm_config_prefix` is honoured, and it hands `DSH_MODULES` to `install.sh` so a non-default prefix patches the tree it just installed instead of the default one.

### Fixed

- **A plain `npm install -g @deepseek-ai/dsh` does not work on Termux/Android, and both READMEs said to run exactly that.** koffi's `install` lifecycle hook runs CNoke, which compiles `lib/native/base/base.cc`; its `statx()` branch cannot compile against bionic (`cannot initialize a member subobject of type '__u32' ... with an lvalue of type 'const char *'`, base.cc:2967), so the hook exits 1 and npm rolls the entire global install back — dsh ends up not installed at all. Nothing the hook would have produced is usable on Android anyway: koffi publishes no `android-arm64` prebuilt, so the hook can only attempt that same doomed compile. `--ignore-scripts` is therefore required, and every binding the skipped hooks would have produced is supplied by steps 1, 2, 3, 6 and 7. Documented in both READMEs (new "Installing dsh by hand" section) and in `--help`.
- **Installing a second global package that pulls dsh in — `dsh-tui` is one — hits the same hook.** Both READMEs now say to pass `--ignore-scripts` there too, and to re-run `./install.sh` afterwards, because that install wipes the existing patches.
- **Documented two pre-existing gaps that nothing here fixes, and that `--ignore-scripts` does not cause.** Both are missing-platform-package failures: `sharp` (image attachments, lazily reached from `dsh-attachment-local`) and `@vscode/ripgrep` (`glob`/`grep`, via `dsh-tool-fs-search`) resolve per-platform binaries that npm can only supply through `optionalDependencies`, and the registry publishes no Android entry for either — twelve `@vscode/ripgrep-*` packages, none for Android; `sharp`'s `@img/*` packages declare no `os: ["android"]`, so npm filters them all out. Neither package declares a lifecycle script, so neither is affected by skipping them either way. Both fail lazily at first use, not at boot; a curated `packages`/`os` entry or a locally compiled binding is the only real fix, and both need work upstream. Recorded in the troubleshooting section of both READMEs instead of being silently left to look like this project's bug.
- **`--help` still advertised `--step N (0-6)`** while `run_step()` accepted 0-7 (step 7 landed in 1.9.0 and the STEPS list was extended but the option line was not). Both READMEs repeated the stale range in their usage blocks.

## [1.9.1] — 2026-10-21

### Fixed

- **The node-pty loader half of step 7 was unnecessary and is gone.** node-pty's loader already scans `prebuilds/<platform>-<arch>/pty.node`, so `prebuilds/android-arm64/` is in the candidate list before any patch; the only thing missing was a bionic binary at that path. The patch had appended `prebuilds/linux-arm64` as a fallback, which is the glibc build the docs call unusable, and it made failures worse: the loader reports the last error it hit, so a missing binding surfaced as `Cannot find module './prebuilds/linux-arm64/pty.node'` instead of naming the path actually absent. `patch-terminal-android.mjs` now patches only the inspector gate, and `--check` no longer reports a loader line.
- **`--help` no longer omits step 6.** Adding step 7 replaced the `6 speech` line in the STEPS list instead of appending after it.
- **The inspector file is resolved, not hardcoded.** Its name carries a dsh build hash (`runner-launch-<hash>.js`), so a rebuild would have produced a raw `ENOENT` stack trace instead of the intended `upstream layout changed` message. Both the patcher and `--check` now glob the name and fail cleanly when the count is not one.

## [1.9.0] — 2026-10-21

### Added

- **Persistent terminals now work on Termux/Android** (step 7). Opening a terminal previously failed with a single line, `terminal inspection is unsupported on platform android`, which concealed two unrelated defects. Both are fixed: `createProcessInspector()` accepts `android` and routes it through its existing `LinuxProcessInspector` (`process.platform` is `android` on Termux, but `/proc` and the arm64 syscall numbers it reads are the same as Linux). node-pty needs no patch at all: its loader already scans `prebuilds/<platform>-<arch>/pty.node`, a directory upstream simply does not publish, so supplying a bionic build at that path is the entire fix.
- **Prebuilt pty binding** (`src/node-pty/pty.node`, 97 KB) compiled from unmodified upstream `src/unix/pty.cc` against bionic, with `pty.json` recording version, architecture and checksum. The stock `linux-arm64` prebuild cannot be reused because it links glibc's `libutil.so.1`, which bionic does not provide. Step 7 prefers the prebuilt and only invokes the toolchain when the version, architecture or checksum does not match.
- `scripts/build-node-pty.sh` compiles the binding locally as a fallback, and `--check` reports the terminal gate and the binding (distinguishing prebuilt from locally compiled) as separate lines, so a partial fix is visible.

### Fixed

- Step 7 proves the terminal works by forking a shell and reading its echo back, rather than only `require()`ing the binding: loading the `.node` does not demonstrate that `forkpty(3)` works on bionic.

## [1.8.0] — 2026-10-21

### Added

- An `[!IMPORTANT]` alert near the top of both READMEs stating that only the **latest** `@deepseek-ai/dsh` release is supported. Patches are anchored to exact text inside the installed package and those anchors move between releases, so after a dsh update you have to `git pull` for matching patches or wait for adaptation. It also notes that a mismatched anchor exits with `upstream layout changed` rather than patching the wrong place.

## [1.7.0] — 2026-10-21

### Changed

- **Every Markdown file is unwrapped.** Each paragraph, blockquote and list item now occupies a single line, so no line break falls inside a sentence. Applies to both languages. GitHub renders a soft break between two CJK characters as `<br>`, which made wrapped Chinese read as though it had stray spaces mid-sentence; one rule for all files keeps the two language versions symmetrical.

## [1.6.0] — 2026-10-21

### Added

- **Prebuilt koffi binding** (`src/koffi/koffi.node`, 1.1 MB) compiled once from the patched source, with `koffi.json` recording version, architecture and checksum. Step 1 installs it and verifies that it loads — the same test cnoke's `checkPrebuild()` performs — and only compiles from source when the version, architecture or checksum does not match.

### Changed

- **cmake is no longer required for step 1.** cnoke short-circuits on a valid prebuilt, so neither the compiler nor cmake is invoked when the binding fits. This removes the single least reliable dependency on Termux: issues #1 and #2 were both cmake failures (absent, then built against a newer libc++ than installed) and neither concerned koffi's behaviour.
- `--check` reports `1 koffi binding  loads (koffi <version>)` instead of inspecting whether the source carries the patch. How the binding was obtained is no longer the interesting question — whether it loads is.

### Fixed

- Step 1 verifies the binding after a source build too, so a build that succeeds but produces an unloadable binary no longer reports `ok compiled`.

## [1.5.0] — 2026-10-21

### Fixed

- **Corrected the advice for a cmake/libc++ version skew.** The previous entry told users to run `pkg reinstall cmake` when `cmake --version` failed. That is wrong for the most common cause: if the failure is a missing C++ symbol (`cannot locate symbol "_ZNSt6__ndk113__hash_memoryEPKvm"`), cmake is fine and the outdated package is **libc++** — `__hash_memory` only arrived in libc++ 21. Reinstalling cmake cannot help; `pkg upgrade` upgrades both together. Reported and confirmed in issue #2.

### Added

- Step 0 and step 1 recognise the dynamic-linker signature (`CANNOT LINK EXECUTABLE` / `cannot locate symbol`) and report it as a partial upgrade with the `pkg upgrade` remedy, instead of the generic "installed but not runnable" text.
- Troubleshooting now separates three distinct causes for the same cnoke error: not installed, installed but damaged, and installed but behind libc++.

## [1.4.0] — 2026-10-21

### Fixed

- **`CMake does not seem to be available` also fires when cmake is installed but unrunnable.** cnoke's `checkCMake()` judges cmake solely by the exit status of `cmake --version`. A broken install — interrupted upgrade, missing shared library, or a stale `$PREFIX/bin/cmake` shadowing a working one — produces the identical message, which reads as "not installed". Step 1 previously guarded with `command -v cmake`, which passes in exactly that case, so the build failed with the same misleading text.
- Step 1 now probes with `cmake --version` — the same test cnoke uses — and reports cmake's own stderr, distinguishing "missing" from "broken".
- Step 0 verifies `cmake`, `clang` and `git` actually execute after installing, including on the all-present fast path, and fails with `pkg reinstall ...` rather than leaving it for a later step.
- `--check` gained a `BROKEN:` state alongside `MISSING:`, so an installed but unrunnable tool is visible before any build starts.

## [1.3.0] — 2026-10-21

### Added

- **Issue template** (`.github/ISSUE_TEMPLATE/bug_report.yml`) that makes the commit hash a required field, alongside `--check` output and versions.
- `--check` prints `commit <short-hash>` first, so the exact revision travels with any pasted report.
- `warn_if_stale` prints an advisory warning when the checkout is behind its upstream branch, prompting a `git pull` before a stale bug is reported. Silent when git is absent, the directory is not a repo, or no upstream is configured; it never fails a run.
- **"Reporting an issue"** section in both READMEs, explaining why pulling first matters and how to obtain the short hash.

## [1.2.0] — 2026-10-21

### Added

- **Step 0: install the toolchain.** `scripts/step0-deps.sh` runs `pkg install` for `clang`, `cmake`, `make`, `git`, `tar` and `curl`, and is a no-op when all of them are present. It runs first in the default flow.
- `--check` reports `0 toolchain`, listing only the packages that are actually missing.

### Fixed

- **Issue #1 — a missing `cmake` produced an unreadable failure.** Step 1 shelled out to koffi's `cnoke.cjs`, which throws `CMake does not seem to be available` from inside its stack; the script reduced that to `koffi build failed`, with no hint about what to install. Step 1 now checks for `cmake` up front and names the fix (`pkg install cmake`, or `./install.sh --step 0`), and the generic failure message points at the underlying error.

## [1.1.0] — 2026-10-21

### Added

- **Step 6: local speech-to-text.** Voice input previously failed with `Local speech is unavailable for android-arm64`. Two independent causes: the sensevoice package allowlists only darwin/linux/win32, and `sherpa-onnx-node` has no android build at all — its `linux-arm64` binary is linked against glibc (`libc.so.6`, `ld-linux-aarch64.so.1`) and cannot load on Android's bionic libc.
- `scripts/step6-speech.sh` downloads upstream's `android-aarch64-termux-shared` release (a bionic build, published on GitHub but not through npm), compiles only the N-API wrapper, and installs both.
- `scripts/build-sherpa-addon.sh` — the clang command line for that wrapper.
- `patch/patch-sherpa-addon.mjs` — two anchored rewrites: the sensevoice platform allowlist, and a `process.dlopen` preload in `addon.js`.

### Fixed

- **Android's linker ignores `DT_RPATH`/`DT_RUNPATH`.** Emitting an rpath on a native addon does nothing on Android — the loader prints `unused DT entry: DT_RPATH ... (ignoring)`. The addon therefore cannot find its sibling `.so` files, and dsh does not export `LD_LIBRARY_PATH`. The preload in `addon.js` is the fix. Note that `process.dlopen` on a plain shared library throws `Module did not self-register` — expected, harmless, and swallowed on purpose.

### Changed

- Duplicate retry logic for slow networks replaced with mirror fallbacks (`gh-proxy.com`, `ghproxy.net`) in step 6.
- Documented that `npm install -g @deepseek-ai/dsh` is a **prerequisite**, not something the installer does.

## [1.0.0] — 2026-10-21

Initial release. Collected, verified and packaged the set of patches needed to run `@deepseek-ai/dsh` on Termux/Android.

### Added

- `install.sh` entry point with `--check`, `--step N`, `--list` and `--help`.
- Five independent, idempotent step scripts under `scripts/`.
- `src/node-addon-system/system.cc` — minimal N-API binding implementing `tryLock(fd, cb)` and `renameNoReplace(old, new, cb)`.
- `src/node-addon-system/system.node` — prebuilt aarch64 binding.
- `patch/patch-session-persistence.mjs` — SELinux `link()` fallbacks for session persistence and attachments.
- English and Chinese documentation.

### Fixed relative to the original ad-hoc scripts

- **koffi step never worked.** The original `awk` anchor `/^static StatResult\(/` cannot match the real signature `static StatResult StatAt(`. The script output the file unchanged, and its own `grep -q "StatAt"` check looked for the *function*, not the *patch*, so the failure was invisible. Fixing the anchor alone is not enough either: `StatAt`'s body contains a second `#if defined(__linux__)` (around line 3048) that must not be touched. The rewrite now locks after the first replacement and verifies from the function body.
- **`flock.js` platform guard was not idempotent.** The original `sed` re-matched its own output, appending another `&& platform !== 'android'` on every run. The check now runs first and the patch is skipped when present.
- **Hard-coded install paths replaced** with `npm root -g` discovery plus a `DSH_MODULES` override.
- **Prebuilt fallback** for `system.node` when compilation is unavailable.

### Verified on

- Termux, aarch64, Android
- Node v26.4.0, clang 21.1.8
- koffi 3.1.1, dsh 0.2.1-rc.2
