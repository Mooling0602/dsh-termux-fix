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
( cd "$KBASE" && node ./cnoke.cjs -P . -D src/koffi --prebuild --release >/dev/null ) \
    || die "koffi build failed"
ok "compiled"
