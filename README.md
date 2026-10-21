# dsh-termux-fix

**Run [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh) on Termux / Android.**

[简体中文](README.zh.md) · English

---

`dsh` is published for linux, macOS and Windows. On Android it starts, then
falls over — differently at each layer. This repository collects the patches
that make it work, as one re-runnable, idempotent installer.

```
$ npm install -g @deepseek-ai/dsh     # 1. install dsh first
$ cd dsh-termux-fix && ./install.sh   # 2. patch the installed package
$ dsh web                             # 3. now boots
```

> **Order matters.** These patches modify files *inside the installed package*,
> so `@deepseek-ai/dsh` must already be installed before you run `install.sh`.
> If dsh is missing, the script stops and tells you to install it. Re-run
> `./install.sh` after **every** `npm install -g @deepseek-ai/dsh`.

## Why it breaks

Android is close enough to Linux to pass every superficial check, and different
enough to fail at six separate points. None of them are configuration problems —
each is a mismatch between what dsh assumes and what Android provides.

| # | Component | Assumption that breaks | Fix |
|---|---|---|---|
| 1 | `koffi` | `statx()` is declared in `<sys/stat.h>` | Exclude Android from the `statx` branch; use the existing `fstatat` fallback |
| 2 | `node-addon-require-builtin` | A prebuilt `android-arm64` binary exists | Compile it from upstream source |
| 3 | `node-addon-system` | A prebuilt `android-arm64` binary exists | Substitute our own minimal N-API binding |
| 4 | session persistence, attachments | `link(2)` works | Replace every `link()` publish with `renameat2` / `copyFile` |
| 5 | verifying the above | — | Load every binding and exercise it |
| 6 | local speech-to-text | An `android-arm64` sherpa-onnx binary exists | Build the N-API addon against upstream's official Termux release |

### Speech: two bugs behind one error

Voice input fails with a single unhelpful line:

```
Error: Local speech is unavailable for android-arm64
```

That message comes from a hardcoded platform allowlist in
`dsh-experimental-speech-to-text-sensevoice`, listing darwin/linux/win32 only.
Adding `android-arm64` to that list is necessary but **not sufficient** — the
next failure is the native dependency:

`sherpa-onnx-node` ships prebuilt binaries for linux, darwin and win32. Its
`linux-arm64` build is dynamically linked against **glibc** (`libc.so.6`,
`ld-linux-aarch64.so.1`, `libstdc++.so.6`). Android uses **bionic**, so that
binary cannot load at all — not a path problem, a different libc.

The way out: upstream publishes an `android-aarch64-termux-shared` release
built against bionic, it just is not distributed through npm. Step 6 downloads
that release, compiles only the thin N-API wrapper against it, and drops both
next to the JS package.

One wrinkle worth knowing: **Android's linker ignores `DT_RPATH` and
`DT_RUNPATH`** — it prints `unused DT entry: DT_RPATH ... (ignoring)` and
carries on. So the addon cannot find its sibling `.so` files by rpath, and the
dsh process does not export `LD_LIBRARY_PATH`. The patch therefore preloads the
two shared libraries with `process.dlopen` before requiring the addon, which
puts them in the global symbol scope where `OrtGetApiBase` can be resolved.

### The interesting one: SELinux blocks `link()`

This is the failure that eats the most time, because it is not an error about
capabilities or filesystems — **Android's SELinux policy denies `link(2)`
outright**, returning `EACCES`/`EPERM` for every call.

dsh uses `link()` in three places, and in all three it is doing something
specific: an **atomic exclusive-create publish**. Linking a staged file to its
final path either succeeds (the file now exists under both names, then the
staged name is dropped) or fails with `EEXIST` because the target is already
there. That is a compare-and-swap, not a copy.

So the replacement cannot be a plain `rename()` — that would silently clobber a
concurrent writer. The two fallbacks preserve the original contract:

| Location | Fallback | Why it is equivalent |
|---|---|---|
| session publish (ESM + CJS) | `renameat2(RENAME_NOREPLACE)` | Kernel-level atomic exclusive create; reports `EEXIST` on collision |
| attachment publish | `copyFile` | Targets are content-addressed (sha256), so a racing duplicate write is byte-identical; the following digest check still guards integrity |

The first needs a syscall that Node's public API does not expose, which is why
step 3 exists at all: `src/node-addon-system/system.cc` is a small N-API binding
that provides both `flock` (dsh needs it) and `renameNoReplace` (our patch needs
it).

## Quick start

```bash
git clone https://github.com/Mooling0602/dsh-termux-fix
cd dsh-termux-fix
./install.sh --check    # see what is missing
./install.sh            # apply everything
```

Then restart `dsh`.

## Usage

```
./install.sh              Apply every step. Idempotent — safe to re-run.
./install.sh --check      Report status of each patch. Changes nothing.
./install.sh --step 3     Run one step only.
./install.sh --list       List steps.
./install.sh --help       Full options.
```

`--check` output looks like this:

```
dsh-termux-fix — status

  dsh version   0.2.1-rc.2
  modules       /data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules
  node          v26.4.0
  platform      Linux aarch64

  1 koffi source                     patched
  2 require-builtin binding          present (245424 bytes)
  3 system binding                   present (8216 bytes)
  3 flock.js guard                   allows android
  4 session-persistence              patched (3 refs)
  4 attachment-local                 patched (2 refs)
  6 sherpa addon                     present (616216 bytes)
  6 sensevoice platform gate         allows android
  6 addon library preload            patched
  6 model files                      downloaded
```

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `DSH_MODULES` | `npm root -g` + `/@deepseek-ai/dsh/node_modules` | Where dsh is installed |
| `DSH_FIX_WORKDIR` | `~/src` | Scratch space for cloned/built sources |
| `NODE_INC` | `$PREFIX/include/node` | Directory containing `node_api.h` |
| `NO_COLOR` | unset | Disable coloured output |

