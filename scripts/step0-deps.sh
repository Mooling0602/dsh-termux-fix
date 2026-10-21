#!/usr/bin/env bash
# Step 0 — install the toolchain the later steps need.
#
# Every other step shells out to something that may not be present: clang to
# compile, cmake for koffi's cnoke frontend, git to clone upstream sources.
# When one is missing the failure surfaces much later and says something
# unhelpful (see issue #1: "koffi build failed", with the actual cause "CMake
# does not seem to be available" buried in a stack trace).
#
# This step is a no-op when everything is already installed, so it is cheap to
# keep in the default run.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/lib.sh"

# package -> why we need it
# Keep this in sync with the checks in --check and with what the steps use.
DEPS="
clang:compiling every native binding (steps 1, 2, 3, 6)
cmake:koffi's cnoke build frontend (step 1)
make:build orchestration used by cnoke
git:cloning upstream sources (step 2)
nodejs:the runtime itself, and node_api.h
tar:unpacking release archives (steps 2, 6)
curl:downloading sources and releases (steps 2, 6)
"

info "toolchain"

MISSING=()
PRESENT=0

while IFS=: read -r pkg why; do
    [ -n "$pkg" ] || continue
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        PRESENT=$((PRESENT + 1))
    else
        MISSING+=("$pkg")
        dim "  missing: $pkg ($why)"
    fi
done <<< "$DEPS"

if [ ${#MISSING[@]} -eq 0 ]; then
    ok "all $PRESENT packages present"
    exit 0
fi

if ! command -v pkg >/dev/null 2>&1; then
    die "missing packages: ${MISSING[*]} — and 'pkg' is not available to install them"
fi

info "installing ${#MISSING[@]} package(s): ${MISSING[*]}"

# -y avoids the interactive prompt; Termux's pkg maps onto apt.
if ! pkg install -y "${MISSING[@]}"; then
    printf '\n' >&2
    warn "pkg install failed"
    dim "  If this is a mirror problem, try:" >&2
    dim "    termux-change-repo" >&2
    dim "  Then re-run: ./install.sh --step 0" >&2
    exit 1
fi

# Verify rather than trust the exit code: pkg can succeed while a package is
# still absent (held, replaced, or a virtual package name).
STILL=()
for pkg in "${MISSING[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || STILL+=("$pkg")
done

if [ ${#STILL[@]} -gt 0 ]; then
    die "still missing after install: ${STILL[*]}"
fi

ok "installed ${MISSING[*]}"
