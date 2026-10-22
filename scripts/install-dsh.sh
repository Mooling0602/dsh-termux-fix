#!/usr/bin/env bash
# dsh-termux-fix — install the packages, then patch them.
#
# A bare `npm install -g @deepseek-ai/dsh` is fatal on Termux/Android: koffi's
# install script compiles C++ and its statx() branch does not compile against
# bionic (base.cc:2967), so the script exits 1 and npm aborts the whole
# transaction — dsh ends up not installed at all. Nothing koffi needs is
# produced by that script on this platform anyway, so the packages are
# installed with --ignore-scripts and ./install.sh supplies every native
# binding afterwards (steps 1, 2, 3, 6 and 7 build or drop in the .node files).
#
# Usage:
#   ./scripts/install-dsh.sh                    install dsh, then patch it
#   ./scripts/install-dsh.sh --with-tui         also install dsh-tui
#   ./scripts/install-dsh.sh --no-patch         install only, do not patch
#   ./scripts/install-dsh.sh @deepseek-ai/dsh@0.2.1-rc.2
#
# Extra arguments are passed to npm as package specs, so a version can be
# pinned without editing this script. This is a separate script rather than a
# flag on install.sh because it has to be runnable *before* dsh exists.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
source "$HERE/scripts/lib.sh"

usage() {
    cat <<'TXT'
scripts/install-dsh.sh — install dsh (and dsh-tui) so it can be patched

USAGE
  ./scripts/install-dsh.sh [options] [package-spec ...]

OPTIONS
  --with-tui       Install @deepseek-harness-tui/dsh-tui in the same
                   transaction as dsh, then patch.
  --no-patch       Install only; skip ./install.sh. dsh will not run until
                   you have patched it.
  -h, --help       Show this help.

PACKAGE SPECS
  Arguments are handed to npm as-is, so `@deepseek-ai/dsh@0.2.1-rc.2` pins a
  version. With no arguments dsh itself is installed at the latest version.

ENVIRONMENT
  npm_config_prefix   Honoured: npm installs and resolves `npm root -g` there.
  DSH_MODULES         Passed through to ./install.sh after the install.
  NO_COLOR            Disable coloured output.

WHY --ignore-scripts
  Skipping lifecycle scripts is not a shortcut, it is the only way the install
  completes: koffi's CNoke build cannot compile on Android, and one failing
  script rolls back the entire global install. The scripts it skips for other
  packages are covered by ./install.sh, and --check reports each binding.
TXT
}

main() {
    local with_tui=0 do_patch=1
    local specs=()
    local arg

    while [ $# -gt 0 ]; do
        case "$1" in
            --with-tui) with_tui=1 ;;
            --no-patch) do_patch=0 ;;
            -h|--help)  usage; exit 0 ;;
            --)         shift; while [ $# -gt 0 ]; do specs+=("$1"); shift; done; break ;;
            -*)         die "unknown option: $1 (try --help)" ;;
            *)          specs+=("$1") ;;
        esac
        shift
    done

    require_android_or_linux

    command -v node >/dev/null 2>&1 || die "node not found. Install Node.js first: pkg install nodejs"
    command -v npm  >/dev/null 2>&1 || die "npm not found. Install Node.js first: pkg install nodejs"

    # dsh is the default target; ask for it explicitly rather than relying on
    # npm's argument order when --with-tui adds a second package.
    if [ ${#specs[@]} -eq 0 ]; then
        specs=("@deepseek-ai/dsh")
    fi
    if [ "$with_tui" -eq 1 ]; then
        local have_tui=0
        for arg in "${specs[@]}"; do
            case "$arg" in @deepseek-harness-tui/dsh-tui*) have_tui=1 ;; esac
        done
        [ "$have_tui" -eq 1 ] || specs+=("@deepseek-harness-tui/dsh-tui")
    fi

    local root
    root=$(npm root -g 2>/dev/null || true)
    [ -n "$root" ] || die "could not determine the global npm root ('npm root -g' failed)"

    if [ -f "$root/@deepseek-ai/dsh/package.json" ]; then
        local cur
        cur=$(node -e 'console.log(require(process.argv[1]).version)' \
              "$root/@deepseek-ai/dsh/package.json" 2>/dev/null || echo '?')
        info "replacing dsh $cur in $root"
        dim "  this wipes every patch — ./install.sh re-applies them below" >&2
    else
        info "installing into $root"
    fi

    # --ignore-scripts is load-bearing, not a speed-up. See the header comment.
    printf '\n'
    info "npm install -g --ignore-scripts ${specs[*]}"
    npm install -g --ignore-scripts "${specs[@]}"

    printf '\n'
    local dmod=$root/@deepseek-ai/dsh/node_modules
    [ -d "$dmod/@deepseek-ai" ] \
        || die "npm reported success but there is no dsh under $root — check 'npm config get prefix'"
    ok "dsh $(dsh_version "$dmod") installed"

    if [ "$do_patch" -eq 0 ]; then
        printf '\n'
        info "next: ./install.sh    (dsh does not run until the patches are applied)"
        exit 0
    fi

    # Hand install.sh the tree that was just written, so a custom npm prefix is
    # honoured even when it differs from the default one.
    printf '\n'
    DSH_MODULES="$dmod" bash "$HERE/install.sh"

    printf '\n'
    ok "ready — start it with: dsh web"
}

main "$@"
