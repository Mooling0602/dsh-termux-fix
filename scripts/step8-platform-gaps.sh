#!/usr/bin/env bash
# Step 8 — the two "missing platform package" gaps.
#
# Both are the same shape: a dependency resolves a per-platform binary through
# require.resolve(), and the npm registry publishes no Android entry, so the
# resolution throws lazily at the first use. Neither is caused (or fixed) by
# --ignore-scripts, and neither has an upstream knob to point elsewhere.
#
#   ripgrep  dsh-tool-fs-search -> @vscode/ripgrep -> @vscode/ripgrep-android-arm64/bin/rg
#            Twelve platform packages exist; none is Android. The shim points
#            at Termux's own rg so `pkg upgrade ripgrep` keeps it current.
#
#   fs-local dsh-fs-local publishes a new file with link(2), which SELinux
#            denies outright — so the `write` tool cannot create a file at all.
#            Falls back to renameat2(RENAME_NOREPLACE): atomic, EEXIST on
#            collision, the same contract link-when-absent had.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
DMOD=$(resolve_dsh_modules)

info "platform-package gaps"

# The ripgrep shim is a symlink to the system binary; there is nothing to
# point at without it, so fail early with the remedy rather than a link error.
if [ ! -x "${PREFIX:-/data/data/com.termux/files/usr}/bin/rg" ]; then
    warn "no system ripgrep — run 'pkg install ripgrep' first"
fi

node "$ROOT/patch/patch-platform-gaps.mjs" all "$DMOD" \
    || die "patching failed"

ok "platform-package gaps closed"
