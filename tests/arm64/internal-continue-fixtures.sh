#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ISH_BIN="${ISH_BIN:-$PROJECT_DIR/build-arm64-linux/ish}"
ROOTFS="${ROOTFS:-$PROJECT_DIR/alpine-arm64-fakefs}"
TIMEOUT_S="${TIMEOUT_S:-120}"
REPORT_DIR="${REPORT_DIR:-/workspace/tmp}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPORT_DIR/ish-arm64-internal-continue-fixtures-$STAMP.md"
GUEST_WORK="/tmp/arm64-internal-continue-fixtures"
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

append_row() {
    local name="$1"
    local status="$2"
    local detail="$3"
    REPORT_ROWS+="| $name | $status | ${detail//$'\n'/<br>} |"$'\n'
}

run_host_test() {
    local name="$1"
    local env_spec="$2"
    local cmd="$3"
    local expect_kind="$4"
    local expect_text="$5"
    local out="$HOST_TMP/${name//[^A-Za-z0-9_]/_}.out"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '[internal-continue] %s ... ' "$name"

    local -a env_args=()
    if [ -n "$env_spec" ]; then
        # shellcheck disable=SC2206
        env_args=($env_spec)
    fi

    if env "${env_args[@]}" timeout "$TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -c "export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; $cmd" >"$out" 2>&1; then
        case "$expect_kind" in
            exact)
                if grep -qx "$expect_text" "$out" && ! grep -q 'ARM64_FUSION_STATS' "$out"; then
                    PASS_COUNT=$((PASS_COUNT + 1))
                    echo PASS
                    append_row "$name" PASS "$(sed -n '1,8p' "$out" | sed 's/|/\\|/g')"
                    return
                fi
                ;;
            stats-zero)
                if grep -qx "$expect_text" "$out" && grep -Eq 'internal_continue=0($|[[:space:]])' "$out"; then
                    PASS_COUNT=$((PASS_COUNT + 1))
                    echo PASS
                    append_row "$name" PASS "$(sed -n '1,8p' "$out" | sed 's/|/\\|/g')"
                    return
                fi
                ;;
            stats-positive)
                if grep -qx "$expect_text" "$out" && grep -Eq 'internal_continue=[1-9][0-9]*' "$out"; then
                    PASS_COUNT=$((PASS_COUNT + 1))
                    echo PASS
                    append_row "$name" PASS "$(sed -n '1,8p' "$out" | sed 's/|/\\|/g')"
                    return
                fi
                ;;
        esac
    fi

    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo FAIL
    append_row "$name" FAIL "$(sed -n '1,20p' "$out" | sed 's/|/\\|/g')"
}

push_tree() {
    local src="$1"
    local dst="$2"
    tar -C "$src" -cf - . | timeout "$TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -c "rm -rf '$dst' && mkdir -p '$dst' && tar -xf - -C '$dst'"
}

write_report() {
    cat >"$REPORT" <<EOF_REPORT
# ARM64 internal-continue fixture report

- Generated: $(date -Is)
- Binary: $ISH_BIN
- Rootfs: $ROOTFS
- Timeout: ${TIMEOUT_S}s
- Total: $TOTAL_COUNT
- Passed: $PASS_COUNT
- Failed: $FAIL_COUNT

| Test | Status | Detail |
|---|---|---|
$REPORT_ROWS
EOF_REPORT
    printf '\n%s\n' "$REPORT"
}

prepare_fixture() {
    local dir="$HOST_TMP/src"
    mkdir -p "$dir"
    cat >"$dir/internal_continue_fixture.c" <<'EOF_C'
#define _GNU_SOURCE
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <ucontext.h>

uintptr_t expected_internal_fault_pc;

int ic_branch_fixture(int v);
int ic_call_adjacent_fixture(int v);
void ic_internal_fault_fixture(int v);

__asm__(
".text\n"
".align 2\n"
".global ic_branch_fixture\n"
"ic_branch_fixture:\n"
"    cmp w0, #0\n"
"    b.eq 1f\n"
"    mov w0, #22\n"
"    ret\n"
"1:  mov w0, #11\n"
"    ret\n"
".global ic_call_adjacent_fixture\n"
"ic_call_adjacent_fixture:\n"
"    stp x29, x30, [sp, #-16]!\n"
"    bl ic_call_helper_fixture\n"
"    ldp x29, x30, [sp], #16\n"
"    cmp w0, #7\n"
"    b.eq 2f\n"
"    add w0, w0, #5\n"
"    ret\n"
"2:  add w0, w0, #9\n"
"    ret\n"
"ic_call_helper_fixture:\n"
"    add w0, w0, #1\n"
"    ret\n"
".global ic_internal_fault_fixture\n"
"ic_internal_fault_fixture:\n"
"    cmp w0, #0\n"
"    b.eq 4f\n"
"    adrp x10, expected_internal_fault_pc\n"
"    add x10, x10, :lo12:expected_internal_fault_pc\n"
"    adr x9, 3f\n"
"    str x9, [x10]\n"
"    mov x11, xzr\n"
"3:  ldr x12, [x11]\n"
"    mov w0, #99\n"
"    ret\n"
"4:  ret\n"
);

static sigjmp_buf jb;
static volatile uintptr_t observed_pc;
static volatile uintptr_t observed_fault;

static void handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    ucontext_t *uc = (ucontext_t *)uctx;
    observed_pc = (uintptr_t)uc->uc_mcontext.pc;
    observed_fault = (uintptr_t)si->si_addr;
    siglongjmp(jb, 1);
}

