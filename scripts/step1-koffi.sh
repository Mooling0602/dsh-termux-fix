#!/usr/bin/env bash
# Step 1 — koffi: drop the statx() branch on Android, then rebuild.
#
# koffi's StatAt() calls statx() under #if defined(__linux__). Android's kernel
# supports statx, but the NDK/bionic headers ship neither the statx()
# declaration nor the STATX_* macros, so the build fails. koffi already carries
# an fstatat() fallback; we only need to exclude Android from the statx branch.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DMOD=$(resolve_dsh_modules)
KBASE=$DMOD/koffi
SRC=$KBASE/lib/native/base/base.cc

[ -f "$SRC" ] || die "koffi source not found: $SRC"
KVER=$(node -e "console.log(require('$KBASE/package.json').version)")

info "koffi $KVER"

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

info "compiling koffi (1-2 minutes)"

# cnoke's checkCMake() decides cmake is usable purely from the exit status of
# `cmake --version`:
#
#     let proc = spawnSync("cmake", ["--version"]);
#     if (proc.status === 0) { cmake_bin = "cmake" } else { throw ... }
#
# When that fails it throws "CMake does not seem to be available" — which reads
# as "not installed" but also fires when cmake IS installed and merely fails to
# run (broken link, missing lib, bad PATH entry). Checking `command -v cmake`
# therefore is not equivalent: it passes for a cmake that cannot execute, and
# the build fails later with the same misleading message.
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
ok "compiled"
