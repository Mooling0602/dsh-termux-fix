# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
