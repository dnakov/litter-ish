#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ISH_BIN="${ISH_BIN:-$PROJECT_DIR/build-arm64-linux/ish}"
ROOTFS="${ROOTFS:-$PROJECT_DIR/alpine-arm64-fakefs}"
TIMEOUT_S="${TIMEOUT_S:-120}"
INSTALL_TIMEOUT_S="${INSTALL_TIMEOUT_S:-1200}"
REPORT_DIR="${REPORT_DIR:-/workspace/tmp}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPORT_DIR/ish-arm64-runtime-coverage-$STAMP.md"
GUEST_WORK="/tmp/runtime-coverage"
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
    timeout "$TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -c "export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; { $1; }; rc=\$?; printf '\n__ISH_STATUS:%s\n' \"\$rc\""
}

guest_capture_install() {
    timeout "$INSTALL_TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -c "export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; { $1; }; rc=\$?; printf '\n__ISH_STATUS:%s\n' \"\$rc\""
}

push_tree() {
    local src="$1"
    local dst="$2"
    tar -C "$src" -cf - . | timeout "$TIMEOUT_S" "$ISH_BIN" -f "$ROOTFS" /bin/sh -c "rm -rf '$dst' && mkdir -p '$dst' && tar -xf - -C '$dst'"
}

append_row() {
    local stage="$1"
    local name="$2"
    local status="$3"
    local detail="$4"
    REPORT_ROWS+="| $stage | $name | $status | ${detail//$'\n'/<br>} |"$'\n'
}

run_test() {
    local stage="$1"
    local name="$2"
    local cmd="$3"
    local out="$HOST_TMP/test.out"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '[%s] %s ... ' "$stage" "$name"
    if guest_capture "$cmd" >"$out" 2>&1 && grep -q '^__ISH_STATUS:0$' "$out" && ! grep -q 'SAFETY-VALVE' "$out"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "PASS"
        append_row "$stage" "$name" "PASS" "$(grep -v '^__ISH_STATUS:' "$out" | sed -n '1,6p' | sed 's/|/\\|/g')"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "FAIL"
        append_row "$stage" "$name" "FAIL" "$(grep -v '^__ISH_STATUS:' "$out" | sed -n '1,20p' | sed 's/|/\\|/g')"
    fi
}

ensure_guest_basics() {
    log "Ensuring fakefs DNS/apk basics"
    local out="$HOST_TMP/install.out"
    guest_capture_install "test -f /etc/resolv.conf || echo 'nameserver 1.1.1.1' > /etc/resolv.conf; sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null || true; mkdir -p '$GUEST_WORK'" >"$out" 2>&1
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
        log "Installing guest packages: ${missing[*]}"
        local out="$HOST_TMP/apk.out"
        guest_capture_install "apk update >/dev/null 2>&1 && apk add --no-cache ${missing[*]}" >"$out" 2>&1
        grep -q '^__ISH_STATUS:0$' "$out"
    fi
}

prepare_c_fixture() {
    local dir="$HOST_TMP/c"
    mkdir -p "$dir"
    cat >"$dir/hello.c" <<'EOF'
#include <stdio.h>
#include <stdint.h>

int main(void) {
    uint64_t sum = 0;
    for (uint64_t i = 0; i < 100000; i++) sum += i;
    printf("c-runtime-ok %llu\n", (unsigned long long)sum);
    return 0;
}
EOF
    cat >"$dir/sysv_ipc.c" <<'EOF'
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/msg.h>
#include <sys/shm.h>
#include <sys/wait.h>
#include <unistd.h>

struct test_msg {
    long mtype;
    char mtext[64];
};

static void die(const char *what) {
    perror(what);
    exit(1);
}

int main(void) {
    int shmid = shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0600);
    if (shmid < 0) die("shmget");
    char *shared = shmat(shmid, NULL, 0);
    if (shared == (void *) -1) die("shmat");
    strcpy(shared, "parent");

    int msgid = msgget(IPC_PRIVATE, IPC_CREAT | 0600);
    if (msgid < 0) die("msgget");

    pid_t pid = fork();
    if (pid < 0) die("fork");
    if (pid == 0) {
        if (strcmp(shared, "parent") != 0) _exit(2);
        strcpy(shared, "child");
        struct test_msg msg = {.mtype = 2};
        strcpy(msg.mtext, "msg-ok");
        if (msgsnd(msgid, &msg, strlen(msg.mtext) + 1, 0) < 0) _exit(3);
        shmdt(shared);
        _exit(0);
    }

    struct test_msg msg;
    if (msgrcv(msgid, &msg, sizeof(msg.mtext), 2, 0) < 0) die("msgrcv");
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) die("waitpid");
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return 4;
    if (strcmp(shared, "child") != 0) return 5;
    if (strcmp(msg.mtext, "msg-ok") != 0) return 6;

    if (shmdt(shared) < 0) die("shmdt");
    if (shmctl(shmid, IPC_RMID, NULL) < 0) die("shmctl");
    if (msgctl(msgid, IPC_RMID, NULL) < 0) die("msgctl");
    puts("sysv-ipc-ok");
    return 0;
}
EOF
    cat >"$dir/syscall_gaps.c" <<'EOF'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/sem.h>
