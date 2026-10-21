#!/usr/bin/env bash
# Step 6 — local speech-to-text (SenseVoice via sherpa-onnx).
#
# dsh's voice input refuses to start on android:
#
#   Error: Local speech is unavailable for android-arm64
#
# Two separate problems hide behind that one line:
#
#   1. sherpa-onnx-node ships prebuilt binaries for linux/darwin/win32 only.
#      Its linux-arm64 build links against glibc (libc.so.6, ld-linux-aarch64),
#      so it cannot load on Android's bionic libc at all.
#
#   2. The sensevoice package hardcodes a platform allowlist that excludes
#      android.
#
# The fix uses the official `android-aarch64-termux-shared` sherpa-onnx release
# — upstream does publish a bionic-compatible Termux build, just not through
# npm. We compile only the thin N-API wrapper on top of it.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
source "$HERE/lib.sh"

SHERPA_VERSION=1.13.8
WORK=${DSH_FIX_WORKDIR:-$HOME/src}/sherpa-onnx

DMOD=$(resolve_dsh_modules)
SENSEVOICE=$DMOD/@deepseek-ai/dsh-experimental-speech-to-text-sensevoice

info "speech-to-text (sherpa-onnx $SHERPA_VERSION)"

if [ ! -d "$SENSEVOICE" ]; then
    warn "sensevoice package not installed — enable the voice-input bundle first"
    warn "  add @deepseek-ai/dsh-experimental-voice-input-bundle to your profile"
    exit 0
fi

# sherpa-onnx-node is installed by npm as a transitive dependency, but without
# any binary: its optional platform packages are linux/darwin/win32 only, so npm
# skips them all on android. We add our build alongside it.
NODE_PKG=
for candidate in \
    "$SENSEVOICE/node_modules/sherpa-onnx-node" \
    "$DMOD/sherpa-onnx-node"
do
    [ -d "$candidate" ] && { NODE_PKG=$candidate; break; }
done

if [ -z "$NODE_PKG" ]; then
    warn "sherpa-onnx-node not found; install the voice-input bundle first"
    exit 0
fi

# Already built? The .node file is the marker — everything else is a copy.
if [ -f "$NODE_PKG/sherpa-onnx.node" ] && [ -f "$NODE_PKG/libonnxruntime.so" ]; then
    ok "addon already installed at $NODE_PKG"
    node "$ROOT/patch/patch-sherpa-addon.mjs" "$SENSEVOICE" "$NODE_PKG" \
        || die "patching failed"
    exit 0
fi

mkdir -p "$WORK"
LIBS=$WORK/termux-shared-$SHERPA_VERSION
SRC=$WORK/src-$SHERPA_VERSION
OUT=$WORK/sherpa-onnx.node

# --- official Termux build ---------------------------------------------------
if [ ! -f "$LIBS/lib/libsherpa-onnx-c-api.so" ]; then
    ARCHIVE=$WORK/termux-shared-$SHERPA_VERSION.tar.bz2
    URL=https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA_VERSION/sherpa-onnx-v$SHERPA_VERSION-android-aarch64-termux-shared.tar.bz2

    info "downloading the official Termux release"
    download() {
        for attempt in "https://gh-proxy.com/$URL" "https://ghproxy.net/$URL" "$URL"; do
            curl -sSL --retry 2 --max-time 900 -o "$ARCHIVE" "$attempt" 2>/dev/null \
                && tar -tjf "$ARCHIVE" >/dev/null 2>&1 && return 0
            dim "  retrying via another mirror"
        done
        return 1
    }
    download || die "download failed; set up a mirror and retry"
    mkdir -p "$LIBS"
    tar -xjf "$ARCHIVE" -C "$LIBS" --strip-components=1
    ok "downloaded $(du -sh "$LIBS/lib" | cut -f1) of libraries"
fi

# --- addon sources -----------------------------------------------------------
if [ ! -d "$SRC/scripts/node-addon-api/src" ]; then
    info "fetching sherpa-onnx $SHERPA_VERSION sources"
    ARCHIVE=$WORK/src-$SHERPA_VERSION.tar.gz
    for attempt in \
        "https://gh-proxy.com/https://github.com/k2-fsa/sherpa-onnx/archive/refs/tags/v$SHERPA_VERSION.tar.gz" \
        "https://github.com/k2-fsa/sherpa-onnx/archive/refs/tags/v$SHERPA_VERSION.tar.gz"
    do
        curl -sSL --retry 2 --max-time 900 -o "$ARCHIVE" "$attempt" 2>/dev/null \
            && tar -tzf "$ARCHIVE" >/dev/null 2>&1 && break
        dim "  retrying via another mirror"
    done
    [ -s "$ARCHIVE" ] || die "could not download sources"
    mkdir -p "$SRC"
    tar -xzf "$ARCHIVE" -C "$SRC" --strip-components=1
    ok "sources ready"
fi

# --- node-addon-api headers --------------------------------------------------
NAPI=$WORK/node-addon-api-8
if [ ! -f "$NAPI/napi.h" ]; then
    info "fetching node-addon-api 8.9.0 headers"
    ( cd "$WORK" \
        && npm pack node-addon-api@8.9.0 >/dev/null 2>&1 \
        && mkdir -p node-addon-api-8 \
        && tar -xzf node-addon-api-8.9.0.tgz -C node-addon-api-8 --strip-components=1 ) \
        || die "could not fetch node-addon-api headers"
    ok "headers ready"
fi

# --- compile -----------------------------------------------------------------
info "compiling the N-API addon"
SRC="$SRC" LIBS="$LIBS" NAPI_INC="$NAPI" OUT="$OUT" \
    bash "$HERE/build-sherpa-addon.sh" || die "compile failed"
ok "compiled"

# --- install -----------------------------------------------------------------
cp "$OUT" "$NODE_PKG/sherpa-onnx.node"
cp "$LIBS/lib/libsherpa-onnx-c-api.so" \
   "$LIBS/lib/libonnxruntime.so" \
   "$LIBS/lib/libsherpa-onnx-cxx-api.so" \
   "$NODE_PKG/"
ok "installed into $NODE_PKG"

node "$ROOT/patch/patch-sherpa-addon.mjs" "$SENSEVOICE" "$NODE_PKG" \
    || die "patching failed"

printf '\n'
dim "  Model files are downloaded on first use from the dsh settings page."
dim "  Default origins: huggingface.co, then hf-mirror.com."
dim "  huggingface.co is unreachable from some networks; the probe falls back"
dim "  to hf-mirror.com automatically, or set modelOrigin in the plugin config."
