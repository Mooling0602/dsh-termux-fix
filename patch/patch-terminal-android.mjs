#!/usr/bin/env node
// dsh-termux-fix: make dsh's persistent terminal work on Termux/Android.
//
// Two independent problems, both fatal before this patch:
//
//   1. dsh-subprocess-local rejects the platform outright.
//      createProcessInspector() only accepts "linux" / "darwin" / "win32"
//      and throws `subprocess-local: terminal inspection is unsupported on
//      platform android` at plugin load. Android *is* the Linux kernel: /proc
//      has the same layout and the arm64 syscall numbers used by the inspector
//      (read=63, pselect=72, ppoll=73, epoll_pwait=22) are identical. Routing
//      android to LinuxProcessInspector is therefore correct, not a hack.
//
//   2. node-pty ships no android-arm64 prebuild.
//      Its loader looks for prebuilds/<platform>-<arch>/pty.node, i.e.
//      prebuilds/android-arm64/pty.node, which does not exist upstream. The
//      bundled linux-arm64 build cannot be reused because it links against
//      glibc's libutil.so.1, while Android uses bionic (libutil is folded into
//      libc). The fix is to drop a locally built pty.node at that path --
//      see scripts/build-node-pty.sh.
//
// Usage: patch-terminal-android.mjs <dsh-subprocess-local-dir> <node-pty-dir>

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
// 1. createProcessInspector -- accept android via the Linux inspector
// ---------------------------------------------------------------------------

const INSPECTOR_ANCHOR = `\tif (platform === "linux") return new LinuxProcessInspector(arch, internals);`;

const INSPECTOR_PATCH = `\t// dsh-termux-fix: Termux reports process.platform === "android", which is
\t// still the Linux kernel -- same /proc layout, same arm64 syscall numbers.
\t// Upstream bails out here and the whole terminal service fails to load.
\tif (platform === "linux" || platform === "android") return new LinuxProcessInspector(arch, internals);`;

// ---------------------------------------------------------------------------
// 2. node-pty loader -- fall back to linux-arm64 when no android prebuild exists
// ---------------------------------------------------------------------------

const PTY_LOADER_ANCHOR = `    var dirs = ['build/Release', 'build/Debug', "prebuilds/".concat(process.platform, "-").concat(process.arch)];`;

const PTY_LOADER_PATCH = `    // dsh-termux-fix: node-pty publishes no prebuilds/android-arm64/pty.node,
    // but an aarch64 build made against Termux/bionic works fine. Accept it
    // from a sibling "prebuilds/linux-arm64" slot so the upstream layout stays
    // untouched. (The stock linux-arm64 binary cannot be used: it links
    // libutil.so.1, which bionic does not provide.)
    var dirs = ['build/Release', 'build/Debug', "prebuilds/".concat(process.platform, "-").concat(process.arch)];
    if (process.platform === 'android') {
        dirs.push('prebuilds/' + (process.arch === 'arm64' ? 'linux-arm64' : process.arch));
    }`;

// ---------------------------------------------------------------------------

const [subprocessDir, nodePtyDir] = process.argv.slice(2);
if (!subprocessDir || !nodePtyDir) {
    die("usage: patch-terminal-android.mjs <dsh-subprocess-local-dir> <node-pty-dir>");
}

console.log("==> patching persistent terminal");

applyOnce(join(subprocessDir, "lib", "runner-launch-B2zsQ1Dz.js"), {
    anchor: INSPECTOR_ANCHOR,
    replacement: INSPECTOR_PATCH,
    marker: "dsh-termux-fix: Termux reports process.platform",
    label: "createProcessInspector android allowlist",
});

applyOnce(join(nodePtyDir, "lib", "utils.js"), {
    anchor: PTY_LOADER_ANCHOR,
    replacement: PTY_LOADER_PATCH,
    marker: "dsh-termux-fix: node-pty publishes no prebuilds",
    label: "node-pty android binding lookup",
});