#include <sys/signalfd.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>
#include <linux/openat2.h>

union semun { int val; struct semid_ds *buf; unsigned short *array; };
static void die(const char *s){perror(s); exit(1);}
int main(){
 int fd=syscall(SYS_memfd_create,"gap",MFD_CLOEXEC); if(fd<0) die("memfd_create"); write(fd,"abc",3); char b[8]={0}; struct iovec iov={b,3}; if(syscall(SYS_preadv2,fd,&iov,1,0,0)!=3) die("preadv2"); if(strcmp(b,"abc")) return 2; struct iovec wiov={(char*)"Z",1}; if(syscall(SYS_pwritev2,fd,&wiov,1,1,0)!=1) die("pwritev2"); memset(b,0,8); pread(fd,b,3,0); if(strcmp(b,"aZc")) return 3;
 struct open_how how={.flags=O_RDONLY}; int ofd=syscall(SYS_openat2,AT_FDCWD,"/tmp/gap-openat2",&how,sizeof(how)); if(ofd>=0) close(ofd); int cfd=open("/tmp/gap-openat2",O_CREAT|O_RDWR,0600); if(cfd<0) die("create"); close(cfd); ofd=syscall(SYS_openat2,AT_FDCWD,"/tmp/gap-openat2",&how,sizeof(how)); if(ofd<0) die("openat2"); close(ofd); if(syscall(SYS_faccessat2,AT_FDCWD,"/tmp/gap-openat2",R_OK,0)<0) die("faccessat2");
 sigset_t mask; sigemptyset(&mask); sigaddset(&mask,SIGUSR1); if(sigprocmask(SIG_BLOCK,&mask,NULL)<0) die("sigprocmask"); int sfd=signalfd(-1,&mask,SFD_CLOEXEC|SFD_NONBLOCK); if(sfd<0) die("signalfd"); kill(getpid(),SIGUSR1); struct signalfd_siginfo si; ssize_t sr; for(int i=0;i<100;i++){ sr=read(sfd,&si,sizeof(si)); if(sr==sizeof(si)) break; usleep(1000);} if(sr!=sizeof(si)||si.ssi_signo!=SIGUSR1) die("read signalfd"); close(sfd);
 int sem=semget(IPC_PRIVATE,1,IPC_CREAT|0600); if(sem<0) die("semget"); union semun u; u.val=1; if(semctl(sem,0,SETVAL,u)<0) die("semctl set"); struct sembuf ops[1]={{0,-1,0}}; if(semop(sem,ops,1)<0) die("semop -1"); if(semctl(sem,0,GETVAL,u)!=0) die("semctl get"); semctl(sem,0,IPC_RMID,u);
 struct mq_attr attr={.mq_maxmsg=4,.mq_msgsize=32}; mqd_t mq=mq_open("/gapmq",O_CREAT|O_RDWR|O_NONBLOCK,0600,&attr); if(mq==(mqd_t)-1) die("mq_open"); if(mq_send(mq,"hello",6,7)<0) die("mq_send"); unsigned pr=0; char mbuf[32]; ssize_t mr=mq_receive(mq,mbuf,sizeof(mbuf),&pr); if(mr!=6||strcmp(mbuf,"hello")||pr!=7) die("mq_receive"); mq_close(mq); mq_unlink("/gapmq");
 int us=socket(AF_INET,SOCK_DGRAM|SOCK_CLOEXEC,0); if(us<0) die("socket udp"); int one=1; if(setsockopt(us,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one))<0) die("setsockopt reuseaddr"); int stype=0; socklen_t stype_len=sizeof(stype); if(getsockopt(us,SOL_SOCKET,SO_TYPE,&stype,&stype_len)<0||stype!=SOCK_DGRAM||stype_len!=sizeof(stype)) die("getsockopt type"); struct sockaddr_in a={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK),.sin_port=0}; if(bind(us,(struct sockaddr*)&a,sizeof(a))<0) die("bind udp"); socklen_t alen=sizeof(a); if(getsockname(us,(struct sockaddr*)&a,&alen)<0) die("getsockname udp"); if(sendto(us,"pong",4,0,(struct sockaddr*)&a,alen)!=4) die("sendto udp"); char rb[16]="XXXXXXXXXXXXXXX"; struct sockaddr_in src; socklen_t slen=sizeof(src); ssize_t rr=recvfrom(us,rb,sizeof(rb),0,(struct sockaddr*)&src,&slen); if(rr!=4||memcmp(rb,"pong",4)||rb[4]!='X'||slen>sizeof(src)) die("recvfrom udp"); close(us);
 char local[16]="self"; char out[16]={0}; struct iovec li={out,5}, ri={local,5}; ssize_t vr=syscall(SYS_process_vm_readv,getpid(),&li,1,&ri,1,0); if(vr!=5||strcmp(out,"self")) die("process_vm_readv"); char in[16]="that"; struct iovec liw={in,5}, riw={local,5}; ssize_t vw=syscall(SYS_process_vm_writev,getpid(),&liw,1,&riw,1,0); if(vw!=5||strcmp(local,"that")) die("process_vm_writev");
 puts("syscall-gaps-ok"); return 0;
}
EOF
    cat >"$dir/dczva.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    uint64_t dczid = 0;
    __asm__ volatile("mrs %0, dczid_el0" : "=r"(dczid));
    if (dczid != 4) {
        fprintf(stderr, "unexpected dczid=%llu\n", (unsigned long long)dczid);
        return 1;
    }

    unsigned char *p = NULL;
    if (posix_memalign((void **)&p, 64, 128) != 0)
        return 1;
    memset(p, 0xaa, 128);
    __asm__ volatile("dc zva, %0" :: "r"(p + 17) : "memory");

    for (int i = 0; i < 64; i++)
        if (p[i] != 0)
            return 1;
    for (int i = 64; i < 128; i++)
        if (p[i] != 0xaa)
            return 1;

    puts("dczva-ok");
    free(p);
    return 0;
}
EOF
    cat >"$dir/ccmp_nv.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

