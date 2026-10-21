#!/usr/bin/env bash
# Step 3 — node-addon-system: provide the missing flock binding.
#
# Upstream ships no android prebuilt and the package source is not public, yet
# dsh's session persistence depends on tryLockExclusive(). src/node-addon-system/
# system.cc implements the two functions dsh actually calls, with the exact
# callback contracts the JS side expects.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
DMOD=$(resolve_dsh_modules)

info "node-addon-system"

PKGS=$DMOD/@deepseek-ai/node-addon-system-android-arm64
mkdir -p "$PKGS/bin"

# Prefer a local build; fall back to the committed prebuilt (aarch64 only).
WORKDIR=${DSH_FIX_WORKDIR:-$HOME/src}/node-addon-system
mkdir -p "$WORKDIR"

NODE_INC=${NODE_INC:-$PREFIX/include/node}
if [ -f "$NODE_INC/node_api.h" ]; then
    info "compiling system.node"
    if c++ -std=c++17 -shared -fPIC -pthread -fvisibility=hidden -O2 \
        -DNAPI_VERSION=9 -DNODE_GYP_MODULE_NAME=system \
        -I"$NODE_INC" \
        "$ROOT/src/node-addon-system/system.cc" -o "$WORKDIR/system.node" 2>/dev/null
    then
        ok "compiled"
    else
        warn "compile failed; using prebuilt aarch64 binding"
        cp "$ROOT/src/node-addon-system/system.node" "$WORKDIR/system.node"
    fi
else
    warn "node headers not found at $NODE_INC; using prebuilt aarch64 binding"
    cp "$ROOT/src/node-addon-system/system.node" "$WORKDIR/system.node"
fi

cp "$WORKDIR/system.node" "$PKGS/bin/system.node"

cat > "$PKGS/package.json" <<'JSON'
{
  "name": "@deepseek-ai/node-addon-system-android-arm64",
  "version": "0.1.2",
  "description": "Local Termux/Android build of the flock binding (upstream ships no android prebuilt)",
  "os": ["android"],
  "cpu": ["arm64"],
  "main": "bin/system.node"
}
JSON
ok "platform package written"

# Upstream hardcodes a linux/darwin platform guard. Extend it to android.
# The original sed is NOT idempotent: the patched line still matches the
# pattern, so every re-run appends another "&& platform !== 'android'".
FLOCK=$DMOD/@deepseek-ai/node-addon-system/lib/flock.js
[ -f "$FLOCK" ] || die "missing $FLOCK"

if grep -qF "platform !== 'android'" "$FLOCK"; then
    ok "flock.js already allows android"
else
    node -e '
        const fs = require("node:fs");
        const f = process.argv[1];
        const src = fs.readFileSync(f, "utf8");
        const out = src.replace("platform !== \x27linux\x27 && platform !== \x27darwin\x27",
                                "platform !== \x27linux\x27 && platform !== \x27darwin\x27 && platform !== \x27android\x27");
        if (out === src) { console.error("anchor not found"); process.exit(1); }
        fs.writeFileSync(f, out);
    ' "$FLOCK" || die "could not patch flock.js platform guard"
    ok "flock.js now allows android"
fi