static int branch_fixture(void) {
    int fail = 0;
    for (int i = 0; i < 64; i++) {
        if (ic_branch_fixture(0) != 11)
            fail++;
        if (ic_branch_fixture(1) != 22)
            fail++;
    }
    if (fail) {
        printf("branch-fail %d\n", fail);
        return 1;
    }
    puts("branch-ok");
    return 0;
}

static int call_adjacent_fixture(void) {
    int fail = 0;
    for (int i = 0; i < 64; i++) {
        if (ic_call_adjacent_fixture(6) != 16)
            fail++;
        if (ic_call_adjacent_fixture(1) != 7)
            fail++;
    }
    if (fail) {
        printf("call-adjacent-fail %d\n", fail);
        return 1;
    }
    puts("call-adjacent-ok");
    return 0;
}

static int fault_fixture(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) != 0)
        return 1;

    if (sigsetjmp(jb, 1) == 0) {
        ic_internal_fault_fixture(1);
        puts("missing-fault");
        return 1;
    }

    if (observed_fault != 0 || observed_pc != expected_internal_fault_pc) {
        fprintf(stderr, "internal fault pc mismatch expected=%#lx observed=%#lx fault=%#lx\n",
                (unsigned long)expected_internal_fault_pc,
                (unsigned long)observed_pc,
                (unsigned long)observed_fault);
        return 1;
    }

    puts("internal-fault-pc-ok");
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s branch|call|fault\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "branch") == 0)
        return branch_fixture();
    if (strcmp(argv[1], "call") == 0)
        return call_adjacent_fixture();
    if (strcmp(argv[1], "fault") == 0)
        return fault_fixture();
    return 2;
}
EOF_C
}

main() {
    [ -x "$ISH_BIN" ] || { echo "missing ish binary: $ISH_BIN" >&2; exit 1; }
    [ -d "$ROOTFS" ] || { echo "missing rootfs: $ROOTFS" >&2; exit 1; }

    prepare_fixture
    push_tree "$HOST_TMP/src" "$GUEST_WORK"

    run_host_test "build fixture" "" "cd '$GUEST_WORK' && command -v gcc >/dev/null && gcc -O0 -fno-pie -no-pie internal_continue_fixture.c -o internal_continue_fixture && test -x internal_continue_fixture && echo build-ok" exact "build-ok"
    run_host_test "default branch fixture stays silent" "" "cd '$GUEST_WORK' && ./internal_continue_fixture branch" exact "branch-ok"
    run_host_test "stats-only default-off fixture" "ISH_ARM64_FUSION_STATS=1" "cd '$GUEST_WORK' && ./internal_continue_fixture branch" stats-zero "branch-ok"
    run_host_test "opt-in branch taken/fallthrough fixture" "ISH_ARM64_FUSION_STATS=1 ISH_ARM64_INTERNAL_CONTINUE=1" "cd '$GUEST_WORK' && ./internal_continue_fixture branch" stats-positive "branch-ok"
    run_host_test "opt-in call-adjacent fixture" "ISH_ARM64_FUSION_STATS=1 ISH_ARM64_INTERNAL_CONTINUE=1" "cd '$GUEST_WORK' && ./internal_continue_fixture call" stats-positive "call-adjacent-ok"
    run_host_test "opt-in internal-segment fault PC fixture" "ISH_ARM64_FUSION_STATS=1 ISH_ARM64_INTERNAL_CONTINUE=1" "cd '$GUEST_WORK' && ./internal_continue_fixture fault" stats-positive "internal-fault-pc-ok"

    write_report
    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