static unsigned flags_after_ccmp_nv(uint64_t a, uint64_t b) {
    uint64_t flags;
    __asm__ volatile(
        "cmp %1, %2\n"
        "ccmp %1, %2, #0, nv\n"
        "mrs %0, nzcv\n"
        : "=r"(flags) : "r"(a), "r"(b) : "cc");
    return (unsigned)(flags >> 28) & 0xf;
}

static unsigned flags_after_ccmn_nv(uint64_t a, uint64_t b) {
    uint64_t flags;
    __asm__ volatile(
        "cmp %1, %2\n"
        "ccmn %1, %2, #0, nv\n"
        "mrs %0, nzcv\n"
        : "=r"(flags) : "r"(a), "r"(b) : "cc");
    return (unsigned)(flags >> 28) & 0xf;
}

static unsigned flags_after_ccmp_ne_false(uint64_t a, uint64_t b) {
    uint64_t flags;
    __asm__ volatile(
        "cmp %1, %1\n"
        "ccmp %1, %2, #5, ne\n"
        "mrs %0, nzcv\n"
        : "=r"(flags) : "r"(a), "r"(b) : "cc");
    return (unsigned)(flags >> 28) & 0xf;
}

static unsigned flags_sub(uint64_t a, uint64_t b) {
    uint64_t flags;
    __asm__ volatile("cmp %1, %2\n mrs %0, nzcv" : "=r"(flags) : "r"(a), "r"(b) : "cc");
    return (unsigned)(flags >> 28) & 0xf;
}

static unsigned flags_add(uint64_t a, uint64_t b) {
    uint64_t flags;
    __asm__ volatile("cmn %1, %2\n mrs %0, nzcv" : "=r"(flags) : "r"(a), "r"(b) : "cc");
    return (unsigned)(flags >> 28) & 0xf;
}

int main(void) {
    int fail = 0;
    uint64_t pairs[][2] = {{0,0}, {1,2}, {2,1}, {0xffffffffffffffffULL,1}, {0x8000000000000000ULL,0}};
    for (unsigned i = 0; i < sizeof(pairs)/sizeof(pairs[0]); i++) {
        uint64_t a = pairs[i][0], b = pairs[i][1];
        unsigned got = flags_after_ccmp_nv(a, b), exp = flags_sub(a, b);
        if (got != exp) { printf("ccmp-nv fail %llx %llx got %x exp %x\n", (unsigned long long)a, (unsigned long long)b, got, exp); fail++; }
        got = flags_after_ccmn_nv(a, b); exp = flags_add(a, b);
        if (got != exp) { printf("ccmn-nv fail %llx %llx got %x exp %x\n", (unsigned long long)a, (unsigned long long)b, got, exp); fail++; }
    }
    if (flags_after_ccmp_ne_false(1, 2) != 5) { printf("ccmp false nzcv fail got %x\n", flags_after_ccmp_ne_false(1, 2)); fail++; }
    if (fail) return 1;
    puts("ccmp-nv-ok");
    return 0;
}
EOF

    cat >"$dir/barriers.c" <<'EOF'
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>

static volatile uint64_t sink;

