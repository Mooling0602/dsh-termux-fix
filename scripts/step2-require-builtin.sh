#!/usr/bin/env bash
# Step 2 — node-addon-require-builtin: build the missing android-arm64 binding.
#
# Upstream publishes prebuilt .node files for linux/darwin/win32 only. We clone
# the source and compile it locally with the Termux clang, replicating the
# direct-clang branch of upstream's scripts/build.ts.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DMOD=$(resolve_dsh_modules)
DEST=$DMOD/node-addon-require-builtin/build/napi/napi-v9-android-arm64/require_builtin.node
WORK=${DSH_FIX_WORKDIR:-$HOME/src}
REPO=$WORK/dsh-node-addon-require-builtin
NAPI=$WORK/node-addon-api-8

info "node-addon-require-builtin"

if [ -f "$DEST" ]; then
    ok "binding already present ($(wc -c < "$DEST") bytes)"
    exit 0
fi

mkdir -p "$WORK"

if [ ! -d "$REPO/packages/native/src" ]; then
    info "cloning upstream source"
    git clone --depth 1 https://github.com/deepseek-ai/dsh-node-addon-require-builtin "$REPO" \
        || die "clone failed (needs network)"
fi

if [ ! -f "$NAPI/napi.h" ]; then
    info "fetching node-addon-api 8.9.0 headers"
    ( cd "$WORK" \
        && npm pack node-addon-api@8.9.0 >/dev/null 2>&1 \
        && mkdir -p node-addon-api-8 \
        && tar -xzf node-addon-api-8.9.0.tgz -C node-addon-api-8 --strip-components=1 ) \
        || die "could not fetch node-addon-api headers"
fi

info "compiling"
REPO="$REPO" NAPI_INC="$NAPI" bash "$(dirname "${BASH_SOURCE[0]}")/build-require-builtin.sh" \
    || die "compile failed"

mkdir -p "$(dirname "$DEST")"
cp "$REPO/packages/require-builtin/entry/build/napi/napi-v9-android-arm64/require_builtin.node" "$DEST"
ok "installed $(wc -c < "$DEST") bytes"
