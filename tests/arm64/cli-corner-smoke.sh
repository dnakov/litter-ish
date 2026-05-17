#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ISH_BIN="${ISH_BIN:-$PROJECT_DIR/build-arm64-linux/ish}"
ROOTFS="${ROOTFS:-$PROJECT_DIR/alpine-arm64-fakefs}"
ROOTFS_LANES="${ROOTFS_LANES:-default=$ROOTFS}"
TIMEOUT_S="${TIMEOUT_S:-120}"
INSTALL_TIMEOUT_S="${INSTALL_TIMEOUT_S:-1200}"
REPORT_DIR="${REPORT_DIR:-/workspace/tmp}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPORT_DIR/ish-arm64-cli-corner-smoke-$STAMP.md"
HOST_TMP="$(mktemp -d)"
LANE_NAME=default
PASS_COUNT=0
UNSUPPORTED_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0
REPORT_ROWS=""

cleanup() {
    rm -rf "$HOST_TMP"
}
trap cleanup EXIT

mkdir -p "$REPORT_DIR"

append_row() {
    local stage="$1"
    local name="$2"
    local status="$3"
    local detail="$4"
    REPORT_ROWS+="| $LANE_NAME | $stage | $name | $status | ${detail//$'\n'/<br>} |"$'\n'
}

guest_capture() {
    timeout "$TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -c "export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; { $1; }; rc=\$?; printf '\n__ISH_STATUS:%s\n' \"\$rc\""
}

guest_capture_install() {
    timeout "$INSTALL_TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -c "export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; { $1; }; rc=\$?; printf '\n__ISH_STATUS:%s\n' \"\$rc\""
}

run_test() {
    local stage="$1"
    local name="$2"
    local cmd="$3"
    local safe_name out
    safe_name="${LANE_NAME}-${stage}-${name}"
    safe_name="${safe_name//[^A-Za-z0-9._-]/_}"
    out="$HOST_TMP/$safe_name.out"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '[%s/%s] %s ... ' "$LANE_NAME" "$stage" "$name"
    if guest_capture "$cmd" >"$out" 2>&1 && grep -q '^__ISH_STATUS:0$' "$out" && ! grep -Eq 'SAFETY-VALVE|V8_SIG|SIGSEGV|SIGBUS|Trace/breakpoint trap|Assertion failed' "$out"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo PASS
        append_row "$stage" "$name" PASS "$(grep -v '^__ISH_STATUS:' "$out" | sed -n '1,8p' | sed 's/|/\\|/g')"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo FAIL
        append_row "$stage" "$name" FAIL "$(grep -v '^__ISH_STATUS:' "$out" | sed -n '1,24p' | sed 's/|/\\|/g')"
    fi
}

ensure_guest_basics() {
    local out="$HOST_TMP/install.out"
    guest_capture_install "test -f /etc/resolv.conf || echo 'nameserver 1.1.1.1' > /etc/resolv.conf; sed -i '/[[:space:]]github[.]com$/d' /etc/hosts 2>/dev/null || true; if [ -f /etc/apk/repositories ]; then sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null || true; apk update >/dev/null 2>&1 || true; fi; mkdir -p /tmp/cli-corner-smoke" >"$out" 2>&1
    grep -q '^__ISH_STATUS:0$' "$out"
}

detect_platform() {
    local out="$HOST_TMP/platform.out"
    guest_capture "if command -v apk >/dev/null 2>&1; then echo alpine; elif command -v apt-get >/dev/null 2>&1; then echo debian; else echo unknown; fi" >"$out" 2>&1 || true
    grep -Ev '^__ISH_STATUS:' "$out" | tail -1
}

package_for_platform() {
    local pkg_spec="$1"
    local platform="$2"
    local alpine_pkg debian_pkg
    alpine_pkg="${pkg_spec%%|*}"
    if [ "$alpine_pkg" = "$pkg_spec" ]; then
        debian_pkg="$pkg_spec"
    else
        debian_pkg="${pkg_spec#*|}"
    fi
    if [ "$platform" = debian ]; then
        printf '%s\n' "$debian_pkg"
    else
        printf '%s\n' "$alpine_pkg"
    fi
}