int main(void) {
    sink = 1;
    __asm__ volatile("dmb sy" ::: "memory");
    sink = 2;
    __asm__ volatile("dmb ish" ::: "memory");
    sink = 3;
    __asm__ volatile("dmb ishld" ::: "memory");
    sink = 4;
    __asm__ volatile("dmb ishst" ::: "memory");
    sink = 5;
    __asm__ volatile("dsb sy" ::: "memory");
    sink = 6;
    __asm__ volatile("dsb ish" ::: "memory");
    sink = 7;
    __asm__ volatile("isb" ::: "memory");
    atomic_thread_fence(memory_order_seq_cst);
    if (sink != 7) {
        fprintf(stderr, "bad sink=%llu\n", (unsigned long long)sink);
        return 1;
    }
    puts("barriers-ok");
    return 0;
}
EOF

    cat >"$dir/smc.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    unsigned char *p = mmap(NULL, 4096, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return 1;
    uint32_t code[] = {0x52800020, 0xd65f03c0}; // mov w0,#1; ret
    memcpy(p, code, sizeof(code));
    __builtin___clear_cache((char*)p, (char*)p + sizeof(code));
    int (*fn)(void) = (int(*)(void))p;
    int a = fn();
    ((uint32_t*)p)[0] = 0x52800040; // mov w0,#2
    __builtin___clear_cache((char*)p, (char*)p + sizeof(code));
    int b = fn();
    printf("smc %d %d\n", a, b);
    return (a == 1 && b == 2) ? 0 : 2;
}
EOF

    cat >"$dir/signal_ucontext.c" <<'EOF'
#define _GNU_SOURCE
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <ucontext.h>

static sigjmp_buf jb;
static volatile uintptr_t trigger_addr;
static volatile uintptr_t observed_pc;
static volatile uintptr_t observed_sp;
static volatile uintptr_t observed_lr;
static volatile uintptr_t observed_fault;

__attribute__((noinline)) static void trigger_segv(void) {
    trigger_addr = (uintptr_t)&trigger_segv;
    volatile int *p = (volatile int *)0;
    (void)*p;
}

static void handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    ucontext_t *uc = (ucontext_t *)uctx;
    observed_pc = (uintptr_t)uc->uc_mcontext.pc;
    observed_sp = (uintptr_t)uc->uc_mcontext.sp;
    observed_lr = (uintptr_t)uc->uc_mcontext.regs[30];
    observed_fault = (uintptr_t)si->si_addr;
    siglongjmp(jb, 1);
}

int main(void) {
    if (offsetof(ucontext_t, uc_mcontext) != 176) {
        fprintf(stderr, "bad mcontext offset: %zu\n", offsetof(ucontext_t, uc_mcontext));
        return 1;
    }

    struct sigaction sa = {0};
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) != 0)
        return 1;

    if (sigsetjmp(jb, 1) == 0) {
        trigger_segv();
        return 1;
    }

    if (observed_fault != 0)
        return 1;
    if (observed_pc < trigger_addr || observed_pc >= trigger_addr + 256) {
        fprintf(stderr, "bad pc: trigger=%#lx pc=%#lx sp=%#lx lr=%#lx\n",
                (unsigned long)trigger_addr, (unsigned long)observed_pc,
                (unsigned long)observed_sp, (unsigned long)observed_lr);
        return 1;
    }
    if (observed_sp == 0 || observed_lr == 0 || observed_lr == observed_sp)
        return 1;

    puts("signal-ucontext-ok");
    return 0;
}
EOF


    cp "$PROJECT_DIR/tests/arm64/signals/sigaltstack-thread.c" "$dir/sigaltstack_thread.c"
    push_tree "$dir" "$GUEST_WORK/c"
}

prepare_go_fixture() {
    local dir="$HOST_TMP/go"
    mkdir -p "$dir"
    cat >"$dir/go.mod" <<'EOF'
module example.com/runtimecoverage

go 1.22
EOF
    cat >"$dir/main.go" <<'EOF'
package main

import (
    "encoding/json"
    "fmt"
    "os"
)

func main() {
    payload := map[string]any{"runtime": "go", "ok": true}
    _ = json.NewEncoder(os.Stdout).Encode(payload)
    fmt.Println("go-runtime-ok")
}
EOF
    mkdir -p "$dir/compileonly"
    cat >"$dir/compileonly/compile_only.go" <<'EOF'
package compileonly

func Add(a, b int) int {
    return a + b
}
EOF
    cat >"$dir/main_test.go" <<'EOF'
package main

import "testing"

func TestMath(t *testing.T) {
    if 2+2 != 4 {
        t.Fatal("bad math")
    }
}
EOF
    push_tree "$dir" "$GUEST_WORK/go"
}

