# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
