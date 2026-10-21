#!/usr/bin/env bash
# dsh-termux-fix — run @deepseek-ai/dsh on Termux/Android.
#
# Usage:
#   ./install.sh              apply every step (idempotent)
#   ./install.sh --check      report status only, change nothing
#   ./install.sh --step 3     run a single step
#   ./install.sh --help
#
# Re-run after every `npm install -g @deepseek-ai/dsh` upgrade: these patches
# modify the installed package contents and are wiped by a reinstall.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "$HERE/scripts/lib.sh"

usage() {
    cat <<'TXT'
dsh-termux-fix — make @deepseek-ai/dsh work under Termux/Android

USAGE
  ./install.sh [options]

OPTIONS
  --check          Report the status of every patch without changing anything.
  --step N         Run only step N (0-6).
  --list           List the steps.
  -h, --help       Show this help.

ENVIRONMENT
  DSH_MODULES      Path to @deepseek-ai/dsh/node_modules. Default: npm root -g
  DSH_FIX_WORKDIR  Scratch dir for cloned/built sources. Default: ~/src
  NODE_INC         Directory holding node_api.h. Default: $PREFIX/include/node
  NO_COLOR         Disable coloured output.

STEPS
  0  deps                       install clang, cmake, git via pkg
  1  koffi                      statx() is unavailable in the Android NDK
  2  node-addon-require-builtin no android prebuilt; compile from source
  3  node-addon-system          no android prebuilt; substitute our binding
  4  session-persistence        SELinux blocks link(); renameat2 / copyFile
  5  verify                     load every binding and exercise it
  6  speech                     local SenseVoice; no android prebuilt

NOTE
  These patches change files inside the installed dsh package. Every upgrade
  or reinstall wipes them — re-run this script afterwards.
TXT
}

list_steps() {
    cat <<'TXT'
0  deps                       install the toolchain (clang, cmake, git, ...)
1  koffi                      statx() unavailable; prebuilt binding, compile as fallback
2  node-addon-require-builtin no android prebuilt; compiled from upstream source
3  node-addon-system          no android prebuilt (source private); substitute binding
4  session-persistence        SELinux denies link(); renameat2 / copyFile fallbacks
5  verify                     load all bindings, check the EEXIST contract
6  speech                     local speech-to-text via sherpa-onnx
TXT
}

check_status() {
    local dmod ver
    dmod=$(resolve_dsh_modules)
    ver=$(dsh_version "$dmod")

    # The commit identifies exactly which revision produced this output. It is
    # printed so it travels with any pasted report: without it a bug cannot be
    # reproduced, because the behaviour may differ between commits.
    local commit
    commit=$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo 'unknown')

    printf '%sdsh-termux-fix — status%s\n\n' "$C_BOLD" "$C_RESET"
    printf '  commit        %s\n' "$commit"
    printf '  dsh version   %s\n' "$ver"
    printf '  modules       %s\n' "$dmod"
    printf '  node          %s\n' "$(node -v)"
    printf '  platform      %s %s\n\n' "$(uname -s)" "$(uname -m)"

    status() { printf '  %-34s %s\n' "$1" "$2"; }

    # 0 toolchain — report only what is actually wrong, so the line stays
    # quiet on a healthy install. Installed-but-unrunnable is called out
    # separately: dpkg says "installed", but cnoke only cares whether
    # `cmake --version` exits 0, and reports the mismatch as
    # "CMake does not seem to be available".
    local missing='' broken=''
    for pkg in clang cmake make git nodejs tar curl; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
            | grep -q "install ok installed" || missing="$missing $pkg"
    done
    for tool in cmake clang git; do
        command -v "$tool" >/dev/null 2>&1 || continue
        "$tool" --version >/dev/null 2>&1 || broken="$broken $tool"
    done
    if [ -n "$broken" ]; then
        status "0 toolchain" "BROKEN:$broken (installed, will not run)"
    elif [ -z "$missing" ]; then
        status "0 toolchain" "complete"
    else
        status "0 toolchain" "MISSING:$missing"
    fi

    # 1 koffi — what matters is whether the binding loads, not how it got
    # there. A prebuilt avoids needing cmake at all; a source build proves the
    # statx patch was applied, but both produce an equivalent binding.
    local kbase=$dmod/koffi
    local kbind
    kbind=$(ls "$kbase"/build/koffi/android_*/koffi.node 2>/dev/null | head -1)
    if [ -f "$kbase/lib/native/base/base.cc" ]; then
        if [ -n "$kbind" ] && ( cd "$kbase" && node -e 'require(process.argv[1])' "$kbase" >/dev/null 2>&1 ); then
            local kver
            kver=$(node -e 'console.log(require(process.argv[1]).version)' "$kbase/package.json" 2>/dev/null || echo '?')
            status "1 koffi binding" "loads (koffi $kver)"
        elif [ -n "$kbind" ]; then
            status "1 koffi binding" "present but will not load"
        else
            status "1 koffi binding" "MISSING"
        fi
    else
        status "1 koffi binding" "package missing"
    fi

    # 2 require-builtin
    local rb=$dmod/node-addon-require-builtin/build/napi/napi-v9-android-arm64/require_builtin.node
    [ -f "$rb" ] && status "2 require-builtin binding" "present ($(wc -c < "$rb") bytes)" \
                 || status "2 require-builtin binding" "MISSING"

    # 3 system
    local sys=$dmod/@deepseek-ai/node-addon-system-android-arm64/bin/system.node
    [ -f "$sys" ] && status "3 system binding" "present ($(wc -c < "$sys") bytes)" \
                  || status "3 system binding" "MISSING"
    if [ -f "$dmod/@deepseek-ai/node-addon-system/lib/flock.js" ]; then
        if grep -qF "platform !== 'android'" "$dmod/@deepseek-ai/node-addon-system/lib/flock.js"; then
            local dup
            dup=$(grep -o "platform !== 'android'" "$dmod/@deepseek-ai/node-addon-system/lib/flock.js" | wc -l)
            if [ "$dup" -gt 1 ]; then
                status "3 flock.js guard" "allows android (x$dup duplicated)"
            else
                status "3 flock.js guard" "allows android"
            fi
        else
            status "3 flock.js guard" "NOT patched"
        fi
    fi

    # 4 session persistence
    local sp=$dmod/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js
    if [ -f "$sp" ]; then
        local n
        n=$(grep -c "_dshTermuxLoadSystem" "$sp" 2>/dev/null || true)
        [ "$n" -ge 3 ] && status "4 session-persistence" "patched ($n refs)" \
                       || status "4 session-persistence" "NOT patched ($n refs)"
    else
        status "4 session-persistence" "missing"
    fi
    local att=$dmod/@deepseek-ai/dsh-attachment-local/lib/index.js
    if [ -f "$att" ]; then
        local n
        n=$(grep -c "dsh-termux-fix" "$att" 2>/dev/null || true)
        [ "$n" -ge 2 ] && status "4 attachment-local" "patched ($n refs)" \
                       || status "4 attachment-local" "NOT patched ($n refs)"
    else
        status "4 attachment-local" "missing"
    fi

    # 6 speech
    local sv=$dmod/@deepseek-ai/dsh-experimental-speech-to-text-sensevoice
    if [ -d "$sv" ]; then
        local sn=
        for c in "$sv/node_modules/sherpa-onnx-node" "$dmod/sherpa-onnx-node"; do
            [ -d "$c" ] && { sn=$c; break; }
        done
        if [ -n "$sn" ] && [ -f "$sn/sherpa-onnx.node" ]; then
            status "6 sherpa addon" "present ($(wc -c < "$sn/sherpa-onnx.node") bytes)"
        else
            status "6 sherpa addon" "MISSING"
        fi
        if grep -qF '"android-arm64"' "$sv/lib/index.js" 2>/dev/null; then
            status "6 sensevoice platform gate" "allows android"
        else
            status "6 sensevoice platform gate" "NOT patched"
        fi
        if [ -n "$sn" ] && grep -qF 'dsh-termux-fix: preload sherpa' "$sn/addon.js" 2>/dev/null; then
            status "6 addon library preload" "patched"
        else
            status "6 addon library preload" "NOT patched"
        fi
        local models=$HOME/.dsh/speech-to-text/sensevoice/models
        if [ -f "$models/silero/silero_vad.onnx" ] && [ -f "$models/sensevoice-onnx/model.int8.onnx" ]; then
            status "6 model files" "downloaded"
        else
            status "6 model files" "not downloaded (settings page)"
        fi
    else
        status "6 speech package" "not installed (enable voice-input bundle)"
    fi

    printf '\n'
    info "run ./install.sh to apply, or ./install.sh --step N for one step"
}