prepare_bun_fixture() {
    local dir="$HOST_TMP/bun"
    mkdir -p "$dir/localdep"
    cat >"$dir/package.json" <<'EOF'
{
  "name": "bun-runtime-coverage",
  "private": true,
  "type": "module",
  "dependencies": {
    "localdep": "file:./localdep"
  }
}
EOF
    cat >"$dir/localdep/package.json" <<'EOF'
{
  "name": "localdep",
  "version": "1.0.0",
  "type": "module",
  "exports": "./index.js"
}
EOF
    cat >"$dir/localdep/index.js" <<'EOF'
export const marker = "bun-localdep-ok";
EOF
    cat >"$dir/index.ts" <<'EOF'
import { writeFileSync, readFileSync } from "node:fs";
import { marker } from "localdep";

writeFileSync("/tmp/runtime-coverage/bun/output.txt", marker + "\n");
process.stdout.write(readFileSync("/tmp/runtime-coverage/bun/output.txt", "utf8"));
EOF
    cat >"$dir/sum.test.ts" <<'EOF'
import { expect, test } from "bun:test";
import { marker } from "localdep";

test("bun runtime coverage", () => {
  expect(marker).toBe("bun-localdep-ok");
  expect(1 + 1).toBe(2);
});
EOF
    push_tree "$dir" "$GUEST_WORK/bun"
}

prepare_node_fixture() {
    local dir="$HOST_TMP/node"
    mkdir -p "$dir"
    cat >"$dir/package.json" <<'EOF'
{
  "name": "node-runtime-coverage",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node index.mjs"
  }
}
EOF
    cat >"$dir/index.mjs" <<'EOF'
import { writeFileSync, readFileSync } from "node:fs";

writeFileSync("/tmp/runtime-coverage/node/output.txt", "node-runtime-ok\n");
process.stdout.write(readFileSync("/tmp/runtime-coverage/node/output.txt", "utf8"));
EOF
    push_tree "$dir" "$GUEST_WORK/node"
}

prepare_rust_fixture() {
    local dir="$HOST_TMP/rust"
    mkdir -p "$dir/src" "$dir/tests"
    cat >"$dir/Cargo.toml" <<'EOF'
[package]
name = "runtime_coverage"
version = "0.1.0"
edition = "2021"

[profile.dev]
debug = 0

[profile.release]
debug = 0
EOF
    cat >"$dir/src/lib.rs" <<'EOF'
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;

pub fn checksum(input: &[u8]) -> u64 {
    input.iter().fold(0u64, |acc, b| acc.wrapping_mul(131).wrapping_add(*b as u64))
}

pub fn threaded_sum() -> u64 {
    let acc = Arc::new(AtomicU64::new(0));
    let seen = Arc::new(Mutex::new(Vec::new()));
    let mut handles = Vec::new();
    for worker in 0..4u64 {
        let acc = Arc::clone(&acc);
        let seen = Arc::clone(&seen);
        handles.push(thread::spawn(move || {
            let start = worker * 250 + 1;
            let end = start + 249;
            let subtotal: u64 = (start..=end).sum();
            acc.fetch_add(subtotal, Ordering::SeqCst);
            seen.lock().unwrap().push(worker);
        }));
    }
    for handle in handles {
        handle.join().unwrap();
    }
    let mut workers = seen.lock().unwrap().clone();
    workers.sort_unstable();
    assert_eq!(workers, vec![0, 1, 2, 3]);
    acc.load(Ordering::SeqCst)
}

pub fn channel_roundtrip() -> String {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || tx.send("rust-channel-ok".to_string()).unwrap()).join().unwrap();
    rx.recv().unwrap()
}

pub fn file_roundtrip(path: &Path) -> std::io::Result<String> {
    fs::write(path, b"rust-file-ok\n")?;
    let text = fs::read_to_string(path)?;
    let meta = fs::metadata(path)?;
    assert_eq!(meta.len(), text.len() as u64);
    Ok(text.trim().to_string())
}

pub fn tcp_loopback() -> std::io::Result<String> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let addr = listener.local_addr()?;
    let server = thread::spawn(move || -> std::io::Result<()> {
        let (mut stream, _) = listener.accept()?;
        let mut buf = [0u8; 4];
        stream.read_exact(&mut buf)?;
        assert_eq!(&buf, b"ping");
        stream.write_all(b"pong")?;
        Ok(())
    });
    let mut client = TcpStream::connect(addr)?;
    client.write_all(b"ping")?;
    let mut reply = [0u8; 4];
    client.read_exact(&mut reply)?;
    server.join().unwrap()?;
    Ok(String::from_utf8(reply.to_vec()).unwrap())
}

