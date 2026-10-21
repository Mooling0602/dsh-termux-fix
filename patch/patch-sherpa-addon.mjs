#!/usr/bin/env node
/**
 * Patch the JS side of local speech-to-text for Termux/Android.
 *
 * Two independent rewrites:
 *
 *   1. sherpa-onnx-node/addon.js — preload libonnxruntime.so and
 *      libsherpa-onnx-c-api.so before requiring the addon. Needed because
 *      Android's linker ignores DT_RPATH/DT_RUNPATH, so the addon cannot find
 *      its sibling .so files on its own, and there is no LD_LIBRARY_PATH in the
 *      dsh process.
 *
 *   2. dsh-experimental-speech-to-text-sensevoice/lib/index.js — add android
 *      to the platform allowlist. Upstream ships no android prebuilt, which is
 *      true, but the runtime works once the addon is built locally.
 *
 * Usage: patch-sherpa-addon.mjs <sensevoice-package-dir> <sherpa-onnx-node-dir>
 */

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const die = (message) => {
    console.error(`error: ${message}`);
    process.exit(1);
};

const count = (haystack, needle) => haystack.split(needle).length - 1;

const applyOnce = (file, { anchor, replacement, marker, label }) => {
    const source = readFileSync(file, "utf8");

    if (count(source, marker) > 0) {
        console.log(`  ok ${label}: already applied`);
        return;
    }

    const hits = count(source, anchor);
    if (hits !== 1) {
        die(`${label}: anchor found ${hits} times (expected 1), upstream layout changed`);
    }

    writeFileSync(file, source.replace(anchor, replacement));

    if (count(readFileSync(file, "utf8"), marker) === 0) {
        die(`${label}: patch did not take effect`);
    }
    console.log(`  ok ${label}: patched`);
};

// ---------------------------------------------------------------------------
// 1. addon.js — dlopen preload
// ---------------------------------------------------------------------------

const ADDON_ANCHOR = "const addonStaticImport = require('./addon-static-import');";

const ADDON_PATCH = `${ADDON_ANCHOR}

// --- dsh-termux-fix: preload sherpa-onnx shared libraries -------------------
// Android's linker ignores DT_RPATH/DT_RUNPATH entirely ("unused DT entry:
// DT_RPATH ... ignoring"), so the only way to satisfy the addon's
// libsherpa-onnx-c-api.so / libonnxruntime.so dependencies without exporting
// LD_LIBRARY_PATH into the dsh process is to map them here first.
// process.dlopen loads into the global symbol scope, which is what the addon
// needs in order to resolve OrtGetApiBase.
if (process.platform === 'android') {
  const { join } = require('path');
  for (const lib of ['libonnxruntime.so', 'libsherpa-onnx-c-api.so']) {
    try {
      process.dlopen({ exports: {} }, join(__dirname, lib));
    } catch (error) {
      // "Module did not self-register" is expected and harmless here: the
      // library is already mapped into the process, which is all we need.
    }
  }
}
// ---------------------------------------------------------------------------`;

// ---------------------------------------------------------------------------
// 2. sensevoice index.js — platform allowlist
// ---------------------------------------------------------------------------

const GATE_ANCHOR = `		"win32-x64"
	].includes(\`\${process.platform}-\${process.arch}\`))`;

const GATE_PATCH = `		"win32-x64",
		// dsh-termux-fix: Android works once the sherpa-onnx addon is built
		// locally. Upstream publishes no android prebuilt, but the official
		// android-aarch64-termux release links against bionic and loads fine.
		"android-arm64",
		"android-x64"
	].includes(\`\${process.platform}-\${process.arch}\`))`;

// ---------------------------------------------------------------------------

const [sensevoiceDir, sherpaDir] = process.argv.slice(2);
if (!sensevoiceDir || !sherpaDir) {
    die("usage: patch-sherpa-addon.mjs <sensevoice-package-dir> <sherpa-onnx-node-dir>");
}

console.log("==> patching speech-to-text");

applyOnce(join(sherpaDir, "addon.js"), {
    anchor: ADDON_ANCHOR,
    replacement: ADDON_PATCH,
    marker: "dsh-termux-fix: preload sherpa-onnx shared libraries",
    label: "addon.js library preload",
});

applyOnce(join(sensevoiceDir, "lib", "index.js"), {
    anchor: GATE_ANCHOR,
    replacement: GATE_PATCH,
    marker: '"android-arm64"',
    label: "sensevoice platform allowlist",
});