# Warn when the checkout is behind origin/main. Deliberately advisory: this
# must never fail a run, and must stay silent when git is unavailable, the
# directory is not a repo (e.g. an unpacked tarball), or the network is down.
warn_if_stale() {
    git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1 || return 0

    local branch upstream behind
    branch=$(git -C "$HERE" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
    upstream=$(git -C "$HERE" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || return 0

    # No network call: compare against the local remote-tracking ref. It is only
    # as fresh as the last fetch, which is the honest limit of an offline check.
    behind=$(git -C "$HERE" rev-list --count "HEAD..$upstream" 2>/dev/null) || return 0

    if [ "${behind:-0}" -gt 0 ]; then
        warn "your checkout is $behind commit(s) behind $upstream"
        dim "  run 'git pull' first — the fix may already be in main" >&2
    fi
}

run_step() {
    local n=$1
    case "$n" in
        0) bash "$HERE/scripts/step0-deps.sh" ;;
        1) bash "$HERE/scripts/step1-koffi.sh" ;;
        2) bash "$HERE/scripts/step2-require-builtin.sh" ;;
        3) bash "$HERE/scripts/step3-system.sh" ;;
        4) bash "$HERE/scripts/step4-selinux.sh" ;;
        5) bash "$HERE/scripts/step5-verify.sh" ;;
        6) bash "$HERE/scripts/step6-speech.sh" ;;
        *) die "no such step: $n (valid: 0-6)" ;;
    esac
}

main() {
    local mode=install step=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --check)   mode=check ;;
            --step)    shift; step=${1:-} ;;
            --step=*)  step=${1#*=} ;;
            --list)    list_steps; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument: $1 (try --help)" ;;
        esac
        shift
    done

    require_android_or_linux
    require_arm64_note
    warn_if_stale

    if [ "$mode" = check ]; then
        check_status
        exit 0
    fi

    if [ -n "$step" ]; then
        run_step "$step"
        exit 0
    fi

    local dmod ver
    dmod=$(resolve_dsh_modules)
    ver=$(dsh_version "$dmod")
    info "dsh $ver at $dmod"
    printf '\n'

    run_step 0; printf '\n'
    run_step 1; printf '\n'
    run_step 2; printf '\n'
    run_step 3; printf '\n'
    run_step 4; printf '\n'
    run_step 5; printf '\n'
    run_step 6

    printf '\n'
    ok "done — restart dsh"
}

main "$@"