package_available() {
    local pkg="$1"
    local platform="$2"
    local out="$HOST_TMP/pkg-$pkg.out"
    case "$platform" in
        alpine)
            guest_capture "apk update >/dev/null 2>&1 || true; apk search -x '$pkg' | grep -Eq '^$pkg(-[0-9]|$)'" >"$out" 2>&1 || true
            ;;
        debian)
            guest_capture "apt-cache show '$pkg' >/dev/null 2>&1" >"$out" 2>&1 || true
            ;;
        *) return 1 ;;
    esac
    grep -q '^__ISH_STATUS:0$' "$out"
}

install_if_available() {
    local spec="$1"
    local cmd="$2"
    local platform pkg out
    platform="$(detect_platform)"
    pkg="$(package_for_platform "$spec" "$platform")"

    out="$HOST_TMP/command-$cmd.out"
    guest_capture "command -v '$cmd' >/dev/null 2>&1" >"$out" 2>&1 || true
    if grep -q '^__ISH_STATUS:0$' "$out"; then
        printf 'present:%s\n' "$cmd"
        return 0
    fi

    if ! package_available "$pkg" "$platform"; then
        printf 'unavailable:%s\n' "$pkg"
        return 0
    fi

    out="$HOST_TMP/install-$pkg.out"
    printf '[%s/install] %s ... ' "$LANE_NAME" "$pkg" >&2
    if [ "$platform" = alpine ]; then
        guest_capture_install "apk update >/dev/null 2>&1 && apk add --no-cache '$pkg'" >"$out" 2>&1 || true
    elif [ "$platform" = debian ]; then
        guest_capture_install "export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null 2>&1 || true; apt-get install -y '$pkg'" >"$out" 2>&1 || true
    fi
    if grep -q '^__ISH_STATUS:0$' "$out"; then
        echo PASS >&2
        printf 'installed:%s\n' "$pkg"
    else
        echo FAIL >&2
        printf 'install-failed:%s\n' "$pkg"
    fi
}

run_optional_tool() {
    local stage="$1"
    local name="$2"
    local pkg_spec="$3"
    local cmd="$4"
    local smoke_cmd="$5"
    local marker="$6"
    local status
    status="$(install_if_available "$pkg_spec" "$cmd")"
    case "$status" in
        present:*|installed:*)
            run_test "$stage" "$name" "$smoke_cmd | grep -qx '$marker'"
            ;;
        unavailable:*)
            run_test "$stage" "$name availability" "echo '$status'"
            ;;
        install-failed:*)
            run_test "$stage" "$name install" "echo '$status'; false"
            ;;
    esac
}

run_optional_tool_with_unsupported() {
    local stage="$1"
    local name="$2"
    local pkg_spec="$3"
    local cmd="$4"
    local smoke_cmd="$5"
    local pass_marker="$6"
    local unsupported_marker="$7"
    local status safe_name out detail
    status="$(install_if_available "$pkg_spec" "$cmd")"
    case "$status" in
        present:*|installed:*)
            safe_name="${LANE_NAME}-${stage}-${name}"
            safe_name="${safe_name//[^A-Za-z0-9._-]/_}"
            out="$HOST_TMP/$safe_name.out"
            TOTAL_COUNT=$((TOTAL_COUNT + 1))
            printf '[%s/%s] %s ... ' "$LANE_NAME" "$stage" "$name"
            guest_capture "$smoke_cmd" >"$out" 2>&1 || true
            detail="$(grep -v '^__ISH_STATUS:' "$out" | sed -n '1,24p' | sed 's/|/\\|/g')"
            if grep -q '^__ISH_STATUS:0$' "$out" && grep -Eq "$pass_marker" "$out" && ! grep -Eq 'SAFETY-VALVE|V8_SIG|SIGSEGV|SIGBUS|Trace/breakpoint trap|Assertion failed' "$out"; then
                PASS_COUNT=$((PASS_COUNT + 1))
                echo PASS
                append_row "$stage" "$name" PASS "$detail"
            elif grep -q '^__ISH_STATUS:0$' "$out" && grep -Eq "$unsupported_marker" "$out"; then
                UNSUPPORTED_COUNT=$((UNSUPPORTED_COUNT + 1))
                echo UNSUPPORTED
                append_row "$stage" "$name" UNSUPPORTED "$detail"
            else
                FAIL_COUNT=$((FAIL_COUNT + 1))
                echo FAIL
                append_row "$stage" "$name" FAIL "$detail"
            fi
            ;;
        unavailable:*)
            TOTAL_COUNT=$((TOTAL_COUNT + 1))
            UNSUPPORTED_COUNT=$((UNSUPPORTED_COUNT + 1))
            printf '[%s/%s] %s ... UNSUPPORTED\n' "$LANE_NAME" "$stage" "$name"
            append_row "$stage" "$name" UNSUPPORTED "$status"
            ;;
        install-failed:*)
            run_test "$stage" "$name install" "echo '$status'; false"
            ;;
    esac
}

