#!/usr/bin/env bash
# Step 1 — koffi: make the native binding usable on Android.
#
# koffi's StatAt() calls statx() under #if defined(__linux__). Android's kernel
# supports statx, but the NDK/bionic headers ship neither the statx()
# declaration nor the STATX_* macros, so a stock build fails. koffi already
# carries an fstatat() fallback; only the statx branch has to be excluded.
#
# Two ways to get such a binding, in order of preference:
#
#   1. Our prebuilt src/koffi/koffi.node, compiled once from the patched source.
#   2. Compile it here from the patched source, which needs cmake (cnoke's
#      build frontend).
#
# The prebuilt comes first because needing cmake at all is a liability on
# Termux: issues #1 and #2 were both cmake problems (absent, then built against
# a newer libc++ than installed), and neither touches koffi's actual behaviour.
# cnoke short-circuits on a valid prebuilt via checkPrebuild(), so with one in
# place the compiler and cmake are never invoked.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")

DMOD=$(resolve_dsh_modules)
KBASE=$DMOD/koffi
SRC=$KBASE/lib/native/base/base.cc
PREBUILT=$ROOT/src/koffi

[ -f "$SRC" ] || die "koffi source not found: $SRC"
KVER=$(node -e "console.log(require('$KBASE/package.json').version)")

info "koffi $KVER"

# koffi resolves its binding from build/koffi/<platform>_<arch>/koffi.node.
install_dir() {
    local arch
    case "$(uname -m)" in
        aarch64|arm64) arch=arm64 ;;
        x86_64|amd64)  arch=x64 ;;
        armv7l|arm)    arch=arm ;;
        *)             return 1 ;;
    esac
    printf '%s/build/koffi/android_%s\n' "$KBASE" "$arch"
}

# Exactly what cnoke's checkPrebuild() does — require the package and see
# whether it loads. Anything else would test a different property.
binding_loads() {
    ( cd "$KBASE" && node -e 'require(process.argv[1])' "$KBASE" >/dev/null 2>&1 )
}

BINDING_DIR=$(install_dir) || BINDING_DIR=

# --- 1. prebuilt -------------------------------------------------------------
if [ -n "$BINDING_DIR" ] && [ -f "$PREBUILT/koffi.node" ] && [ -f "$PREBUILT/koffi.json" ]; then
    PB_VER=$(node -e 'console.log(require(process.argv[1]).koffiVersion)' "$PREBUILT/koffi.json" 2>/dev/null || true)
    PB_ARCH=$(node -e 'console.log(require(process.argv[1]).arch)' "$PREBUILT/koffi.json" 2>/dev/null || true)
    PB_SHA=$(node -e 'console.log(require(process.argv[1]).sha256)' "$PREBUILT/koffi.json" 2>/dev/null || true)

    # Normalise both sides: uname says aarch64 or arm64 depending on the build,
    # and the metadata may use either spelling of the same architecture.
    normalise_arch() {
        case "$1" in
            aarch64|arm64)    printf 'aarch64\n' ;;
            x86_64|amd64|x64) printf 'x86_64\n' ;;
            armv7l|arm)       printf 'arm\n' ;;
            *)                printf '%s\n' "$1" ;;
        esac
    }
    local_arch=$(normalise_arch "$(uname -m)")
    PB_ARCH_N=$(normalise_arch "$PB_ARCH")

    # A prebuilt is only usable when it was built for this koffi release and
    # this architecture. The checksum is a corruption check, not a gate: if it
    # cannot be computed, still try the binding and let the load decide.
    if [ "$PB_VER" != "$KVER" ]; then
        dim "  prebuilt is for koffi $PB_VER, installed is $KVER — not using it"
    elif [ "$PB_ARCH_N" != "$local_arch" ]; then
        dim "  prebuilt is for $PB_ARCH, this machine is $local_arch — not using it"
    else
        usable=1
        if [ -n "$PB_SHA" ] && command -v sha256sum >/dev/null 2>&1; then
            actual=$(sha256sum "$PREBUILT/koffi.node" | cut -d' ' -f1)
            [ "$actual" = "$PB_SHA" ] || usable=0
        fi

        if [ "$usable" -eq 0 ]; then
            warn "prebuilt koffi.node does not match its recorded checksum — ignoring it"
        else
            mkdir -p "$BINDING_DIR"
            cp "$PREBUILT/koffi.node" "$BINDING_DIR/koffi.node"
            if binding_loads; then
                ok "installed prebuilt binding (koffi $KVER, no statx)"
                exit 0
            fi
            warn "prebuilt binding did not load — falling back to compiling"
        fi
    fi
