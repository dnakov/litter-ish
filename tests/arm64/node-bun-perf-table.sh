#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ISH_BIN="${ISH_BIN:-$PROJECT_DIR/build-arm64-linux/ish}"
ROOTFS="${ROOTFS:-$PROJECT_DIR/alpine-arm64-fakefs}"
ROOTFS_LANES="${ROOTFS_LANES:-default=$ROOTFS}"
LANE_NAME="${LANE_NAME:-default}"
TIMEOUT_S="${TIMEOUT_S:-180}"
REPORT_DIR="${REPORT_DIR:-/workspace/tmp}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPORT_DIR/ish-arm64-node-bun-perf-$STAMP.md"
HOST_TMP="$(mktemp -d)"
REPORT_ROWS=""
TOTAL_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    rm -rf "$HOST_TMP"
}
trap cleanup EXIT

mkdir -p "$REPORT_DIR"

escape_cell() {
    sed -e 's/|/\\|/g' -e ':a;N;$!ba;s/\n/<br>/g'
}

append_row() {
    local runtime="$1" test_name="$2" status="$3" ms="$4" detail="$5"
    REPORT_ROWS+="| $LANE_NAME | $runtime | $test_name | $status | $ms | $detail |"$'\n'
}

guest_run_timed() {
    local runtime="$1" test_name="$2" cmd="$3" expect_regex="${4:-}"
    local out="$HOST_TMP/out.txt"
    local start_ms end_ms elapsed rc status detail

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '[%s/%s] %s ... ' "$LANE_NAME" "$runtime" "$test_name"

    start_ms="$(date +%s%3N)"
    set +e
    timeout "$TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -lc "export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME=/root NO_COLOR=1 CI=1 TERM=dumb; { $cmd; }; rc=\$?; printf '\n__ISH_STATUS:%s\n' \"\$rc\"" >"$out" 2>&1
    rc=$?
    set -e
    end_ms="$(date +%s%3N)"
    elapsed=$((end_ms - start_ms))

    if [ "$rc" -eq 0 ] && grep -q '^__ISH_STATUS:0$' "$out" && ! grep -Eq 'SAFETY-VALVE|HOST CRASH|Segmentation fault|Bun has crashed|Assertion failed|page fault on|illegal instruction|Illegal instruction' "$out" && { [ -z "$expect_regex" ] || grep -Eq "$expect_regex" "$out"; }; then
        status=PASS
        PASS_COUNT=$((PASS_COUNT + 1))
        echo PASS
    else
        status=FAIL
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo FAIL
    fi

    detail="$(grep -v '^__ISH_STATUS:' "$out" | sed -n '1,8p' | escape_cell)"
    append_row "$runtime" "$test_name" "$status" "$elapsed" "$detail"
}

ensure_lane_basics() {
    timeout "$TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -lc "test -f /etc/resolv.conf || echo nameserver 1.1.1.1 >/etc/resolv.conf; mkdir -p /tmp/node-bun-perf" >/dev/null 2>&1 || true
}

