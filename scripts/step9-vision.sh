#!/usr/bin/env bash
# Step 9 — image attachments (sharp via WebAssembly).
#
# Every uploaded image, and every `read_image` call, goes through
# @deepseek-ai/dsh-attachment-local, which lazily requires sharp on the first
# raster operation. On android-arm64 that require throws:
#
#   Error: Could not load the "sharp" module using the android-arm64 runtime
#
# sharp ships no JavaScript fallback: it loads a native binding from a
# per-platform optional dependency (@img/sharp-linux-arm64, …). The registry
# publishes 26 of those and none targets Android, so npm installs none of them
# and only @img/colour lands in the tree. Nothing here is caused — or fixed —
# by --ignore-scripts; the missing package is filtered out by npm's platform
# check before any lifecycle script would run.
#
# sharp's own loader ends with a fallback the platform table does not mention:
#
#   require("@img/sharp-wasm32/sharp.node")
#
# That is libvips compiled to WebAssembly, and it is the path upstream
# documents for platforms without a native build. It is not an optional
# dependency of sharp, so npm never installs it — this step does, matched to
# the installed sharp version, together with the @emnapi/runtime bridge and
# its tslib dependency.
#
# The packages are copied into dsh's node_modules as siblings of ordinary npm
# packages. Do not run `npm install` inside the dsh tree to achieve this: any
# npm operation there reconciles against the lockfile and prunes everything it
# did not install itself. A staging directory is used instead.
#
# WebAssembly is slower than a native binding would be — roughly 0.3-0.6s for
# a 1080x2460 screenshot — but correct, version-matched, and it survives an
# architecture that upstream does not publish for.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
source "$HERE/lib.sh"

WORK=${DSH_FIX_WORKDIR:-$HOME/src}/sharp-wasm

DMOD=$(resolve_dsh_modules)
SHARP=$DMOD/sharp

info "image attachments (sharp)"

if [ ! -d "$SHARP" ]; then
    warn "sharp is not installed under $DMOD — image attachments are unavailable"
    warn "  reinstall dsh first: ./scripts/install-dsh.sh"
    exit 0
fi

SHARP_VERSION=$(node -e 'console.log(require(process.argv[1]).version)' "$SHARP/package.json" 2>/dev/null || true)
[ -n "$SHARP_VERSION" ] || die "could not read the installed sharp version"

# Exercise the exact call the attachment pipeline makes: load sharp, encode a
# tiny PNG, decode it back, run one resize. A successful require() alone does
# not prove the WebAssembly runtime and libvips codecs are usable together.
sharp_loads() {
    node -e '
        const sharp = require(process.argv[1]);
        sharp({ create: { width: 8, height: 6, channels: 3, background: "#123456" } })
            .png()
            .toBuffer()
            .then((png) => sharp(png).metadata())
            .then((meta) => {
                if (meta.format !== "png" || meta.width !== 8 || meta.height !== 6) {
                    throw new Error("decoded facts do not match the encoded image");
                }
                return sharp({ create: { width: 8, height: 6, channels: 3, background: "#123456" } })
                    .resize({ width: 4 })
                    .jpeg({ quality: 80 })
                    .toBuffer({ resolveWithObject: true });
            })
            .then((out) => {
                if (out.info.format !== "jpeg" || out.info.width !== 4) {
                    throw new Error("resize/JPEG encode returned unexpected facts");
                }
            })
            .then(() => process.exit(0), (error) => {
                console.error(error && error.message ? error.message : error);
                process.exit(1);
            });
    ' "$SHARP" >/dev/null 2>&1
}

