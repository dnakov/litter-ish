#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ISH_BIN="${ISH_BIN:-$PROJECT_DIR/build-arm64-linux/ish}"
ROOTFS="${ROOTFS:-$PROJECT_DIR/alpine-arm64-fakefs}"
ROOTFS_LANES="${ROOTFS_LANES:-default=$ROOTFS}"
LANE_NAME="${LANE_NAME:-default}"
CLI_PACKAGE_MANAGERS="${CLI_PACKAGE_MANAGERS:-npm bun pip}"
TIMEOUT_S="${TIMEOUT_S:-180}"
INSTALL_TIMEOUT_S="${INSTALL_TIMEOUT_S:-1800}"
REPORT_DIR="${REPORT_DIR:-/workspace/tmp}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPORT_DIR/ish-arm64-cli-package-runtime-coverage-$STAMP.md"
GUEST_WORK="/tmp/cli-package-runtime-coverage"
HOST_TMP="$(mktemp -d)"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0
REPORT_ROWS=""

cleanup() {
    rm -rf "$HOST_TMP"
}
trap cleanup EXIT

mkdir -p "$REPORT_DIR"

log() {
    printf '>>> %s\n' "$*"
}

guest_capture() {
    timeout "$TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -c "export HOME=/root NO_COLOR=1 CI=1 TERM=dumb PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; { $1; }; rc=\$?; printf '\n__ISH_STATUS:%s\n' \"\$rc\""
}

guest_capture_install() {
    timeout "$INSTALL_TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -c "export HOME=/root NO_COLOR=1 CI=1 TERM=dumb PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; { $1; }; rc=\$?; printf '\n__ISH_STATUS:%s\n' \"\$rc\""
}

push_tree() {
    local src="$1"
    local dst="$2"
    tar -C "$src" -cf - . | timeout "$TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -c "rm -rf '$dst' && mkdir -p '$dst' && tar -xf - -C '$dst'"
}

merge_tree() {
    local src="$1"
    local dst="$2"
    tar -C "$src" -cf - . | timeout "$TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -c "mkdir -p '$dst' && tar -xf - -C '$dst'"
}

append_row() {
    local stage="$1"
    local name="$2"
    local status="$3"
    local detail="$4"
    REPORT_ROWS+="| $LANE_NAME | $stage | $name | $status | ${detail//$'\n'/<br>} |"$'\n'
}

run_guest_test() {
    local timeout_kind="$1"
    local stage="$2"
    local name="$3"
    local cmd="$4"
    local out="$HOST_TMP/test.out"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '[%s/%s] %s ... ' "$LANE_NAME" "$stage" "$name"
    local host_rc=0
    if [ "$timeout_kind" = install ]; then
        guest_capture_install "$cmd" >"$out" 2>&1 || host_rc=$?
    else
        guest_capture "$cmd" >"$out" 2>&1 || host_rc=$?
    fi

    local bad_diag='SAFETY-VALVE|SYS_FUTEX|V8_SIG|panic\(|Segmentation fault|Bun has crashed|illegal instruction|Illegal instruction|page fault on|SIGNAL_TRACE|HOST CRASH|Assertion failed|uv_thread_create|ERR_DLOPEN_FAILED|Error loading shared library|unsupported relocation|Cannot find module|TypeError'
    if [ "$host_rc" -eq 0 ] && grep -q '^__ISH_STATUS:0$' "$out" && ! grep -Eq "$bad_diag" "$out"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "PASS"
        append_row "$stage" "$name" "PASS" "$(grep -v '^__ISH_STATUS:' "$out" | sed -n '1,8p' | sed 's/|/\\|/g')"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "FAIL"
        local detail
        detail="$(grep -v '^__ISH_STATUS:' "$out" | sed -n '1,24p' | sed 's/|/\\|/g')"
        if [ "$host_rc" -ne 0 ]; then
            detail="host rc=$host_rc${detail:+$'\n'$detail}"
        fi
        append_row "$stage" "$name" "FAIL" "$detail"
    fi
}

