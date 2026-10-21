#!/usr/bin/env bash
# Step 7 — persistent terminal (pty).
#
# dsh's terminal service fails to load on Android for two independent reasons:
#
#   1. dsh-subprocess-local's createProcessInspector() only understands
#      linux/darwin/win32 and throws
#      "terminal inspection is unsupported on platform android".
#      Android is the Linux kernel: same /proc layout, same arm64 syscall
#      numbers the inspector reads. patch-terminal-android.mjs widens the gate.
#
#   2. node-pty has no prebuilds/android-arm64/pty.node, and the linux-arm64
#      prebuild cannot be reused because it links glibc's libutil.so.1 (bionic
#      folds libutil into libc).
#
# Two ways to get such a binding, in order of preference:
#
#   1. Our prebuilt src/node-pty/pty.node.
#   2. Compile it here from upstream src/unix/pty.cc, which needs clang.
#
# The prebuilt comes first because needing clang at all is a liability on
# Termux — the same reasoning as step 1 (koffi).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
DMOD=$(resolve_dsh_modules)

info "persistent terminal (pty)"

NODE_PTY=$DMOD/node-pty
SUBPROCESS=$DMOD/@deepseek-ai/dsh-subprocess-local
PREBUILT=$ROOT/src/node-pty
PTY_ARCH=$(node -p "process.arch")

[ -d "$SUBPROCESS" ] || die "missing $SUBPROCESS (is this dsh >= 0.2?)"
[ -d "$NODE_PTY" ] || die "missing $NODE_PTY"

node "$ROOT/patch/patch-terminal-android.mjs" "$SUBPROCESS" \
    || die "patching failed"

# node-pty resolves its binding from prebuilds/<platform>-<arch>/pty.node, so on
# Termux that is prebuilds/android-arm64/pty.node — a directory upstream simply
# does not publish. The stock loader already scans this path, so placing the
# binary is the whole fix; no loader patch is involved.
INSTALL_DIR=$NODE_PTY/prebuilds/android-$PTY_ARCH
INSTALLED=$INSTALL_DIR/pty.node

# Load the package the way node-pty does, rather than require()ing the raw
# .node path: only that proves the loader patch found the right slot.
binding_loads() {
    node -e 'require(process.argv[1])' "$NODE_PTY" >/dev/null 2>&1
}

# --- 1. prebuilt -------------------------------------------------------------
if [ -f "$PREBUILT/pty.node" ] && [ -f "$PREBUILT/pty.json" ]; then
    PB_VER=$(node -e 'console.log(require(process.argv[1]).nodePtyVersion)' "$PREBUILT/pty.json" 2>/dev/null || true)
    PB_ARCH=$(node -e 'console.log(require(process.argv[1]).arch)' "$PREBUILT/pty.json" 2>/dev/null || true)
    PB_SHA=$(node -e 'console.log(require(process.argv[1]).sha256)' "$PREBUILT/pty.json" 2>/dev/null || true)
    PTY_VER=$(node -e 'console.log(require(process.argv[1]).version)' "$NODE_PTY/package.json" 2>/dev/null || true)

    # Normalise both sides: uname says aarch64 or arm64 depending on the build,
    # and the metadata may use either spelling of the same architecture.
    normalise_arch() {
        case "$1" in
            aarch64|arm64)    printf 'aarch64\n' ;;
            x86_64|amd64|x64) printf 'x86_64\n' ;;
            armv7l|arm)       printf 'arm\n' ;;
            *)                printf '%s\n' "$1" ;;
        esac
    }
    local_arch=$(normalise_arch "$(uname -m)")
    PB_ARCH_N=$(normalise_arch "$PB_ARCH")

    # A prebuilt is only usable when it was built for this node-pty release and
    # this architecture. The checksum is a corruption check, not a gate: if it
    # cannot be computed, still try the binding and let the load decide.
    if [ "$PB_VER" != "$PTY_VER" ]; then
        dim "  prebuilt is for node-pty $PB_VER, installed is $PTY_VER — not using it"
    elif [ "$PB_ARCH_N" != "$local_arch" ]; then
        dim "  prebuilt is for $PB_ARCH, this machine is $local_arch — not using it"
    else
        usable=1
        if [ -n "$PB_SHA" ] && command -v sha256sum >/dev/null 2>&1; then
            actual=$(sha256sum "$PREBUILT/pty.node" | cut -d' ' -f1)
            [ "$actual" = "$PB_SHA" ] || usable=0
        fi

        if [ "$usable" -eq 0 ]; then
            warn "prebuilt pty.node does not match its recorded checksum — ignoring it"
        else
            mkdir -p "$INSTALL_DIR"
            cp "$PREBUILT/pty.node" "$INSTALLED"
            if binding_loads; then
                ok "installed prebuilt binding (node-pty $PTY_VER)"
                prebuilt_done=1
            else
                warn "prebuilt binding did not load — falling back to compiling"
            fi
        fi
    fi
fi

# --- 2. compile from upstream source -----------------------------------------
if [ -z "${prebuilt_done:-}" ]; then
    NODE_PTY_DIR=$NODE_PTY bash "$HERE/build-node-pty.sh" || die "could not build pty.node"
    binding_loads || die "build finished but node-pty still does not load"
    ok "compiled"
fi

# Exercise the binding for real: fork a shell and read back its echo. Loading
# the .node alone would not prove forkpty(3) works on bionic.
node -e "
const pty = require(process.argv[1]);
const term = pty.spawn('/bin/sh', ['-i'], {
    name: 'xterm-256color', cols: 80, rows: 24, cwd: process.env.HOME, env: process.env,
});
let out = '';
const done = setTimeout(() => {
    console.error('  fail pty: no output within 15s');
    try { term.kill(); } catch {}
    process.exit(1);
}, 15000);
term.onData((d) => {
    out += d;
    if (out.includes('DSH_TERM_OK')) {
        clearTimeout(done);
        try { term.kill(); } catch {}
        console.log('  ok pty (forkpty + interactive echo)');
        process.exit(0);
    }
});
setTimeout(() => term.write('echo DSH_TERM_OK\n'), 600);
" "$NODE_PTY" || die "pty smoke test failed"

ok "persistent terminal ready"
