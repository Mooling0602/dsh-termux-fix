#!/usr/bin/env bash
# Build node-pty's PTY binding against Termux/bionic.
#
# node-pty upstream publishes no android-arm64 prebuild, and the linux-arm64
# prebuild is unusable on Android: it links glibc's libutil.so.1, while bionic
# folds libutil into libc. So we compile src/unix/pty.cc locally.
#
# No -lutil is needed on bionic (forkpty/openpty live in libc); the upstream
# binding.gyp only lists it for glibc systems.
#
# Usage: NODE_PTY_DIR=/path/to/node-pty scripts/build-node-pty.sh
# Env:   NAPI_INC   node-addon-api headers   (optional, auto-detected)
#        NODE_INC   node headers            (default: $PREFIX/include/node)
set -euo pipefail

NODE_PTY_DIR=${NODE_PTY_DIR:?NODE_PTY_DIR must point at the node-pty package}
NODE_INC=${NODE_INC:-$PREFIX/include/node}
OUT_DIR=${OUT_DIR:-$NODE_PTY_DIR/prebuilds/android-$(node -p "process.arch")}

[ -f "$NODE_PTY_DIR/src/unix/pty.cc" ] || { echo "missing $NODE_PTY_DIR/src/unix/pty.cc" >&2; exit 1; }
[ -f "$NODE_INC/node_api.h" ] || { echo "missing $NODE_INC/node_api.h" >&2; exit 1; }

if [ -z "${NAPI_INC:-}" ]; then
    NAPI_INC=$(node -p "require('node:path').dirname(require.resolve('node-addon-api/package.json', {paths:['$NODE_PTY_DIR']}))" 2>/dev/null || true)
fi
[ -n "${NAPI_INC:-}" ] && [ -f "$NAPI_INC/napi.h" ] || { echo "cannot locate node-addon-api headers; set NAPI_INC" >&2; exit 1; }

mkdir -p "$OUT_DIR"

c++ -std=c++20 -shared -fPIC -pthread -O2 \
    -DNAPI_VERSION=9 -DNODE_GYP_MODULE_NAME=pty \
    -I"$NODE_INC" -I"$NAPI_INC" \
    "$NODE_PTY_DIR/src/unix/pty.cc" \
    -o "$OUT_DIR/pty.node"

node -e "require('$OUT_DIR/pty.node'); console.log('built and loadable: $OUT_DIR/pty.node')"
