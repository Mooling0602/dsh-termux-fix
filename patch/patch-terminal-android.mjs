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
//      Its loader already scans prebuilds/<platform>-<arch>/pty.node, i.e.
//      prebuilds/android-arm64/pty.node on Termux -- upstream simply does not
//      publish that directory. Dropping a bionic build there therefore needs no
//      loader change at all; see scripts/build-node-pty.sh.
//
//      An earlier revision of this patch also widened the loader's candidate
//      list to prebuilds/linux-arm64. That was redundant (the stock array
//      already contains prebuilds/android-arm64) and actively misleading: when
//      the binding is missing, the extra candidate makes the error name
//      prebuilds/linux-arm64 instead of the path that is actually absent.
//
// Only the inspector gate needs patching, so node-pty is not touched here.
//
// Usage: patch-terminal-android.mjs <dsh-subprocess-local-dir>

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
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

const [subprocessDir] = process.argv.slice(2);
if (!subprocessDir) {
    die("usage: patch-terminal-android.mjs <dsh-subprocess-local-dir>");
}

// The file name carries a build hash (runner-launch-<hash>.js), so it changes
// whenever dsh is rebuilt. Resolve it instead of hardcoding one: a stale hash
// would surface as a raw ENOENT stack trace rather than the deliberate
// "upstream layout changed" message every other patcher produces.
const launchDir = join(subprocessDir, "lib");
const candidates = readdirSync(launchDir).filter((name) => /^runner-launch-.*\.js$/.test(name));

if (candidates.length !== 1) {
    die(`inspector gate: expected exactly one runner-launch-*.js in ${launchDir}, found ${candidates.length} (upstream layout changed)`);
}

console.log("==> patching persistent terminal");

applyOnce(join(launchDir, candidates[0]), {
    anchor: INSPECTOR_ANCHOR,
    replacement: INSPECTOR_PATCH,
    marker: "dsh-termux-fix: Termux reports process.platform",
    label: "createProcessInspector android allowlist",
});