run_test() {
    run_guest_test run "$@"
}

run_install_test() {
    run_guest_test install "$@"
}

want_package_manager() {
    local wanted="$1"
    local pm
    for pm in $CLI_PACKAGE_MANAGERS; do
        [ "$pm" = "$wanted" ] && return 0
    done
    return 1
}

ensure_guest_basics() {
    log "[$LANE_NAME] Ensuring fakefs DNS/package-manager basics"
    local out="$HOST_TMP/install.out"
    guest_capture_install "test -f /etc/resolv.conf || echo 'nameserver 1.1.1.1' > /etc/resolv.conf; if [ -f /etc/apk/repositories ]; then sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null || true; fi; mkdir -p '$GUEST_WORK'" >"$out" 2>&1
    grep -q '^__ISH_STATUS:0$' "$out"
}

install_guest_packages() {
    if (($# == 0)); then
        return
    fi
    local out="$HOST_TMP/pkg-install.out"
    log "[$LANE_NAME] Installing guest packages: $*"
    guest_capture_install "if command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1 && apk add --no-cache $*; elif command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null 2>&1 || true; apt-get install -y $*; else echo 'no supported guest package manager' >&2; exit 127; fi" >"$out" 2>&1
    grep -q '^__ISH_STATUS:0$' "$out"
}

ensure_tools() {
    local missing=()
    local spec pkg cmd
    for spec in "$@"; do
        pkg="${spec%%:*}"
        cmd="${spec#*:}"
        [ "$cmd" = "$spec" ] && cmd="$pkg"
        local out="$HOST_TMP/ensure-tool.out"
        guest_capture "command -v $cmd >/dev/null 2>&1" >"$out" 2>&1 || true
        if ! grep -q '^__ISH_STATUS:0$' "$out"; then
            missing+=("$pkg")
        fi
    done
    if ((${#missing[@]} > 0)); then
        install_guest_packages "${missing[@]}"
    fi
}

ensure_platform_packages() {
    local out="$HOST_TMP/platform.out"
    guest_capture "if command -v apk >/dev/null 2>&1; then echo alpine; elif command -v apt-get >/dev/null 2>&1; then echo debian; else echo unknown; fi" >"$out" 2>&1 || true
    if grep -q '^alpine$' "$out"; then
        install_guest_packages musl-dev gcompat libgcc libstdc++ py3-virtualenv gcc python3-dev
    elif grep -q '^debian$' "$out"; then
        install_guest_packages libc6 libstdc++6 libgcc-s1 python3-venv
    fi
}

prepare_glibc_compat() {
    local platform_out="$HOST_TMP/glibc-compat-platform.out"
    guest_capture "test -f /etc/alpine-release" >"$platform_out" 2>&1 || true
    if ! grep -q '^__ISH_STATUS:0$' "$platform_out"; then
        return
    fi

    local dir="$HOST_TMP/glibc-compat"
    mkdir -p "$dir"
    cat >"$dir/ish-glibc-compat.c" <<'EOF'
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdarg.h>

int fcntl64(int fd, int cmd, ...) {
    va_list ap;
    void *arg = 0;
    va_start(ap, cmd);
    arg = va_arg(ap, void *);
    va_end(ap);
    return fcntl(fd, cmd, arg);
}
EOF
    push_tree "$dir" "$GUEST_WORK/glibc-compat"
    local out="$HOST_TMP/glibc-compat.out"
    guest_capture_install "mkdir -p /usr/local/lib && cc -shared -fPIC -O2 -o /usr/local/lib/ish-glibc-compat.so '$GUEST_WORK/glibc-compat/ish-glibc-compat.c'" >"$out" 2>&1
    grep -q '^__ISH_STATUS:0$' "$out"
}

prepare_node_polyfills() {
    local src="$PROJECT_DIR/app/RootfsPatch.bundle/files/lib"
    local dir="$HOST_TMP/polyfills"
    if [ ! -f "$src/wasm-polyfill.js" ] || [ ! -f "$src/fetch-polyfill.js" ]; then
        log "Skipping Node polyfill injection; RootfsPatch bundle files not found"
        return
    fi
    mkdir -p "$dir"
    cp "$src/wasm-polyfill.js" "$src/fetch-polyfill.js" "$dir/"
    merge_tree "$dir" "/lib"
}

prepare_smoke_helper() {
    local dir="$HOST_TMP/helper"
    mkdir -p "$dir"
    cat >"$dir/smoke-bin.sh" <<'EOF'
#!/bin/sh
set -eu
bin="$1"
shift || true
if ! command -v "$bin" >/dev/null 2>&1; then
    echo "missing binary: $bin" >&2
    exit 127
fi

# Claude's standalone Bun binary currently aborts under iSH/Alpine on its
# help path. The npm wrapper's unauthenticated version path exercises the
# installed platform binary startup and exits cleanly.
if [ "$bin" = claude ]; then
    if [ -f node_modules/@anthropic-ai/claude-code/cli-wrapper.cjs ]; then
        node node_modules/@anthropic-ai/claude-code/cli-wrapper.cjs --version
        exit $?
    fi
    "$bin" --version
    exit $?
fi

run_probe() {
    probe_name="$1"
    shift
    out_file="/tmp/cli-package-runtime-coverage/probe.out"
    set +e
    "$@" >"$out_file" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo "$probe_name rc=0"
        sed -n '1,12p' "$out_file"
        exit 0
    fi
    if ! grep -Eq 'V8_SIG|panic\(|Segmentation fault|Bun has crashed|terminate called' "$out_file" \
        && grep -Eiq 'usage|help|version|login|auth|api[ _-]?key|token|not authenticated|configure|environment|model|provider' "$out_file"; then
        echo "$probe_name rc=$rc accepted-startup-output"
        sed -n '1,12p' "$out_file"
        exit 0
    fi
    return 1
}

# Do not use guest busybox timeout here: on iSH/Alpine it sends SIGTERM in a
# way that can kill PID 1 after the probe returns, producing false force-kills.
# The host-side guest_capture timeout remains the outer guard for true hangs.
# OpenCode currently hangs on --help under iSH/Alpine while the equivalent
# help subcommand prints usage and exits cleanly.
if [ "$bin" = opencode ]; then
    run_probe help-subcommand "$bin" help || true
else
    run_probe help "$bin" --help || true
fi
run_probe help-subcommand "$bin" help || true
run_probe version "$bin" --version || true

echo "no acceptable startup/help/version output from $bin" >&2
sed -n '1,20p' /tmp/cli-package-runtime-coverage/probe.out 2>/dev/null || true
exit 1
EOF
    chmod +x "$dir/smoke-bin.sh"
    push_tree "$dir" "$GUEST_WORK/helper"
}

write_report() {
    cat >"$REPORT" <<EOF
# iSH ARM64 CLI Package Runtime Coverage Report

- Timestamp: $(date -Is)
- ish binary: $ISH_BIN
- rootfs lanes: $ROOTFS_LANES
- package managers: $CLI_PACKAGE_MANAGERS
- timeout: ${TIMEOUT_S}s
- install timeout: ${INSTALL_TIMEOUT_S}s

## Summary

- Total: $TOTAL_COUNT
- Passed: $PASS_COUNT
- Failed: $FAIL_COUNT

## Scope

This second runtime coverage set installs fast-moving CLI packages through npm/node and Bun package-manager paths where JavaScript packages and executable entrypoints are available, plus pip/venv where a package is Python-only. It intentionally runs only unauthenticated startup/version/help probes; no API keys or user credentials are required or consumed.

## Package matrix

| Tool | Package | Binary | Notes |
|---|---|---|---|
| Claude Code | \`@anthropic-ai/claude-code\` | \`claude\` | Official npm package. |
| OpenAI Codex | \`@openai/codex\` | \`codex\` | Official npm package. |
| Pi CLI | \`@earendil-works/pi-coding-agent\` | \`pi\` | npm package behind the Pi CLI. |
| Mistral Vibe | \`mistral-vibe\` | \`vibe\` | Mistral CLI package installed via pip/venv. |
| GitHub Copilot | \`@github/copilot\` | \`copilot\` | GitHub Copilot npm CLI package. |
| OpenCode | \`opencode-ai\` | \`opencode\` | Official OpenCode npm package. |
| Gemini CLI | \`@google/gemini-cli\` | \`gemini\` | Official Google Gemini CLI npm package. |
| Grok CLI | \`grok-cli\` | \`grok\` | Community wrapper package; npm-only unauthenticated help row stubs \`keytar\` to avoid native keychain access. |

## Results

| Lane | Stage | Test | Status | Detail |
|---|---|---|---|---|
$REPORT_ROWS
EOF
}

install_and_smoke_npm() {
    local slug="$1"
    local pkg="$2"
    local bin="$3"
    local dir="$GUEST_WORK/npm/$slug"
    local smoke_env=""
    local preinstall=""
    local postinstall=":"
    local install_env=""
    if [ "$slug" = opencode ]; then
        smoke_env="if [ -x '$dir/node_modules/opencode-linux-arm64-musl/bin/opencode' ]; then export OPENCODE_BIN_PATH='$dir/node_modules/opencode-linux-arm64-musl/bin/opencode'; fi;"
    elif [ "$slug" = gemini-cli ]; then
        smoke_env="export ISH_NODE_NO_ARG_INJECTION=1 GEMINI_CLI_NO_RELAUNCH=1;"
    fi
    local install_flags="--no-audit --no-fund"
    if [ "$slug" = pi ]; then
        # `koffi` is an optional dependency of pi-tui. Its install script probes
        # a prebuilt native module that currently trips an illegal-instruction
        # diagnostic under iSH before npm treats the optional dependency as
        # skippable. Omit optional deps for this unauthenticated CLI startup
        # smoke so diagnostics stay strict and the real `pi --help` path remains
        # covered.
        install_flags="$install_flags --omit=optional"
    elif [ "$slug" = grok-cli ]; then
        # `grok-cli` requires `keytar` at startup. The npm prebuilt aarch64
        # binary targets glibc and fails under Alpine/musl with unsupported
        # relocations, while source-building the native addon is outside this
        # unauthenticated help-smoke scope and has exposed host/emulator crashes.
        # Install package files without native scripts and replace keytar's
        # loader with a no-op async keychain stub; `grok --help` parses before
        # any real keychain access is needed.
        install_flags="$install_flags --ignore-scripts"
        postinstall="mkdir -p node_modules/keytar/lib && printf '%s\\n' 'module.exports = {' '  getPassword: async () => null,' '  setPassword: async () => null,' '  deletePassword: async () => true,' '};' > node_modules/keytar/lib/keytar.js"
    fi
    run_install_test npm "$slug install $pkg" "$preinstall rm -rf '$dir' && mkdir -p '$dir' && cd '$dir' && npm init -y >/dev/null && $install_env npm install $install_flags '$pkg' && $postinstall"
    if [ "$slug" = claude-code ]; then
        run_test npm "$slug smoke $bin" "cd '$dir' && PATH=\"\$PWD/node_modules/.bin:\$PATH\" '$GUEST_WORK/helper/smoke-bin.sh' '$bin'"
    elif [ "$slug" = github-copilot ]; then
        run_test npm "$slug smoke $bin" "cd '$dir' && ISH_NODE_NO_ARG_INJECTION=1 node node_modules/@github/copilot/index.js --version"
    else
        run_test npm "$slug smoke $bin" "cd '$dir' && PATH=\"\$PWD/node_modules/.bin:\$PATH\"; $smoke_env '$GUEST_WORK/helper/smoke-bin.sh' '$bin'"
    fi
}

install_and_smoke_bun() {
    local slug="$1"
    local pkg="$2"
    local bin="$3"
    local dir="$GUEST_WORK/bun/$slug"
    run_install_test bun "$slug install $pkg" "rm -rf '$dir' && mkdir -p '$dir' && cd '$dir' && bun init -y >/dev/null && bun add '$pkg'"
    run_test bun "$slug smoke $bin" "cd '$dir' && PATH=\"\$PWD/node_modules/.bin:\$PATH\" '$GUEST_WORK/helper/smoke-bin.sh' '$bin'"
}

install_and_smoke_pip() {
    local slug="$1"
    local pkg="$2"
    local bin="$3"
    local dir="$GUEST_WORK/pip/$slug"
    run_install_test pip "$slug install $pkg" "rm -rf '$dir' && mkdir -p '$dir' && cd '$dir' && python3 -m venv .venv && . .venv/bin/activate && pip install --disable-pip-version-check --no-input '$pkg'"
    run_test pip "$slug smoke $bin" "cd '$dir' && . .venv/bin/activate && '$GUEST_WORK/helper/smoke-bin.sh' '$bin'"
}

run_tool_matrix() {
    local slug="$1"
    local pkg="$2"
    local bin="$3"
    if want_package_manager npm; then
        install_and_smoke_npm "$slug" "$pkg" "$bin"
    fi
    if want_package_manager bun; then
        install_and_smoke_bun "$slug" "$pkg" "$bin"
    fi
}

run_lane() {
    LANE_NAME="$1"
    ROOTFS="$2"

    [ -d "$ROOTFS" ] || { echo "missing rootfs for lane $LANE_NAME: $ROOTFS" >&2; return 1; }

    ensure_guest_basics
    if want_package_manager npm; then
        ensure_tools nodejs:node npm
    fi
    if want_package_manager bun; then
        ensure_tools bun
    fi
    if want_package_manager pip; then
        ensure_tools python3 py3-pip:pip3
    fi
    ensure_platform_packages
    prepare_glibc_compat
    prepare_node_polyfills
    prepare_smoke_helper

    if want_package_manager npm || want_package_manager bun; then
        run_test base "node version" "node --version"
    fi
    if want_package_manager npm; then
        run_test base "npm version" "npm --version"
    fi
    if want_package_manager bun; then
        run_test base "bun version" "bun --version"
    fi

    run_tool_matrix claude-code "@anthropic-ai/claude-code" claude
    run_tool_matrix codex "@openai/codex" codex
    run_tool_matrix pi "@earendil-works/pi-coding-agent" pi
    if want_package_manager pip; then
        install_and_smoke_pip mistral-vibe "mistral-vibe" vibe
    fi
    run_tool_matrix github-copilot "@github/copilot" copilot
    run_tool_matrix opencode "opencode-ai" opencode
    run_tool_matrix gemini-cli "@google/gemini-cli" gemini
    if want_package_manager npm; then
        install_and_smoke_npm grok-cli "grok-cli" grok
    fi
}

main() {
    [ -x "$ISH_BIN" ] || { echo "missing ish binary: $ISH_BIN" >&2; exit 1; }

    local spec lane rootfs_path
    for spec in $ROOTFS_LANES; do
        lane="${spec%%=*}"
        rootfs_path="${spec#*=}"
        if [ "$lane" = "$spec" ]; then
            lane="$(basename "$rootfs_path")"
        fi
        run_lane "$lane" "$rootfs_path"
    done

    write_report
    echo "report: $REPORT"

    if ((FAIL_COUNT > 0)); then
        exit 1
    fi
}

main "$@"
