#!/usr/bin/env bash
# Build sherpa-onnx.node (the N-API addon) against the official Termux libs.
#
# Upstream's CMakeLists expects cmake-js and a locally built sherpa-onnx
# install tree. We already have a *published* Android build that links against
# bionic, so there is no reason to rebuild sherpa-onnx itself — only the thin
# N-API wrapper on top of it.
#
# No rpath is emitted on purpose: Android's linker ignores DT_RPATH/DT_RUNPATH
# ("unused DT entry ... ignoring"), so library resolution is done at runtime by
# the dlopen preload that patch-sherpa-addon.mjs injects into addon.js.
set -euo pipefail

SRC=${SRC:?SRC must point at the sherpa-onnx source tree}
LIBS=${LIBS:?LIBS must point at the extracted termux-shared release}
NAPI_INC=${NAPI_INC:?NAPI_INC must point at the node-addon-api headers}
NODE_INC=${NODE_INC:-$PREFIX/include/node}
OUT=${OUT:?OUT must be the target .node path}

ADDON_SRC=$SRC/scripts/node-addon-api/src

[ -d "$ADDON_SRC" ] || { echo "missing $ADDON_SRC" >&2; exit 1; }
[ -f "$LIBS/include/sherpa-onnx/c-api/c-api.h" ] || { echo "missing sherpa headers in $LIBS" >&2; exit 1; }
[ -f "$NAPI_INC/napi.h" ] || { echo "missing $NAPI_INC/napi.h" >&2; exit 1; }
[ -f "$NODE_INC/node_api.h" ] || { echo "missing $NODE_INC/node_api.h" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

c++ -std=c++17 -shared -fPIC -pthread -O2 -fvisibility=hidden \
  -DNAPI_VERSION=9 -DNODE_GYP_MODULE_NAME=sherpa_onnx \
  -I"$NODE_INC" -I"$NAPI_INC" -I"$LIBS/include" \
  "$ADDON_SRC"/*.cc \
  -L"$LIBS/lib" -lsherpa-onnx-c-api -lonnxruntime \
  -o "$OUT"

echo "built: $OUT"
