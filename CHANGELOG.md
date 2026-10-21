# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.2.0] — 2026-10-21

### Added

- **Step 0: install the toolchain.** `scripts/step0-deps.sh` runs
  `pkg install` for `clang`, `cmake`, `make`, `git`, `tar` and `curl`, and is a
  no-op when all of them are present. It runs first in the default flow.
- `--check` reports `0 toolchain`, listing only the packages that are actually
  missing.

### Fixed

- **Issue #1 — a missing `cmake` produced an unreadable failure.** Step 1
  shelled out to koffi's `cnoke.cjs`, which throws
  `CMake does not seem to be available` from inside its stack; the script
  reduced that to `koffi build failed`, with no hint about what to install.
  Step 1 now checks for `cmake` up front and names the fix
  (`pkg install cmake`, or `./install.sh --step 0`), and the generic failure
  message points at the underlying error.

## [1.1.0] — 2026-10-21

### Added

- **Step 6: local speech-to-text.** Voice input previously failed with
  `Local speech is unavailable for android-arm64`. Two independent causes:
  the sensevoice package allowlists only darwin/linux/win32, and
  `sherpa-onnx-node` has no android build at all — its `linux-arm64` binary is
  linked against glibc (`libc.so.6`, `ld-linux-aarch64.so.1`) and cannot load
  on Android's bionic libc.
- `scripts/step6-speech.sh` downloads upstream's
  `android-aarch64-termux-shared` release (a bionic build, published on GitHub
  but not through npm), compiles only the N-API wrapper, and installs both.
- `scripts/build-sherpa-addon.sh` — the clang command line for that wrapper.
- `patch/patch-sherpa-addon.mjs` — two anchored rewrites: the sensevoice
  platform allowlist, and a `process.dlopen` preload in `addon.js`.

### Fixed

- **Android's linker ignores `DT_RPATH`/`DT_RUNPATH`.** Emitting an rpath on a
  native addon does nothing on Android — the loader prints
  `unused DT entry: DT_RPATH ... (ignoring)`. The addon therefore cannot find
  its sibling `.so` files, and dsh does not export `LD_LIBRARY_PATH`. The
  preload in `addon.js` is the fix. Note that `process.dlopen` on a plain
  shared library throws `Module did not self-register` — expected, harmless,
  and swallowed on purpose.

### Changed

- Duplicate retry logic for slow networks replaced with mirror fallbacks
  (`gh-proxy.com`, `ghproxy.net`) in step 6.
- Documented that `npm install -g @deepseek-ai/dsh` is a **prerequisite**, not
  something the installer does.

## [1.0.0] — 2026-10-21

Initial release. Collected, verified and packaged the set of patches needed to
run `@deepseek-ai/dsh` on Termux/Android.

### Added

- `install.sh` entry point with `--check`, `--step N`, `--list` and `--help`.
- Five independent, idempotent step scripts under `scripts/`.
- `src/node-addon-system/system.cc` — minimal N-API binding implementing
  `tryLock(fd, cb)` and `renameNoReplace(old, new, cb)`.
- `src/node-addon-system/system.node` — prebuilt aarch64 binding.
- `patch/patch-session-persistence.mjs` — SELinux `link()` fallbacks for
  session persistence and attachments.
- English and Chinese documentation.

### Fixed relative to the original ad-hoc scripts

- **koffi step never worked.** The original `awk` anchor `/^static StatResult\(/`
  cannot match the real signature `static StatResult StatAt(`. The script
  output the file unchanged, and its own `grep -q "StatAt"` check looked for
  the *function*, not the *patch*, so the failure was invisible.
  Fixing the anchor alone is not enough either: `StatAt`'s body contains a
  second `#if defined(__linux__)` (around line 3048) that must not be touched.
  The rewrite now locks after the first replacement and verifies from the
  function body.
- **`flock.js` platform guard was not idempotent.** The original `sed`
  re-matched its own output, appending another `&& platform !== 'android'` on
  every run. The check now runs first and the patch is skipped when present.
- **Hard-coded install paths replaced** with `npm root -g` discovery plus a
  `DSH_MODULES` override.
- **Prebuilt fallback** for `system.node` when compilation is unavailable.

### Verified on

- Termux, aarch64, Android
- Node v26.4.0, clang 21.1.8
- koffi 3.1.1, dsh 0.2.1-rc.2