fi

# --- 2. compile from patched source -----------------------------------------
info "compiling koffi from source (1-2 minutes)"

# Idempotency: inspect the FIRST #if inside StatAt() specifically.
# A whole-file grep for __ANDROID__ is wrong — this file contains unrelated
# occurrences, and StatAt's body holds a second #if defined(__linux__) that
# must NOT be touched (it computes st_mtim manually, no statx involved).
first_if_in_statat() {
    awk '/^static StatResult[[:space:]]+StatAt\(/ { infn = 1; next }
         infn && /^#if defined/ { print; exit }' "$SRC"
}

current=$(first_if_in_statat)
[ -n "$current" ] || die "no #if found inside StatAt() — upstream layout changed"

case "$current" in
    *__ANDROID__*)
        ok "source already patched"
        ;;
    *)
        # done=1 stops the scan immediately after the first rewrite, so we can
        # never reach the second #if further down the function body.
        awk 'BEGIN { infn = 0; done = 0 }
             /^static StatResult[[:space:]]+StatAt\(/ { infn = 1 }
             infn && !done && /^#if defined\(__linux__\)$/ {
                 print "#if defined(__linux__) && !defined(__ANDROID__)"; done = 1; next
             }
             { print }' "$SRC" > "$SRC.new"
        mv "$SRC.new" "$SRC"

        case "$(first_if_in_statat)" in
            *__ANDROID__*) ok "source patched" ;;
            *) die "patch verification failed" ;;
        esac
        ;;
esac

# cnoke's checkCMake() decides cmake is usable purely from the exit status of
# `cmake --version`:
#
#     let proc = spawnSync("cmake", ["--version"]);
#     if (proc.status === 0) { cmake_bin = "cmake" } else { throw ... }
#
# When that fails it throws "CMake does not seem to be available" — which reads
# as "not installed" but also fires when cmake IS installed and merely fails to
# run. Checking `command -v cmake` is not equivalent: it passes for a cmake that
# cannot execute, and the build then fails with that same misleading message.
#
# So probe the same way cnoke does, and surface cmake's own stderr when it
# fails — that is what actually identifies the problem.
if ! cmake_probe=$(cmake --version 2>&1); then
    # A dynamic-linker failure naming a missing C++ symbol means cmake and
    # libc++ are out of step: cmake was built against a newer libc++ than the
    # one installed. Reinstalling cmake cannot fix that, because cmake is not
    # the outdated package — libc++ is. Seen in issue #2:
    #
    #   CANNOT LINK EXECUTABLE "cmake": cannot locate symbol
    #   "_ZNSt6__ndk113__hash_memoryEPKvm" referenced by ".../bin/cmake"
    #
    # (__hash_memory was added to libc++ in release 21, so an older libc++
    # than the cmake build expects produces exactly this.)
    if printf '%s' "$cmake_probe" | grep -qE 'cannot locate symbol|CANNOT LINK EXECUTABLE'; then
        die "cmake cannot start: it needs a newer libc++ than is installed.
       This is a partial upgrade, not a broken cmake — reinstalling cmake
       will not help, because libc++ is the outdated package.

         $(printf '%s' "$cmake_probe" | head -2 | tr -s ' \n' ' ')

       Fix: pkg upgrade      (upgrades libc++ and cmake together)
       Then re-run: ./install.sh --step 1"
    fi

    die "cmake is present but not runnable — cnoke will refuse to build.
       'cmake --version' failed with:
         $(printf '%s' "$cmake_probe" | head -3 | tr '\n' ' ')

       If it is genuinely missing:  pkg install cmake
       If it is installed but broken: pkg reinstall cmake
       Or run: ./install.sh --step 0"
fi

( cd "$KBASE" && node ./cnoke.cjs -P . -D src/koffi --prebuild --release >/dev/null ) \
    || die "koffi build failed (see the 'Error:' line above for the underlying cause)"

binding_loads || die "build finished but koffi still does not load"
ok "compiled"