# Install the WebAssembly fallback beside sharp. A native binding — a source
# build, or a future upstream prebuild — makes this a no-op; the load test, not
# a directory, decides.
install_wasm() {
    # npm needs a project to install into. The staging tree doubles as a cache:
    # a re-run after a failed copy must not need the network again.
    mkdir -p "$WORK"

    stage_ready() {
        local pkg=$WORK/node_modules/@img/sharp-wasm32/package.json
        [ -f "$pkg" ] || return 1
        [ "$(node -e 'console.log(require(process.argv[1]).version)' "$pkg" 2>/dev/null)" = "$SHARP_VERSION" ] || return 1
        [ -d "$WORK/node_modules/@emnapi/runtime" ]
    }

    if stage_ready; then
        ok "reusing staged @img/sharp-wasm32@$SHARP_VERSION"
    else
        info "fetching @img/sharp-wasm32@$SHARP_VERSION"
        dim "  WebAssembly build of libvips, matched to the installed sharp"
        # No lifecycle scripts are needed for this package (or for
        # @emnapi/runtime and tslib); keep them off for symmetry with dsh.
        if ! ( cd "$WORK" && npm install --no-save --ignore-scripts --no-audit --no-fund \
                   "@img/sharp-wasm32@$SHARP_VERSION" ); then
            die "could not install @img/sharp-wasm32@$SHARP_VERSION — check 'npm config get registry' and the network"
        fi
        stage_ready || die "npm reported success but the staged tree is incomplete"
        ok "staged $(du -sh "$WORK/node_modules/@img/sharp-wasm32" | cut -f1) wasm32 build"
    fi

    # Copy, do not install in place. Only the packages sharp resolves at its
    # own level are needed: the wasm binary package, the @emnapi/runtime bridge
    # it requires, and tslib when dsh does not already ship one beside it.
    copy_package() {
        local name=$1
        local src=$WORK/node_modules/$name
        local dest=$DMOD/$name
        [ -d "$src" ] || die "staged package missing: $name"
        rm -rf "$dest"
        mkdir -p "$(dirname "$dest")"
        cp -R "$src" "$dest"
        ok "installed $name -> $dest"
    }

    copy_package "@img/sharp-wasm32"
    copy_package "@emnapi/runtime"
    if [ -d "$WORK/node_modules/tslib" ] && [ ! -d "$DMOD/tslib" ]; then
        copy_package tslib
    fi

    if ! sharp_loads; then
        # Re-run without the redirect so the real cause is visible: sharp's
        # loader prints one line per attempted binding and then its remedies.
        node -e 'require(process.argv[1])' "$SHARP" || true
        die "sharp still cannot load after installing the WebAssembly fallback"
    fi
    ok "sharp $SHARP_VERSION loads via @img/sharp-wasm32 (wasm32)"
}

if sharp_loads; then
    if [ -d "$DMOD/@img/sharp-wasm32" ]; then
        ok "sharp $SHARP_VERSION already loads via the WebAssembly fallback"
    else
        ok "sharp $SHARP_VERSION already loads (native binding) — nothing to install"
    fi
else
    install_wasm
fi

# --- verify ------------------------------------------------------------------
# The attachment store's real save-then-verified-read, on a throwaway root:
# prepareImageFile normalizes, commitPreparedImageFile fsyncs and publishes,
# readImageFile re-probes the stored bytes and checks the digest. That is the
# sequence `read_image` runs, and it is the only way to notice a missing step 4
# (the durable ancestor walk) here rather than at the user's first image.
attachment_roundtrip() {
    node --input-type=module -e '
        import { tmpdir } from "node:os";
        import { join } from "node:path";
        import { pathToFileURL } from "node:url";
        import { rm } from "node:fs/promises";

        const dmod = process.argv[1];
        const sharp = (await import(pathToFileURL(join(dmod, "sharp/dist/index.mjs")).href)).default;
        const store = await import(pathToFileURL(join(dmod, "@deepseek-ai/dsh-attachment-local/lib/index.js")).href);

        const limits = {
            maxImageBytes: store.DEFAULT_MAX_IMAGE_BYTES,
            maxImagesPerMessage: 20,
            maxMessageImageBytes: store.DEFAULT_MAX_MESSAGE_IMAGE_BYTES,
            maxImagePixels: store.DEFAULT_MAX_IMAGE_PIXELS,
            maxImageDimension: store.DEFAULT_MAX_IMAGE_DIMENSION,
            mediaTypes: ["image/png", "image/jpeg", "image/webp", "image/gif"],
        };
        const policy = {
            maxPixels: store.DEFAULT_NORMALIZED_IMAGE_MAX_PIXELS,
            maxDimension: store.DEFAULT_NORMALIZED_IMAGE_MAX_DIMENSION,
            maxBytes: store.DEFAULT_NORMALIZED_IMAGE_MAX_BYTES,
        };

        const png = await sharp({ create: { width: 8, height: 6, channels: 3, background: "#123456" } })
            .png()
            .toBuffer();
        const prepared = await store.prepareImageFile(
            { data: new Uint8Array(png), mediaType: "image/png", name: "self-test.png" },
            limits,
            policy
        );
        const parent = join(tmpdir(), `dsh-termux-fix-attach-${process.pid}`);
        const root = join(parent, "attachments", "v1");
        try {
            const ref = await store.commitPreparedImageFile(root, prepared);
            const back = await store.readImageFile(root, ref);
            if (back.data.byteLength !== ref.bytes) throw new Error("read-back byte count does not match the reference");
        } finally {
            await rm(parent, { recursive: true, force: true });
        }
    ' "$DMOD" >/dev/null 2>&1
}

if ! attachment_roundtrip; then
    warn "sharp loads, but the attachment store could not save and read an image back"
    warn "  its durable ancestor walk is patched by step 4 — run ./install.sh for the full sequence"
    die "attachment round-trip failed"
fi

ok "attachment save/read round-trip works"
dim "  WebAssembly is CPU-only: the first image read pays the module instantiation,"
dim "  and rasterising a large photo is slower than a native binding would be."
dim "  Restart dsh before the next image read; the attachment pipeline only"
dim "  requires sharp at that first image operation."
