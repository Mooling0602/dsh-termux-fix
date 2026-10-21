#!/usr/bin/env bash
# Shared helpers for dsh-termux-fix.
# Sourced by every step script; not meant to be run directly.

set -euo pipefail

# --- Colours (disabled when not a TTY) -------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m';  C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_DIM=''
fi

info()  { printf '%s==>%s %s\n' "$C_BLUE"  "$C_RESET" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%serr %s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; exit 1; }
dim()   { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# --- Locate the installed dsh package --------------------------------------
# Honours $DSH_MODULES, then falls back to the global npm root.
resolve_dsh_modules() {
    if [ -n "${DSH_MODULES:-}" ]; then
        [ -d "$DSH_MODULES/@deepseek-ai" ] || die "DSH_MODULES does not look like a dsh node_modules dir: $DSH_MODULES"
        printf '%s\n' "$DSH_MODULES"
        return
    fi

    local root
    root=$(npm root -g 2>/dev/null || true)
    [ -n "$root" ] || die "Could not run 'npm root -g'. Set DSH_MODULES=/path/to/@deepseek-ai/dsh/node_modules"

    local candidate="$root/@deepseek-ai/dsh/node_modules"
    [ -d "$candidate/@deepseek-ai" ] || die "dsh not found under $root. Install it first, or set DSH_MODULES."
    printf '%s\n' "$candidate"
}

# --- Platform checks ------------------------------------------------------
require_android_or_linux() {
    case "$(uname -s)" in
        Linux|Android) : ;;
        *) die "This tool targets Termux/Android. Detected: $(uname -s)" ;;
    esac
}

require_arm64_note() {
    case "$(uname -m)" in
        aarch64|arm64) : ;;
        *) warn "Architecture is $(uname -m), not arm64. The prebuilt system.node is aarch64 — recompile src/node-addon-system/system.cc for your arch." ;;
    esac
}

# --- dsh version ----------------------------------------------------------
dsh_version() {
    local dmod=$1
    # dmod is <pkg>/node_modules; dsh's own package.json sits one level up.
    local pkg
    pkg=$(dirname "$dmod")/package.json
    if [ -f "$pkg" ]; then
        node -e "console.log(require('$pkg').version)" 2>/dev/null && return
    fi
    printf 'unknown\n'
}

# --- Atomic-ish guarded text patch ---------------------------------------
# Replaces exactly one occurrence, or dies. Idempotent via a caller-supplied
# "already applied" marker check.
patch_once() {
    local file=$1 anchor=$2 replacement=$3 marker=$4 label=$5
    [ -f "$file" ] || die "$label: missing $file"

    if grep -qF -- "$marker" "$file"; then
        ok "$label: already applied"
        return 0
    fi

    local count
    count=$(grep -cF -- "$anchor" "$file" || true)
    if [ "$count" -ne 1 ]; then
        die "$label: anchor found $count times (expected 1). Upstream layout changed."
    fi

    # Use node for literal replacement: sed/awk choke on slashes, quotes and
    # newlines that appear in the anchors.
    node -e '
        const fs = require("node:fs");
        const [file, anchor, replacement] = process.argv.slice(1);
        const src = fs.readFileSync(file, "utf8");
        fs.writeFileSync(file, src.replace(anchor, replacement));
    ' "$file" "$anchor" "$replacement"

    grep -qF -- "$marker" "$file" || die "$label: patch did not take effect"
    ok "$label: patched"
}

export -f info ok warn die dim 2>/dev/null || true