pub fn child_process() -> std::io::Result<String> {
    let output = Command::new("/bin/sh").arg("-c").arg("printf rust-child-ok").output()?;
    assert!(output.status.success());
    Ok(String::from_utf8(output.stdout).unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn checksum_is_stable() {
        assert_eq!(checksum(b"rust-runtime"), 9534429477999140727);
        assert_eq!(checksum(b"abc"), 1677554);
    }

    #[test]
    fn std_thread_channel_and_process_work() {
        assert_eq!(threaded_sum(), 500500);
        assert_eq!(channel_roundtrip(), "rust-channel-ok");
        assert_eq!(child_process().unwrap(), "rust-child-ok");
    }

    #[test]
    fn std_file_and_tcp_work() {
        let path = PathBuf::from("/tmp/runtime-coverage/rust/file-roundtrip.txt");
        assert_eq!(file_roundtrip(&path).unwrap(), "rust-file-ok");
        assert_eq!(tcp_loopback().unwrap(), "pong");
    }
}
EOF
    cat >"$dir/src/main.rs" <<'EOF'
use std::path::Path;

fn main() -> std::io::Result<()> {
    let value = runtime_coverage::checksum(b"rust-runtime");
    let threaded = runtime_coverage::threaded_sum();
    let channel = runtime_coverage::channel_roundtrip();
    let file = runtime_coverage::file_roundtrip(Path::new("/tmp/runtime-coverage/rust/main-file.txt"))?;
    let tcp = runtime_coverage::tcp_loopback()?;
    let child = runtime_coverage::child_process()?;
    println!("rust-runtime-ok {value} {threaded} {channel} {file} {tcp} {child}");
    Ok(())
}
EOF
    cat >"$dir/hello.rs" <<'EOF'
use std::collections::BTreeMap;

fn main() {
    let sum: u64 = (1..=100).sum();
    let mut map = BTreeMap::new();
    map.insert("sum", sum);
    map.insert("double", sum * 2);
    println!("rustc-runtime-ok {} {}", map["sum"], map["double"]);
}
EOF
    cat >"$dir/std_runtime.rs" <<'EOF'
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;

fn main() -> std::io::Result<()> {
    let total = Arc::new(AtomicUsize::new(0));
    let mut handles = Vec::new();
    for i in 0..8usize {
        let total = Arc::clone(&total);
        handles.push(thread::spawn(move || total.fetch_add(i * i, Ordering::SeqCst)));
    }
    for h in handles { h.join().unwrap(); }
    fs::write("/tmp/runtime-coverage/rust/std-runtime.txt", b"rust-std-file-ok")?;
    let file_text = fs::read_to_string("/tmp/runtime-coverage/rust/std-runtime.txt")?;
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let addr = listener.local_addr()?;
    let server = thread::spawn(move || -> std::io::Result<()> {
        let (mut s, _) = listener.accept()?;
        let mut b = [0; 3];
        s.read_exact(&mut b)?;
        s.write_all(b"ack")
    });
    let mut client = TcpStream::connect(addr)?;
    client.write_all(b"hey")?;
    let mut reply = [0; 3];
    client.read_exact(&mut reply)?;
    server.join().unwrap()?;
    let child = Command::new("/bin/sh").arg("-c").arg("printf child").output()?;
    assert_eq!(total.load(Ordering::SeqCst), 140);
    assert_eq!(file_text, "rust-std-file-ok");
    assert_eq!(&reply, b"ack");
    assert_eq!(String::from_utf8(child.stdout).unwrap(), "child");
    println!("rust-std-ok");
    Ok(())
}
EOF
    cat >"$dir/tests/smoke.rs" <<'EOF'
#[test]
fn integration_smoke() {
    assert_eq!(runtime_coverage::checksum(b"abc"), 1677554);
    assert_eq!(runtime_coverage::threaded_sum(), 500500);
}
EOF
    push_tree "$dir" "$GUEST_WORK/rust"
}