run_lane() {
    LANE_NAME="$1"
    ROOTFS="$2"
    [ -d "$ROOTFS" ] || { echo "missing rootfs for lane $LANE_NAME: $ROOTFS" >&2; return 1; }
    ensure_lane_basics

    guest_run_timed node "version" "node --version" '^v[0-9]+'
    guest_run_timed node "eval" "node -e 'console.log(1+1)'" '^2$'
    guest_run_timed node "json loop" "node -e 'const o={a:Array.from({length:128},(_,i)=>i),s:\"abcdefghijklmnopqrstuvwxyz\"}; let s=\"\"; for (let i=0;i<12000;i++) s=JSON.stringify(o); let n=0; for (let i=0;i<12000;i++) n+=JSON.parse(s).a.length; console.log(n);'" '^1536000$'
    guest_run_timed node "fs small files" "rm -rf /tmp/node-perf-fs && mkdir -p /tmp/node-perf-fs && node -e 'const fs=require(\"fs\"),p=\"/tmp/node-perf-fs\"; for(let i=0;i<300;i++)fs.writeFileSync(p+\"/\"+i+\".txt\",String(i)); let n=0; for(let i=0;i<300;i++){const f=p+\"/\"+i+\".txt\"; n+=fs.statSync(f).size; n+=Number(fs.readFileSync(f,\"utf8\"));} console.log(n);'" '^45640$'
    guest_run_timed node "recursive copy" "rm -rf /tmp/node-perf-src /tmp/node-perf-dst && mkdir -p /tmp/node-perf-src/a /tmp/node-perf-src/b && node -e 'const fs=require(\"fs\"); for(let i=0;i<120;i++){const d=(i%2)?\"a\":\"b\"; fs.writeFileSync(\"/tmp/node-perf-src/\"+d+\"/\"+i+\".txt\",String(i));} fs.cpSync(\"/tmp/node-perf-src\",\"/tmp/node-perf-dst\",{recursive:true}); console.log(fs.readdirSync(\"/tmp/node-perf-dst/a\").length+fs.readdirSync(\"/tmp/node-perf-dst/b\").length);'" '^120$'

    guest_run_timed bun "version" "bun --version" '^[0-9]+[.]'
    guest_run_timed bun "eval" "bun -e 'console.log(1+1)'" '^2$'
    guest_run_timed bun "json loop" "bun -e 'const o={a:Array.from({length:128},(_,i)=>i),s:\"abcdefghijklmnopqrstuvwxyz\"}; let s=\"\"; for (let i=0;i<12000;i++) s=JSON.stringify(o); let n=0; for (let i=0;i<12000;i++) n+=JSON.parse(s).a.length; console.log(n);'" '^1536000$'
    guest_run_timed bun "fs small files" "rm -rf /tmp/bun-perf-fs && mkdir -p /tmp/bun-perf-fs && bun -e 'const fs=require(\"fs\"),p=\"/tmp/bun-perf-fs\"; for(let i=0;i<300;i++)fs.writeFileSync(p+\"/\"+i+\".txt\",String(i)); let n=0; for(let i=0;i<300;i++){const f=p+\"/\"+i+\".txt\"; n+=fs.statSync(f).size; n+=Number(fs.readFileSync(f,\"utf8\"));} console.log(n);'" '^45640$'
    guest_run_timed bun "recursive copy" "rm -rf /tmp/bun-perf-src /tmp/bun-perf-dst && mkdir -p /tmp/bun-perf-src/a /tmp/bun-perf-src/b && bun -e 'const fs=require(\"fs\"); for(let i=0;i<120;i++){const d=(i%2)?\"a\":\"b\"; fs.writeFileSync(\"/tmp/bun-perf-src/\"+d+\"/\"+i+\".txt\",String(i));} fs.cpSync(\"/tmp/bun-perf-src\",\"/tmp/bun-perf-dst\",{recursive:true}); console.log(fs.readdirSync(\"/tmp/bun-perf-dst/a\").length+fs.readdirSync(\"/tmp/bun-perf-dst/b\").length);'" '^120$'
}

for lane in $ROOTFS_LANES; do
    name="${lane%%=*}"
    root="${lane#*=}"
    if [ "$name" = "$root" ]; then
        name="$LANE_NAME"
        root="$ROOTFS"
    fi
    run_lane "$name" "$root"
done

cat >"$REPORT" <<EOF_REPORT
# ARM64 Node/Bun perf table

- Generated: $(date -Is)
- Binary: $ISH_BIN
- Rootfs lanes: $ROOTFS_LANES
- Timeout: ${TIMEOUT_S}s
- Total: $TOTAL_COUNT
- Passed: $PASS_COUNT
- Failed: $FAIL_COUNT

| Lane | Runtime | Test | Status | Wall ms | Detail |
|---|---|---|---:|---:|---|
$REPORT_ROWS
EOF_REPORT

printf '\n%s\n' "$REPORT"
if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
