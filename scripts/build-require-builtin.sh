#!/usr/bin/env bash
# Hand-written replica of upstream's scripts/build.ts direct-clang path:
#   NARB_BACKEND=1  -> napi
#   NARB_PRODUCT=1  -> require-builtin
# Upstream's script needs a pnpm workspace and build-time tooling that do not
# run under Termux, so the command line is spelled out here instead.
set -euo pipefail

REPO=${REPO:-$HOME/src/dsh-node-addon-require-builtin}
NAPI_INC=${NAPI_INC:-$HOME/src/node-addon-api-8}
NODE_INC=${NODE_INC:-$PREFIX/include/node}
SRC=$REPO/packages/native/src
OUT=$REPO/packages/require-builtin/entry/build/napi/napi-v9-android-arm64/require_builtin.node

[ -d "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }
[ -f "$NAPI_INC/napi.h" ] || { echo "missing $NAPI_INC/napi.h" >&2; exit 1; }
[ -f "$NODE_INC/node_api.h" ] || { echo "missing $NODE_INC/node_api.h" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

c++ -std=c++17 \
  -shared -fPIC -pthread \
  -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type-mismatch \
  -fno-exceptions -fvisibility=hidden \
  -DNAPI_VERSION=9 \
  -DNARB_BACKEND=1 \
  -DNARB_PRODUCT=1 \
  -DNODE_ADDON_API_DISABLE_CPP_EXCEPTIONS \
  -DNODE_GYP_MODULE_NAME=require_builtin \
  -I"$NODE_INC" -I"$NAPI_INC" \
  "$SRC/node_api_addon.cc" \
  "$SRC/debug_trace.cc" \
  "$SRC/native_types.cc" \
  "$SRC/runtime_symbol.cc" \
  "$SRC/require_builtin_probe.cc" \
  "$SRC/runtime_context/helper.cc" \
  "$SRC/runtime_context/platform.cc" \
  "$SRC/runtime_context/darwin_arm64.cc" \
  "$SRC/runtime_context/darwin_x64.cc" \
  "$SRC/runtime_context/linux_arm64.cc" \
  "$SRC/runtime_context/linux_x64.cc" \
  "$SRC/runtime_context/win32_arm64.cc" \
  "$SRC/runtime_context/win32_x64.cc" \
  "$SRC/runtime_context/win32_ia32.cc" \
  "$SRC/runtime_context/embedder_data.cc" \
  "$SRC/runtime_context/runtime_profile.cc" \
  "$SRC/runtime_context/runtime_profile_napi.cc" \
  "$SRC/runtime_probe/helper.cc" \
  "$SRC/runtime_probe/platform.cc" \
  "$SRC/runtime_probe/getter_decoder.cc" \
  "$SRC/runtime_probe/posix.cc" \
  "$SRC/runtime_probe/win32_common.cc" \
  "$SRC/runtime_probe/darwin_arm64.cc" \
  "$SRC/runtime_probe/darwin_x64.cc" \
  "$SRC/runtime_probe/linux_arm64.cc" \
  "$SRC/runtime_probe/linux_x64.cc" \
  "$SRC/runtime_probe/win32_arm64.cc" \
  "$SRC/runtime_probe/win32_x64.cc" \
  "$SRC/runtime_probe/win32_ia32.cc" \
  "$SRC/runtime_compat_napi.cc" \
  -o "$OUT"

echo "built: $OUT"
