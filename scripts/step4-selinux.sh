#!/usr/bin/env bash
# Step 4 — SELinux link() fallbacks, and attachment durability.
#
# Android SELinux denies link(2) outright (EACCES/EPERM) — it is not a
# filesystem capability question. dsh uses link() in three places, all as an
# atomic exclusive-create publish, so each needs an equivalent replacement:
#
#   1+2  session-persistence  -> renameat2(RENAME_NOREPLACE) via our binding
#   3    attachment-local     -> copyFile (targets are content-addressed)
#
# The attachment store has a second, unrelated Android failure in front of the
# link() calls: it fsyncs every ancestor directory up to the filesystem root,
# and Android denies opening /data/data (mode 0711, system-owned). The walk now
# stops at the first ancestor the process may not open — everything below the
# app's private root is already durable, and the rest is the package manager's.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
DMOD=$(resolve_dsh_modules)

info "SELinux link() fallbacks and attachment durability"

node "$ROOT/patch/patch-session-persistence.mjs" \
    "$DMOD/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js" \
    "$DMOD/@deepseek-ai/dsh-session-persistence-jsonl/lib/worker.cjs" \
    "$DMOD/@deepseek-ai/dsh-attachment-local/lib/index.js" \
    || die "patching failed"