prepare_erlang_fixture() {
    local dir="$HOST_TMP/erlang"
    mkdir -p "$dir"
    cat >"$dir/runtime_coverage.erl" <<'EOF'
-module(runtime_coverage).
-export([main/0, checksum/1]).

checksum(Bin) when is_binary(Bin) ->
    lists:foldl(fun(B, Acc) -> ((Acc * 131) + B) band 16#ffffffffffffffff end, 0, binary_to_list(Bin)).

main() ->
    case checksum(<<"erlang-runtime">>) of
        11736296863384415574 ->
            io:format("erlang-runtime-ok~n"),
            halt(0);
        Other ->
            io:format("bad-checksum ~p~n", [Other]),
            halt(1)
    end.
EOF
    push_tree "$dir" "$GUEST_WORK/erlang"
}

prepare_zig_fixture() {
    local dir="$HOST_TMP/zig"
    mkdir -p "$dir"
    cat >"$dir/main.zig" <<'EOF'
fn checksum(bytes: []const u8) u64 {
    var acc: u64 = 0;
    for (bytes) |b| {
        acc = acc *% 131 +% b;
    }
    return acc;
}

export fn zig_runtime_checksum() u64 {
    return checksum("zig-runtime");
}
EOF
    cat >"$dir/harness.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

uint64_t zig_runtime_checksum(void);

int main(void) {
    uint64_t got = zig_runtime_checksum();
    if (got != 13593902126957356019ULL) {
        printf("zig-runtime-bad %llu\n", (unsigned long long)got);
        return 1;
    }
    printf("zig-runtime-ok %llu\n", (unsigned long long)got);
    return 0;
}
EOF
    push_tree "$dir" "$GUEST_WORK/zig"
}

write_report() {
    cat >"$REPORT" <<EOF
# iSH ARM64 Runtime Coverage Report

- Timestamp: $(date -Is)
- ish binary: $ISH_BIN
- rootfs: $ROOTFS
- timeout: ${TIMEOUT_S}s
- install timeout: ${INSTALL_TIMEOUT_S}s

## Summary

- Total: $TOTAL_COUNT
- Passed: $PASS_COUNT
- Failed: $FAIL_COUNT

## Results

| Stage | Test | Status | Detail |
|---|---|---|---|
$REPORT_ROWS
EOF
}

main() {
    [ -x "$ISH_BIN" ] || { echo "missing ish binary: $ISH_BIN" >&2; exit 1; }
    [ -d "$ROOTFS" ] || { echo "missing rootfs: $ROOTFS" >&2; exit 1; }

    ensure_guest_basics

    run_test base "shell" "echo shell-ok | grep -qx shell-ok"
    run_test base "apk" "apk --version >/dev/null 2>&1"
    run_test base "tmp file io" "echo file-ok > '$GUEST_WORK/base.txt' && grep -qx file-ok '$GUEST_WORK/base.txt'"
    run_test base "symlink retarget normalization" "mkdir -p '$GUEST_WORK/path-cache' && cd '$GUEST_WORK/path-cache' && echo old > old.txt && echo new > new.txt && ln -sf old.txt current && grep -qx old current && ln -sf new.txt current && grep -qx new current"

    ensure_tools build-base:gcc
    prepare_c_fixture
    run_test c "gcc version" "gcc --version | head -1"
    run_test c "compile + run" "cd '$GUEST_WORK/c' && gcc -O0 hello.c -o hello && ./hello | grep -q '^c-runtime-ok '"
    run_test c "sysv shm/msg IPC" "cd '$GUEST_WORK/c' && gcc -O0 sysv_ipc.c -o sysv_ipc && ./sysv_ipc | grep -qx sysv-ipc-ok"
    run_test c "high-value syscall gaps" "cd '$GUEST_WORK/c' && gcc -O0 syscall_gaps.c -o syscall_gaps -lrt && ./syscall_gaps | grep -qx syscall-gaps-ok"
    run_test c "arm64 DC ZVA sysreg/instruction" "cd '$GUEST_WORK/c' && gcc -O0 dczva.c -o dczva && ./dczva | grep -qx dczva-ok"
    run_test c "arm64 signal ucontext layout" "cd '$GUEST_WORK/c' && gcc -O0 signal_ucontext.c -o signal_ucontext && ./signal_ucontext | grep -qx signal-ucontext-ok"
    run_test c "per-thread sigaltstack" "cd '$GUEST_WORK/c' && gcc -O0 sigaltstack_thread.c -o sigaltstack_thread -pthread && ./sigaltstack_thread | grep -qx sigaltstack-thread-ok"
    run_test c "arm64 CCMP/CCMN NV condition" "cd '$GUEST_WORK/c' && gcc -O0 ccmp_nv.c -o ccmp_nv && ./ccmp_nv | grep -qx ccmp-nv-ok"
    run_test c "arm64 barriers DMB/DSB/ISB" "cd '$GUEST_WORK/c' && gcc -O0 barriers.c -o barriers && ./barriers | grep -qx barriers-ok"
    run_test c "arm64 self-modifying code invalidation" "cd '$GUEST_WORK/c' && gcc -O0 smc.c -o smc && ./smc | grep -qx 'smc 1 2'"

    ensure_tools go
    prepare_go_fixture
    run_test go "version" "go version"
    run_test go "env" "go env GOARCH GOOS GOROOT"
    run_test go "go tool compile" "cd '$GUEST_WORK/go/compileonly' && go tool compile -o compile_only.o compile_only.go"
    run_test go "go run" "cd '$GUEST_WORK/go' && go run . | tail -1 | grep -qx go-runtime-ok"
    run_test go "go build + execute" "cd '$GUEST_WORK/go' && go build -o app . && ./app | tail -1 | grep -qx go-runtime-ok"
    run_test go "go test" "cd '$GUEST_WORK/go' && go test ./..."

    run_test bun "version" "bun --version"
    prepare_bun_fixture
    run_test bun "install local dep" "cd '$GUEST_WORK/bun' && bun install"
    run_test bun "run typescript" "cd '$GUEST_WORK/bun' && bun run index.ts | grep -qx bun-localdep-ok"
    run_test bun "bun test" "cd '$GUEST_WORK/bun' && bun test"
    run_test bun "bun build" "cd '$GUEST_WORK/bun' && bun build ./index.ts --outfile ./dist/index.js >/dev/null && test -s ./dist/index.js"

    ensure_tools nodejs:node npm
    prepare_node_fixture
    run_test node "node version" "node --version"
    run_test node "node eval" "node -e 'console.log(1+1)' | grep -qx 2"
    run_test node "npm version" "npm --version"
    run_test node "node run" "cd '$GUEST_WORK/node' && npm run --silent start | grep -qx node-runtime-ok"

    ensure_tools python3 lua5.4 openjdk21-jdk:javac clojure
    run_test python "python3 version" "python3 --version"
    run_test python "python3 eval" "python3 -c 'print(\"python-runtime-ok\", sum(range(10)))' | grep -qx 'python-runtime-ok 45'"
    run_test lua "lua5.4 version" "lua5.4 -v"
    run_test lua "lua5.4 eval" "lua5.4 -e 'print(\"lua-runtime-ok\", 2+3)' | grep -q '^lua-runtime-ok[[:space:]]*5$'"
    run_test java "javac + java" "cd '$GUEST_WORK' && printf '%s\n' 'public class Hello { public static void main(String[] args) { System.out.println(\"java-runtime-ok\"); } }' > Hello.java && javac Hello.java && java -cp . Hello | grep -qx java-runtime-ok"
    run_test java "java interpreter fallback" "cd '$GUEST_WORK' && java -Xint -cp . Hello | grep -qx java-runtime-ok"
    run_test clojure "clojure.main eval" "java -cp /usr/share/clojure/clojure.jar clojure.main -e '(println \"clojure-runtime-ok\" (+ 1 2 3))' | grep -qx 'clojure-runtime-ok 6'"
    run_test pypy "availability probe" "if command -v pypy3 >/dev/null 2>&1; then pypy3 -c 'print(\"pypy-runtime-ok\")' | grep -qx pypy-runtime-ok; else ! apk search pypy | grep -E '(^|-)pypy3?(-|$)' && echo pypy-unavailable-alpine-aarch64; fi"
    run_test swift "availability probe" "if command -v swift >/dev/null 2>&1; then swift --version; elif command -v swiftc >/dev/null 2>&1; then swiftc --version; else ! apk search swift | grep -E '(^|-)swift(c)?(-|$)' && echo swift-unavailable-alpine-aarch64; fi"

    ensure_tools rust:rustc cargo
    prepare_rust_fixture
    run_test rust "rustc version" "rustc --version"
    run_test rust "rustc compile + run" "cd '$GUEST_WORK/rust' && rustc hello.rs -o rustc_app && ./rustc_app | grep -qx 'rustc-runtime-ok 5050 10100'"
    run_test rust "rustc optimized std runtime" "cd '$GUEST_WORK/rust' && rustc -O std_runtime.rs -o rust_std && ./rust_std | grep -qx rust-std-ok"
    run_test rust "rustc unit tests" "cd '$GUEST_WORK/rust' && rustc --test src/lib.rs -o lib_tests && RUST_TEST_THREADS=1 ./lib_tests --quiet"
    run_test rust "cargo build" "cd '$GUEST_WORK/rust' && cargo build --quiet"
    run_test rust "cargo run" "cd '$GUEST_WORK/rust' && cargo run --quiet | grep -q '^rust-runtime-ok 9534429477999140727 500500 rust-channel-ok rust-file-ok pong rust-child-ok$'"
    run_test rust "cargo test" "cd '$GUEST_WORK/rust' && RUST_TEST_THREADS=1 cargo test --quiet --jobs 1"

    ensure_tools erlang:erl
    prepare_erlang_fixture
    run_test erlang "erl version" "erl -version 2>&1 | grep -q 'BEAM.*emulator version'"

    ensure_tools zig
    prepare_zig_fixture
    run_test zig "zig version" "zig version"
    run_test zig "zig build-obj" "cd '$GUEST_WORK/zig' && zig build-obj main.zig -O Debug -femit-bin=zig_runtime.o && test -s zig_runtime.o"
    run_test zig "zig object link + run" "cd '$GUEST_WORK/zig' && zig build-obj main.zig -O Debug -femit-bin=zig_runtime.o && gcc harness.c zig_runtime.o -o zig_app && ./zig_app | grep -q '^zig-runtime-ok '"

    write_report
    echo "report: $REPORT"

    if ((FAIL_COUNT > 0)); then
        exit 1
    fi
}

main "$@"