## After every upgrade

> **The patches live inside the installed package and are wiped by any
> reinstall or upgrade.** Re-run `./install.sh` after every
> `npm install -g @deepseek-ai/dsh`.

Only `koffi` needs a real recompile; the other two are N-API v9 and survive
Node upgrades. Step 2 skips work when its binding is already present, so a
plain re-run is cheap.

**Step 6 is the fragile one.** It writes into `sherpa-onnx-node`, which npm
installs as a transitive dependency of the voice-input bundle. A reinstall wipes
the compiled `.node` and the `.so` copies. Worse, if you use pnpm (dsh profiles
do), `pnpm install` rebuilds the store from scratch and will transport you back
to `Local speech is unavailable for android-arm64`. Re-run `./install.sh --step 6`
after any dependency change. The build artefacts stay in
`$DSH_FIX_WORKDIR/sherpa-onnx/`, so the rebuild is a link step, not a download —
unless you cleared that directory.

## Requirements

- Termux on Android, **aarch64** (arm64). The prebuilt `system.node` is
  aarch64-only; other architectures must recompile from `system.cc`. Step 6
  likewise depends on upstream's `android-aarch64` release.
- **`@deepseek-ai/dsh` installed first.** Run
  `npm install -g @deepseek-ai/dsh` before `./install.sh`; these patches edit
  the installed package and have nothing to edit otherwise. Check with
  `npm root -g`.
- Node.js ≥ 20 with headers at `$PREFIX/include/node`
  (`pkg install nodejs` provides both).
- `clang` (`pkg install clang`).
- Network access for steps 2 and 6 (clone/compile sources, fetch the sherpa
  release). Both are skipped when their output is already present.
- For speech, the voice-input bundle enabled in your dsh profile.
  `--check` reports `6 speech package  not installed` if it is missing.

## Troubleshooting

**`Error: dsh: plugin tree failed to load`** — usually a plugin, not these
patches. Check the full stack trace; a missing npm package is unrelated.

**`no sandbox backend is usable on this host`** — Termux has neither
bubblewrap nor a Landlock-enforcing kernel, so dsh's `workspace-write` sandbox
mode refuses to run commands. This is **not** something these patches fix.
Choose `danger-full-access` for tool execution on this host.

**`EACCES ... cannot write <file>` from dsh's own file tools** — same root cause
as step 4: dsh's atomic write uses `link()`. Writing through `bash`
redirection works. Step 4 fixes the session/attachment paths; the generic file
tool path is upstream's, not patched here.

**Speech still says `Local speech is unavailable for android-arm64`** — step 6
did not run, or a reinstall wiped it. `./install.sh --check` shows three lines
for step 6; if any says `MISSING`/`NOT patched`, re-run `--step 6`.

**`dlopen failed: cannot locate symbol "OrtGetApiBase"`** — the addon loaded
before its dependencies. The `addon.js` preload patch is missing; re-run
`--step 6`.

**Model download stalls or fails** — the plugin tries `huggingface.co` then
`hf-mirror.com`. In mainland China the first is usually unreachable; the
probe picks whichever answers first within 3s. To force one origin, set
`modelOrigin: https://hf-mirror.com` in the plugin config. Models are fetched on
first use from the dsh settings page, not by this script.

**`upstream layout changed`** — a step script found its anchor a number of times
other than exactly 1. Upstream moved the code. Do not force it; open an issue
with the dsh version.

## How it works

Each step is a separate script in [`scripts/`](scripts/) and can run alone. The
installer only orchestrates them and reports.

Patches are applied by **exact-text anchors**, not regex. A step refuses to run
when its anchor does not appear exactly once, because a silently misplaced
patch in this area corrupts session files under concurrency rather than failing
loudly. Failing to patch is the safe outcome.

### Repository layout

```
install.sh                  Entry point: --check / --step / --list / --help
scripts/
  lib.sh                    Shared helpers, module discovery
  step1-koffi.sh            statx -> fstatat
  step2-require-builtin.sh  Clone source, compile the missing binding
  step3-system.sh           Build/install flock + renameNoReplace, fix guard
  step4-selinux.sh          link() fallbacks
  step5-verify.sh           Load and exercise every binding
  step6-speech.sh           Download upstream Termux release, build the addon
  build-require-builtin.sh  Clang command line replicating upstream build.ts
  build-sherpa-addon.sh     Clang command line for the sherpa N-API wrapper
src/node-addon-system/
  system.cc                 N-API binding: tryLock, renameNoReplace
  system.node               Prebuilt aarch64 binding (fallback)
patch/
  patch-session-persistence.mjs   Anchored patcher for the two JS packages
  patch-sherpa-addon.mjs          Library preload + sensevoice platform gate
docs/
  technical-notes.md        Deeper notes on the N-API contracts
```

## Status

Verified on Termux / aarch64 / Node v26.4.0 / clang 21.1.8 with dsh 0.2.1-rc.2,
koffi 3.1.1 and sherpa-onnx 1.13.8.

**This is not an officially supported path.** Everything here modifies files
inside an installed npm package. Upgrades undo it, upstream test suites do not
cover it, and dsh internals may change without notice.

## License

MIT — see [LICENSE](LICENSE).