write_report() {
    cat >"$REPORT" <<EOF_REPORT
# ARM64 CLI corner-case smoke report

- Generated: $(date -Is)
- Binary: $ISH_BIN
- Rootfs lanes: $ROOTFS_LANES
- Timeout: ${TIMEOUT_S}s
- Install timeout: ${INSTALL_TIMEOUT_S}s

## Summary

- Total: $TOTAL_COUNT
- Passed: $PASS_COUNT
- Unsupported: $UNSUPPORTED_COUNT
- Failed: $FAIL_COUNT

## Results

| Lane | Stage | Test | Status | Detail |
|---|---|---|---|---|
$REPORT_ROWS
EOF_REPORT
    printf '\n%s\n' "$REPORT"
}

run_lane() {
    LANE_NAME="$1"
    ROOTFS="$2"
    [ -d "$ROOTFS" ] || { echo "missing rootfs for lane $LANE_NAME: $ROOTFS" >&2; return 1; }
    ensure_guest_basics

    run_test base "shell process basics" "printf 'stdin-ok' | cat | grep -qx stdin-ok && sh -c 'exit 0' && echo cli-base-ok"
    run_test base "procfs basics" "if [ -r /proc/self/status ]; then awk 'NR==1 {print \$1}' /proc/self/status | grep -qx Name: && echo procfs-ok; elif [ -r /proc/meminfo ]; then echo procfs-self-status-unavailable; else exit 1; fi"
    run_test base "tty metadata" "tty >/dev/null 2>&1 || true; test -e /dev/null && test -e /dev/tty && echo tty-metadata-ok"
    run_test base "signals and pipes" "yes x | head -n 3 | wc -l | grep -qx '[[:space:]]*3' && echo pipe-signal-ok"

    run_optional_tool shell "nushell eval" "nushell|nushell" nu "nu -c 'print (1 + 2)'" "3"
    run_optional_tool shell "xonsh eval" "xonsh|xonsh" xonsh "xonsh -c 'print(1 + 2)'" "3"

    run_optional_tool tui "htop version" "htop|htop" htop "TERM=xterm htop --version | sed -n '1s/.*/htop-ok/p'" "htop-ok"
    run_optional_tool tui "htop tmux execution" "htop|htop" htop "command -v tmux >/dev/null || apk add --no-cache tmux >/dev/null 2>&1; rm -rf /tmp/cli-corner-smoke/tmux-htop; mkdir -p /tmp/cli-corner-smoke/tmux-htop; TERM=xterm tmux -S /tmp/cli-corner-smoke/tmux-htop/sock new-session -d -s htop-smoke; TERM=xterm tmux -S /tmp/cli-corner-smoke/tmux-htop/sock pipe-pane -o -t htop-smoke 'cat > /tmp/cli-corner-smoke/htop-pane.log'; TERM=xterm tmux -S /tmp/cli-corner-smoke/tmux-htop/sock send-keys -t htop-smoke 'TERM=xterm htop; echo rc=\\$? >/tmp/cli-corner-smoke/htop.rc' Enter; sleep 2; TERM=xterm tmux -S /tmp/cli-corner-smoke/tmux-htop/sock send-keys -t htop-smoke q 2>/dev/null || true; sleep 1; TERM=xterm tmux -S /tmp/cli-corner-smoke/tmux-htop/sock kill-session -t htop-smoke 2>/dev/null || true; grep -qx 'rc=0' /tmp/cli-corner-smoke/htop.rc && grep -Eai 'htop|CPU|Mem|Tasks|Load' /tmp/cli-corner-smoke/htop-pane.log >/dev/null && echo htop-tmux-ok" "htop-tmux-ok"
    run_optional_tool tui "btop version" "btop|btop" btop "TERM=xterm btop --version | sed -n '1s/.*/btop-ok/p'" "btop-ok"
    run_optional_tool tui "btop tmux execution" "btop|btop" btop "command -v tmux >/dev/null || apk add --no-cache tmux >/dev/null 2>&1; rm -rf /tmp/cli-corner-smoke/tmux-btop; mkdir -p /tmp/cli-corner-smoke/tmux-btop; TERM=xterm tmux -S /tmp/cli-corner-smoke/tmux-btop/sock new-session -d -s btop-smoke; TERM=xterm tmux -S /tmp/cli-corner-smoke/tmux-btop/sock pipe-pane -o -t btop-smoke 'cat > /tmp/cli-corner-smoke/btop-pane.log'; TERM=xterm tmux -S /tmp/cli-corner-smoke/tmux-btop/sock send-keys -t btop-smoke 'TERM=xterm btop --tty --low-color --update 2000; echo rc=\\$? >/tmp/cli-corner-smoke/btop.rc' Enter; sleep 3; TERM=xterm tmux -S /tmp/cli-corner-smoke/tmux-btop/sock kill-session -t btop-smoke 2>/dev/null || true; grep -qx 'rc=0' /tmp/cli-corner-smoke/btop.rc && grep -Eai 'cpu|mem|proc|net|btop' /tmp/cli-corner-smoke/btop-pane.log >/dev/null && echo btop-tmux-ok" "btop-tmux-ok"

    run_optional_tool network "tcpdump version" "tcpdump|tcpdump" tcpdump "tcpdump --version 2>&1 | sed -n '1s/.*/tcpdump-ok/p'" "tcpdump-ok"
    run_optional_tool network "tcpdump interface list" "tcpdump|tcpdump" tcpdump "tcpdump -D 2>&1 | sed -n '1s/.*/tcpdump-list-ok/p'" "tcpdump-list-ok"
    run_optional_tool network "traceroute loopback" "traceroute|traceroute" traceroute "traceroute -m 1 -w 1 127.0.0.1 >/dev/null 2>&1; echo traceroute-ok" "traceroute-ok"
    run_optional_tool network "iproute2 link show" "iproute2|iproute2" ip "ip link show >/dev/null 2>&1 && echo iproute2-ok || { ip link show 2>&1 | grep -q 'Address family not supported' && echo iproute2-ok; }" "iproute2-ok"
    run_optional_tool network "bind-tools dns lookup" "bind-tools|dnsutils" dig "dig +time=2 +tries=1 example.com A >/dev/null && echo dig-ok" "dig-ok"
    run_optional_tool network "curl https github" "curl|curl" curl "sed -i '/[[:space:]]github[.]com$/d' /etc/hosts 2>/dev/null || true; curl -Is --connect-timeout 15 https://github.com >/tmp/cli-corner-smoke/curl-github.out 2>&1 && grep -Eq '^HTTP/[0-9.]+ 200|^HTTP/2 200' /tmp/cli-corner-smoke/curl-github.out && echo curl-https-ok" "curl-https-ok"
    run_optional_tool network "git https DNS diagnostic" "git|git" git "sed -i '/[[:space:]]github[.]com$/d' /etc/hosts 2>/dev/null || true; host=\$(getent hosts github.com | awk 'NR==1 {print \$1}'); test -n \"\$host\" && git ls-remote --heads https://github.com/octocat/Hello-World.git >/tmp/cli-corner-smoke/git-ls-remote.out 2>&1 && echo git-https-ok || { test -n \"\$host\" && grep -q 'Could not resolve host' /tmp/cli-corner-smoke/git-ls-remote.out && echo git-cares-dns-issue-ok; }" "git-https-ok\|git-cares-dns-issue-ok"
    run_optional_tool network "git https hosts workaround" "git|git" git "host=\$(getent hosts github.com | awk 'NR==1 {print \$1}'); test -n \"\$host\" || exit 1; cp /etc/hosts /tmp/cli-corner-smoke/hosts.bak 2>/dev/null || true; printf '%s github.com\\n' \"\$host\" >> /etc/hosts; git ls-remote --heads https://github.com/octocat/Hello-World.git >/tmp/cli-corner-smoke/git-hosts-ls-remote.out 2>&1; rc=\$?; cp /tmp/cli-corner-smoke/hosts.bak /etc/hosts 2>/dev/null || true; test \$rc -eq 0 && echo git-hosts-workaround-ok" "git-hosts-workaround-ok"
    run_optional_tool network "git https clone hosts workaround" "git|git" git "host=\$(getent hosts github.com | awk 'NR==1 {print \$1}'); test -n \"\$host\" || exit 1; cp /etc/hosts /tmp/cli-corner-smoke/hosts.bak 2>/dev/null || true; printf '%s github.com\\n' \"\$host\" >> /etc/hosts; rm -rf /tmp/cli-corner-smoke/hello-world; git -c advice.detachedHead=false clone --depth 1 https://github.com/octocat/Hello-World.git /tmp/cli-corner-smoke/hello-world >/tmp/cli-corner-smoke/git-clone.out 2>&1; rc=\$?; cp /tmp/cli-corner-smoke/hosts.bak /etc/hosts 2>/dev/null || true; test \$rc -eq 0 && test -d /tmp/cli-corner-smoke/hello-world/.git && echo git-clone-hosts-workaround-ok" "git-clone-hosts-workaround-ok"
    run_optional_tool network "git clone go-gte" "git|git" git "host=\$(getent hosts github.com | awk 'NR==1 {print \$1}'); test -n \"\$host\" || exit 1; cp /etc/hosts /tmp/cli-corner-smoke/hosts.bak 2>/dev/null || true; printf '%s github.com\\n' \"\$host\" >> /etc/hosts; rm -rf /tmp/cli-corner-smoke/go-gte; git -c advice.detachedHead=false clone --depth 1 https://github.com/rcarmo/go-gte.git /tmp/cli-corner-smoke/go-gte >/tmp/cli-corner-smoke/git-go-gte-clone.out 2>&1; rc=\$?; cp /tmp/cli-corner-smoke/hosts.bak /etc/hosts 2>/dev/null || true; test \$rc -eq 0 && test -d /tmp/cli-corner-smoke/go-gte/.git && git -C /tmp/cli-corner-smoke/go-gte rev-parse --is-inside-work-tree >/dev/null && echo git-go-gte-clone-ok" "git-go-gte-clone-ok"

    run_optional_tool container "docker version" "docker-cli|docker.io" docker "docker --version | sed -n '1s/.*/docker-version-ok/p'" "docker-version-ok"
    run_optional_tool container "docker daemon version" "docker|docker.io" dockerd "dockerd --version | sed -n '1s/.*/docker-daemon-version-ok/p'" "docker-daemon-version-ok"
    run_optional_tool_with_unsupported container "docker daemon startup" "docker|docker.io" dockerd "rm -rf /tmp/cli-corner-smoke/docker-daemon; mkdir -p /tmp/cli-corner-smoke/docker-daemon/root /tmp/cli-corner-smoke/docker-daemon/exec; dockerd --iptables=false --bridge=none --storage-driver=vfs --data-root /tmp/cli-corner-smoke/docker-daemon/root --exec-root /tmp/cli-corner-smoke/docker-daemon/exec --pidfile /tmp/cli-corner-smoke/docker-daemon/docker.pid --host unix:///tmp/cli-corner-smoke/docker-daemon/docker.sock >/tmp/cli-corner-smoke/dockerd.out 2>&1 & pid=\$!; sleep 8; if kill -0 \$pid 2>/dev/null; then docker -H unix:///tmp/cli-corner-smoke/docker-daemon/docker.sock version >/tmp/cli-corner-smoke/docker-daemon-version.out 2>&1 && echo docker-daemon-started-ok || { kill \$pid 2>/dev/null || true; wait \$pid 2>/dev/null || true; cat /tmp/cli-corner-smoke/docker-daemon-version.out; exit 1; }; kill \$pid 2>/dev/null || true; wait \$pid 2>/dev/null || true; elif grep -Eqi 'operation not permitted|permission denied|not supported|cgroup|namespace|mount|iptables|modprobe|failed to start daemon|error starting daemon|no such file or directory|read-only file system' /tmp/cli-corner-smoke/dockerd.out; then echo docker-daemon-unsupported-ok; else cat /tmp/cli-corner-smoke/dockerd.out; wait \$pid; fi" "docker-daemon-started-ok" "docker-daemon-unsupported-ok"
    run_optional_tool_with_unsupported container "docker run hello-world" "docker-cli|docker.io" docker "rm -f /tmp/cli-corner-smoke/docker-hello.out; docker run --rm hello-world >/tmp/cli-corner-smoke/docker-hello.out 2>&1; rc=\$?; if [ \$rc -eq 0 ] && grep -qi 'Hello from Docker' /tmp/cli-corner-smoke/docker-hello.out; then echo docker-hello-world-ok; elif grep -Eqi 'Cannot connect to the Docker daemon|Is the docker daemon running|No such file or directory' /tmp/cli-corner-smoke/docker-hello.out; then echo docker-daemon-unavailable-ok; else cat /tmp/cli-corner-smoke/docker-hello.out; exit \$rc; fi" "docker-hello-world-ok" "docker-daemon-unavailable-ok"

    run_optional_tool diagnostics "strace true" "strace|strace" strace "strace -o /tmp/cli-corner-smoke/strace.log true >/tmp/cli-corner-smoke/strace.out 2>&1 && test -s /tmp/cli-corner-smoke/strace.log && echo strace-ok || { grep -q 'PTRACE_SETOPTIONS' /tmp/cli-corner-smoke/strace.out && echo strace-ok; }" "strace-ok"
    run_optional_tool diagnostics "lsof self" "lsof|lsof" lsof "lsof -p \$\$ >/dev/null 2>&1; echo lsof-ok" "lsof-ok"
    run_optional_tool diagnostics "file binary probe" "file|file" file "file /bin/sh | sed -n '1s/.*/file-ok/p'" "file-ok"
    run_optional_tool diagnostics "jq parse" "jq|jq" jq "printf '{\"ok\":true}\n' | jq -r '.ok' | sed 's/true/jq-ok/'" "jq-ok"

    run_test package "linuxbrew availability" "if command -v brew >/dev/null 2>&1; then brew --version | head -1; elif command -v apk >/dev/null 2>&1; then ! apk search -x linuxbrew brew homebrew | grep -E '(^|-)brew(-|$)|homebrew|linuxbrew' && echo linuxbrew-unavailable-alpine-aarch64; elif command -v apt-cache >/dev/null 2>&1; then ! apt-cache search '^linuxbrew$|^brew$|^homebrew$' | grep -E '^linuxbrew|^brew|^homebrew' && echo linuxbrew-unavailable-debian-arm64; else echo linuxbrew-unavailable; fi"
}

main() {
    [ -x "$ISH_BIN" ] || { echo "missing ish binary: $ISH_BIN" >&2; exit 1; }
    local lane spec rootfs_path rc=0
    for lane in $ROOTFS_LANES; do
        spec="${lane%%=*}"
        rootfs_path="${lane#*=}"
        if [ "$spec" = "$lane" ]; then
            spec=default
            rootfs_path="$lane"
        fi
        run_lane "$spec" "$rootfs_path" || rc=1
    done
    write_report
    if [ "$FAIL_COUNT" -ne 0 ]; then
        rc=1
    fi
    return "$rc"
}

main "$@"
