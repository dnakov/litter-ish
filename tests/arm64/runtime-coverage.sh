#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ISH_BIN="${ISH_BIN:-$PROJECT_DIR/build-arm64-linux/ish}"
ROOTFS="${ROOTFS:-$PROJECT_DIR/alpine-arm64-fakefs}"
ROOTFS_LANES="${ROOTFS_LANES:-default=$ROOTFS}"
LANE_NAME="${LANE_NAME:-default}"
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
    REPORT_ROWS+="| $LANE_NAME | $stage | $name | $status | ${detail//$'\n'/<br>} |"$'\n'
}

run_test() {
    local stage="$1"
    local name="$2"
    local cmd="$3"
    local out="$HOST_TMP/test.out"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf '[%s/%s] %s ... ' "$LANE_NAME" "$stage" "$name"
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
    log "[$LANE_NAME] Ensuring fakefs DNS/package-manager basics"
    local out="$HOST_TMP/install.out"
    guest_capture_install "test -f /etc/resolv.conf || echo 'nameserver 1.1.1.1' > /etc/resolv.conf; if [ -f /etc/apk/repositories ]; then sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null || true; fi; mkdir -p '$GUEST_WORK'" >"$out" 2>&1
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
    local platform
    platform="$(detect_platform)"
    local missing=()
    local spec pkg_spec pkg cmd
    for spec in "$@"; do
        pkg_spec="${spec%%:*}"
        cmd="${spec#*:}"
        [ "$cmd" = "$spec" ] && cmd="$(package_for_platform "$pkg_spec" "$platform")"
        local out="$HOST_TMP/ensure-tool.out"
        guest_capture "command -v $cmd >/dev/null 2>&1" >"$out" 2>&1 || true
        if ! grep -q '^__ISH_STATUS:0$' "$out"; then
            pkg="$(package_for_platform "$pkg_spec" "$platform")"
            missing+=("$pkg")
        fi
    done
    if ((${#missing[@]} > 0)); then
        install_guest_packages "${missing[@]}"
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
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/sem.h>
#include <sys/signalfd.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>
#include <linux/openat2.h>
#ifndef SYS_fchmodat2
#define SYS_fchmodat2 452
#endif
#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif

union semun { int val; struct semid_ds *buf; unsigned short *array; };
static void die(const char *s){perror(s); exit(1);}
int main(){
 int fd=syscall(SYS_memfd_create,"gap",MFD_CLOEXEC); if(fd<0) die("memfd_create"); write(fd,"abc",3); char b[8]={0}; struct iovec iov={b,3}; if(syscall(SYS_preadv2,fd,&iov,1,0,0)!=3) die("preadv2"); if(strcmp(b,"abc")) return 2; struct iovec wiov={(char*)"Z",1}; if(syscall(SYS_pwritev2,fd,&wiov,1,1,0)!=1) die("pwritev2"); memset(b,0,8); pread(fd,b,3,0); if(strcmp(b,"aZc")) return 3;
 struct open_how how={.flags=O_RDONLY}; int ofd=syscall(SYS_openat2,AT_FDCWD,"/tmp/gap-openat2",&how,sizeof(how)); if(ofd>=0) close(ofd); int cfd=open("/tmp/gap-openat2",O_CREAT|O_RDWR,0600); if(cfd<0) die("create"); close(cfd); ofd=syscall(SYS_openat2,AT_FDCWD,"/tmp/gap-openat2",&how,sizeof(how)); if(ofd<0) die("openat2"); close(ofd); if(syscall(SYS_faccessat2,AT_FDCWD,"/tmp/gap-openat2",R_OK,0)<0) die("faccessat2"); cfd=open("/tmp/gap-openat2",O_RDWR); if(cfd<0) die("open fchmodat2"); if(syscall(SYS_fchmodat2,cfd,"",0644,AT_EMPTY_PATH)<0) die("fchmodat2 empty"); struct stat fst; if(stat("/tmp/gap-openat2",&fst)<0||(fst.st_mode&0777)!=0644) die("fchmodat2 mode"); close(cfd); mkdir("/tmp/gap-fchmodat2-dir",0755); if(chdir("/tmp/gap-fchmodat2-dir")<0) die("chdir fchmodat2"); if(syscall(SYS_fchmodat2,AT_FDCWD,"",0750,AT_EMPTY_PATH)<0) die("fchmodat2 cwd"); if(stat(".",&fst)<0||(fst.st_mode&0777)!=0750) die("fchmodat2 cwd mode"); chmod(".",0755); if(chdir("/")<0) die("chdir root");
 sigset_t mask; sigemptyset(&mask); sigaddset(&mask,SIGUSR1); if(sigprocmask(SIG_BLOCK,&mask,NULL)<0) die("sigprocmask"); int sfd=signalfd(-1,&mask,SFD_CLOEXEC|SFD_NONBLOCK); if(sfd<0) die("signalfd"); kill(getpid(),SIGUSR1); struct signalfd_siginfo si; ssize_t sr; for(int i=0;i<100;i++){ sr=read(sfd,&si,sizeof(si)); if(sr==sizeof(si)) break; usleep(1000);} if(sr!=sizeof(si)||si.ssi_signo!=SIGUSR1) die("read signalfd"); close(sfd);
 int sem=semget(IPC_PRIVATE,1,IPC_CREAT|0600); if(sem<0) die("semget"); union semun u; u.val=1; if(semctl(sem,0,SETVAL,u)<0) die("semctl set"); struct sembuf ops[1]={{0,-1,0}}; if(semop(sem,ops,1)<0) die("semop -1"); if(semctl(sem,0,GETVAL,u)!=0) die("semctl get"); semctl(sem,0,IPC_RMID,u);
 struct mq_attr attr={.mq_maxmsg=4,.mq_msgsize=32}; mqd_t mq=mq_open("/gapmq",O_CREAT|O_RDWR|O_NONBLOCK,0600,&attr); if(mq==(mqd_t)-1) die("mq_open"); if(mq_send(mq,"hello",6,7)<0) die("mq_send"); unsigned pr=0; char mbuf[32]; ssize_t mr=mq_receive(mq,mbuf,sizeof(mbuf),&pr); if(mr!=6||strcmp(mbuf,"hello")||pr!=7) die("mq_receive"); mq_close(mq); mq_unlink("/gapmq");
 int us=socket(AF_INET,SOCK_DGRAM|SOCK_CLOEXEC,0); if(us<0) die("socket udp"); int one=1; if(setsockopt(us,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one))<0) die("setsockopt reuseaddr"); int stype=0; socklen_t stype_len=sizeof(stype); if(getsockopt(us,SOL_SOCKET,SO_TYPE,&stype,&stype_len)<0||stype!=SOCK_DGRAM||stype_len!=sizeof(stype)) die("getsockopt type"); struct sockaddr_in a={.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK),.sin_port=0}; if(bind(us,(struct sockaddr*)&a,sizeof(a))<0) die("bind udp"); socklen_t alen=sizeof(a); if(getsockname(us,(struct sockaddr*)&a,&alen)<0) die("getsockname udp"); if(sendto(us,"pong",4,0,(struct sockaddr*)&a,alen)!=4) die("sendto udp"); char rb[16]="XXXXXXXXXXXXXXX"; struct sockaddr_in src; socklen_t slen=sizeof(src); ssize_t rr=recvfrom(us,rb,sizeof(rb),0,(struct sockaddr*)&src,&slen); if(rr!=4||memcmp(rb,"pong",4)||rb[4]!='X'||slen>sizeof(src)) die("recvfrom udp"); close(us);
 int ls=socket(AF_INET,SOCK_STREAM|SOCK_CLOEXEC,0); if(ls<0) die("socket tcp"); if(setsockopt(ls,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one))<0) die("setsockopt tcp"); memset(&a,0,sizeof(a)); a.sin_family=AF_INET; a.sin_addr.s_addr=htonl(INADDR_LOOPBACK); if(bind(ls,(struct sockaddr*)&a,sizeof(a))<0) die("bind tcp"); alen=sizeof(a); if(getsockname(ls,(struct sockaddr*)&a,&alen)<0||alen>sizeof(a)) die("getsockname tcp"); if(listen(ls,1)<0) die("listen tcp"); pid_t cp=fork(); if(cp<0) die("fork tcp"); if(cp==0){ int cs=socket(AF_INET,SOCK_STREAM|SOCK_CLOEXEC,0); if(cs<0) _exit(21); if(connect(cs,(struct sockaddr*)&a,alen)<0) _exit(22); if(write(cs,"hi",2)!=2) _exit(23); close(cs); _exit(0); } struct sockaddr_in peer; socklen_t plen=sizeof(peer); int as=accept(ls,(struct sockaddr*)&peer,&plen); if(as<0||plen>sizeof(peer)) die("accept tcp"); char tb[4]={0}; if(read(as,tb,2)!=2||memcmp(tb,"hi",2)) die("read tcp"); close(as); close(ls); int wst=0; if(waitpid(cp,&wst,0)<0||!WIFEXITED(wst)||WEXITSTATUS(wst)!=0) die("wait tcp");
 int sp[2]; if(socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,sp)<0) die("socketpair"); struct iovec siov[2]={{(char*)"ab",2},{(char*)"cd",2}}; struct msghdr sm={.msg_iov=siov,.msg_iovlen=2}; if(sendmsg(sp[0],&sm,0)!=4) die("sendmsg"); char r1[3]={0},r2[3]={0}; struct iovec riov2[2]={{r1,2},{r2,2}}; struct msghdr rm={.msg_iov=riov2,.msg_iovlen=2}; if(recvmsg(sp[1],&rm,0)!=4||memcmp(r1,"ab",2)||memcmp(r2,"cd",2)) die("recvmsg"); int pfd[2]; if(pipe(pfd)<0) die("pipe"); char ctrl[CMSG_SPACE(sizeof(int))]; memset(ctrl,0,sizeof(ctrl)); char marker='F'; struct iovec fdiov={&marker,1}; memset(&sm,0,sizeof(sm)); sm.msg_iov=&fdiov; sm.msg_iovlen=1; sm.msg_control=ctrl; sm.msg_controllen=sizeof(ctrl); struct cmsghdr *ch=CMSG_FIRSTHDR(&sm); ch->cmsg_level=SOL_SOCKET; ch->cmsg_type=SCM_RIGHTS; ch->cmsg_len=CMSG_LEN(sizeof(int)); memcpy(CMSG_DATA(ch),&pfd[0],sizeof(int)); if(sendmsg(sp[0],&sm,0)!=1) die("sendmsg fd"); char fdmarker=0; struct iovec friov={&fdmarker,1}; char rctrl[CMSG_SPACE(sizeof(int))]; memset(rctrl,0,sizeof(rctrl)); memset(&rm,0,sizeof(rm)); rm.msg_iov=&friov; rm.msg_iovlen=1; rm.msg_control=rctrl; rm.msg_controllen=sizeof(rctrl); if(recvmsg(sp[1],&rm,0)!=1||fdmarker!='F') die("recvmsg fd"); ch=CMSG_FIRSTHDR(&rm); if(!ch||ch->cmsg_level!=SOL_SOCKET||ch->cmsg_type!=SCM_RIGHTS) die("recvmsg cmsg"); int gotfd=-1; memcpy(&gotfd,CMSG_DATA(ch),sizeof(int)); if(write(pfd[1],"Q",1)!=1) die("pipe write"); char q=0; if(read(gotfd,&q,1)!=1||q!='Q') die("recv fd read"); close(gotfd); close(pfd[0]); close(pfd[1]); close(sp[0]); close(sp[1]);
 char local[16]="self"; char out[16]={0}; struct iovec li={out,5}, ri={local,5}; ssize_t vr=syscall(SYS_process_vm_readv,getpid(),&li,1,&ri,1,0); if(vr!=5||strcmp(out,"self")) die("process_vm_readv"); char in[16]="that"; struct iovec liw={in,5}, riw={local,5}; ssize_t vw=syscall(SYS_process_vm_writev,getpid(),&liw,1,&riw,1,0); if(vw!=5||strcmp(local,"that")) die("process_vm_writev"); void *big=mmap(NULL,0x2000001000ULL,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE,-1,0); if(big==MAP_FAILED) die("mmap big noreserve"); void *mid=mmap(NULL,0x10000000ULL,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_NORESERVE,-1,0); if(mid==MAP_FAILED) die("mmap mid noreserve"); uintptr_t ba=(uintptr_t)big, ma=(uintptr_t)mid; if(ma>=ba&&ma<ba+0x2000001000ULL) die("mmap noreserve overlap"); volatile char *mp=(volatile char*)mid; mp[0]=1; mp[0x1000]=2; munmap(mid,0x10000000ULL); munmap(big,0x2000001000ULL);
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

    cat >"$dir/addsub_cbz.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

static uint64_t sub_cbnz64(uint64_t n) {
    uint64_t v;
    __asm__ volatile(
        "mov %0, %1\n"
        "1: sub %0, %0, #1\n"
        "cbnz %0, 1b\n"
        : "=&r"(v) : "r"(n));
    return v;
}

static uint64_t add_cbnz64(uint64_t n) {
    uint64_t v;
    __asm__ volatile(
        "mov %0, %1\n"
        "1: add %0, %0, #1\n"
        "cbnz %0, 1b\n"
        : "=&r"(v) : "r"(n));
    return v;
}

static uint64_t sub_cbz64(uint64_t n) {
    uint64_t v, out;
    __asm__ volatile(
        "mov %0, %2\n"
        "sub %0, %0, #1\n"
        "cbz %0, 1f\n"
        "mov %1, #99\n"
        "b 2f\n"
        "1: mov %1, #7\n"
        "2:\n"
        : "=&r"(v), "=&r"(out) : "r"(n));
    return v + out;
}

static uint32_t add_cbz32(uint32_t n) {
    uint32_t v, out;
    __asm__ volatile(
        "mov %w0, %w2\n"
        "add %w0, %w0, #1\n"
        "cbz %w0, 1f\n"
        "mov %w1, #99\n"
        "b 2f\n"
        "1: mov %w1, #11\n"
        "2:\n"
        : "=&r"(v), "=&r"(out) : "r"(n));
    return v + out;
}

int main(void) {
    int fail = 0;
    if (sub_cbnz64(5) != 0) fail++;
    if (add_cbnz64(UINT64_MAX - 2) != 0) fail++;
    if (sub_cbz64(1) != 7) fail++;
    if (add_cbz32(UINT32_MAX) != 11) fail++;
    if (fail) {
        printf("addsub-cbz-fail %d\n", fail);
        return 1;
    }
    puts("addsub-cbz-ok");
    return 0;
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

    cat >"$dir/precise_fault_pc.c" <<'EOF'
#define _GNU_SOURCE
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <ucontext.h>

uintptr_t expected_read_pc;
uintptr_t expected_write_pc;

void precise_fault_read(void);
void precise_fault_write(void);

__asm__(
".text\n"
".align 2\n"
".global precise_fault_read\n"
"precise_fault_read:\n"
"    adrp x10, expected_read_pc\n"
"    add x10, x10, :lo12:expected_read_pc\n"
"    adr x9, 1f\n"
"    str x9, [x10]\n"
"    mov x11, xzr\n"
"1:  ldr x12, [x11]\n"
"    ret\n"
".global precise_fault_write\n"
"precise_fault_write:\n"
"    adrp x10, expected_write_pc\n"
"    add x10, x10, :lo12:expected_write_pc\n"
"    adr x9, 1f\n"
"    str x9, [x10]\n"
"    mov x11, xzr\n"
"1:  str xzr, [x11]\n"
"    ret\n"
);

static sigjmp_buf jb;
static volatile int stage;
static volatile uintptr_t observed_pc[2];
static volatile uintptr_t observed_fault[2];

static void handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    ucontext_t *uc = (ucontext_t *)uctx;
    int idx = stage - 1;
    if (idx >= 0 && idx < 2) {
        observed_pc[idx] = (uintptr_t)uc->uc_mcontext.pc;
        observed_fault[idx] = (uintptr_t)si->si_addr;
    }
    siglongjmp(jb, 1);
}

static int run_fault(void (*fn)(void), int new_stage) {
    stage = new_stage;
    if (sigsetjmp(jb, 1) == 0) {
        fn();
        return 1;
    }
    return 0;
}

int main(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) != 0)
        return 1;

    int fail = 0;
    fail += run_fault(precise_fault_read, 1);
    fail += run_fault(precise_fault_write, 2);

    if (observed_fault[0] != 0 || observed_pc[0] != expected_read_pc) {
        fprintf(stderr, "read pc mismatch expected=%#lx observed=%#lx fault=%#lx\n",
                (unsigned long)expected_read_pc, (unsigned long)observed_pc[0],
                (unsigned long)observed_fault[0]);
        fail++;
    }
    if (observed_fault[1] != 0 || observed_pc[1] != expected_write_pc) {
        fprintf(stderr, "write pc mismatch expected=%#lx observed=%#lx fault=%#lx\n",
                (unsigned long)expected_write_pc, (unsigned long)observed_pc[1],
                (unsigned long)observed_fault[1]);
        fail++;
    }

    if (fail)
        return 1;
    puts("precise-fault-pc-ok");
    return 0;
}
EOF

    cat >"$dir/fused_addsub_ldr_fault.c" <<'EOF'
#define _GNU_SOURCE
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <ucontext.h>

uintptr_t expected_pc;
void fused_fault(void);

__asm__(
".text\n"
".align 2\n"
".global fused_fault\n"
"fused_fault:\n"
"    adrp x12, expected_pc\n"
"    add x12, x12, :lo12:expected_pc\n"
"    adr x13, 1f\n"
"    str x13, [x12]\n"
"    mov x9, #-8\n"
"    add x10, x9, #8\n"
"1:  ldr x11, [x10]\n"
"    ret\n"
);

static sigjmp_buf jb;
static volatile uintptr_t observed_pc;
static volatile uintptr_t observed_fault;
static volatile uintptr_t observed_x10;

static void handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    ucontext_t *uc = (ucontext_t *)uctx;
    observed_pc = (uintptr_t)uc->uc_mcontext.pc;
    observed_fault = (uintptr_t)si->si_addr;
    observed_x10 = (uintptr_t)uc->uc_mcontext.regs[10];
    siglongjmp(jb, 1);
}

int main(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) != 0)
        return 1;
    if (sigsetjmp(jb, 1) == 0) {
        fused_fault();
        return 1;
    }
    if (observed_pc != expected_pc || observed_fault != 0 || observed_x10 != 0) {
        fprintf(stderr, "bad fused fault expected_pc=%#lx pc=%#lx fault=%#lx x10=%#lx\n",
                (unsigned long)expected_pc, (unsigned long)observed_pc,
                (unsigned long)observed_fault, (unsigned long)observed_x10);
        return 1;
    }
    puts("fused-addsub-ldr-fault-ok");
    return 0;
}
EOF

    cat >"$dir/addsub_ldr32_fusion.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

static uint32_t data[8] = {
    0x11111111u, 0x22222222u, 0x89abcdefu, 0xfedcba98u,
    0x55555555u, 0x66666666u, 0x77777777u, 0x88888888u
};

int main(void) {
    uint64_t loaded0 = 0, loaded1 = 0;
    __asm__ volatile(
        "mov x9, %[base]\n"
        "add x10, x9, #4\n"
        "ldr w11, [x10, #4]\n"
        "add x12, x9, #12\n"
        "ldr w12, [x12]\n"
        "mov %[loaded0], x11\n"
        "mov %[loaded1], x12\n"
        : [loaded0] "=r"(loaded0), [loaded1] "=r"(loaded1)
        : [base] "r"(data)
        : "x9", "x10", "x11", "x12", "memory", "cc");
    if (loaded0 != data[2] || loaded1 != data[3]) {
        printf("addsub-ldr32-fail %llx %llx\n",
               (unsigned long long)loaded0, (unsigned long long)loaded1);
        return 1;
    }
    puts("addsub-ldr32-fusion-ok");
    return 0;
}
EOF

    cat >"$dir/fused_addsub_ldr32_fault.c" <<'EOF'
#define _GNU_SOURCE
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <ucontext.h>

uintptr_t expected_pc;
void fused_fault(void);

__asm__(
".text\n"
".align 2\n"
".global fused_fault\n"
"fused_fault:\n"
"    adrp x12, expected_pc\n"
"    add x12, x12, :lo12:expected_pc\n"
"    adr x13, 1f\n"
"    str x13, [x12]\n"
"    mov x9, #-4\n"
"    movz x11, #0x5678\n"
"    movk x11, #0x1234, lsl #16\n"
"    movk x11, #0x5678, lsl #32\n"
"    movk x11, #0x1234, lsl #48\n"
"    add x10, x9, #4\n"
"1:  ldr w11, [x10]\n"
"    ret\n"
);

static sigjmp_buf jb;
static volatile uintptr_t observed_pc;
static volatile uintptr_t observed_fault;
static volatile uintptr_t observed_x10;
static volatile uintptr_t observed_x11;

static void handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    ucontext_t *uc = (ucontext_t *)uctx;
    observed_pc = (uintptr_t)uc->uc_mcontext.pc;
    observed_fault = (uintptr_t)si->si_addr;
    observed_x10 = (uintptr_t)uc->uc_mcontext.regs[10];
    observed_x11 = (uintptr_t)uc->uc_mcontext.regs[11];
    siglongjmp(jb, 1);
}

int main(void) {
    struct sigaction sa = {0};
    const uintptr_t marker = 0x1234567812345678ULL;
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) != 0)
        return 1;
    if (sigsetjmp(jb, 1) == 0) {
        fused_fault();
        return 1;
    }
    if (observed_pc != expected_pc || observed_fault != 0 || observed_x10 != 0 || observed_x11 != marker) {
        fprintf(stderr, "bad fused addsub ldr32 fault expected_pc=%#lx pc=%#lx fault=%#lx x10=%#lx x11=%#lx\n",
                (unsigned long)expected_pc, (unsigned long)observed_pc,
                (unsigned long)observed_fault, (unsigned long)observed_x10,
                (unsigned long)observed_x11);
        return 1;
    }
    puts("fused-addsub-ldr32-fault-ok");
    return 0;
}
EOF

    cat >"$dir/addsub_ldr16_fusion.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

static uint16_t data[8] = {
    0x1111, 0x2222, 0xabcd, 0xcdef,
    0x5555, 0x6666, 0x7777, 0x8888
};

int main(void) {
    uint64_t loaded0 = 0, loaded1 = 0;
    __asm__ volatile(
        "mov x9, %[base]\n"
        "add x10, x9, #2\n"
        "ldrh w11, [x10, #2]\n"
        "add x12, x9, #6\n"
        "ldrh w12, [x12]\n"
        "mov %[loaded0], x11\n"
        "mov %[loaded1], x12\n"
        : [loaded0] "=r"(loaded0), [loaded1] "=r"(loaded1)
        : [base] "r"(data)
        : "x9", "x10", "x11", "x12", "memory", "cc");
    if (loaded0 != data[2] || loaded1 != data[3]) {
        printf("addsub-ldr16-fail %llx %llx\n",
               (unsigned long long)loaded0, (unsigned long long)loaded1);
        return 1;
    }
    puts("addsub-ldr16-fusion-ok");
    return 0;
}
EOF

    cat >"$dir/fused_addsub_ldr16_fault.c" <<'EOF'
#define _GNU_SOURCE
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <ucontext.h>

uintptr_t expected_pc;
void fused_fault(void);

__asm__(
".text\n"
".align 2\n"
".global fused_fault\n"
"fused_fault:\n"
"    adrp x12, expected_pc\n"
"    add x12, x12, :lo12:expected_pc\n"
"    adr x13, 1f\n"
"    str x13, [x12]\n"
"    mov x9, #-2\n"
"    movz x11, #0x5678\n"
"    movk x11, #0x1234, lsl #16\n"
"    movk x11, #0x5678, lsl #32\n"
"    movk x11, #0x1234, lsl #48\n"
"    add x10, x9, #2\n"
"1:  ldrh w11, [x10]\n"
"    ret\n"
);

static sigjmp_buf jb;
static volatile uintptr_t observed_pc;
static volatile uintptr_t observed_fault;
static volatile uintptr_t observed_x10;
static volatile uintptr_t observed_x11;

static void handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    ucontext_t *uc = (ucontext_t *)uctx;
    observed_pc = (uintptr_t)uc->uc_mcontext.pc;
    observed_fault = (uintptr_t)si->si_addr;
    observed_x10 = (uintptr_t)uc->uc_mcontext.regs[10];
    observed_x11 = (uintptr_t)uc->uc_mcontext.regs[11];
    siglongjmp(jb, 1);
}

int main(void) {
    struct sigaction sa = {0};
    const uintptr_t marker = 0x1234567812345678ULL;
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) != 0)
        return 1;
    if (sigsetjmp(jb, 1) == 0) {
        fused_fault();
        return 1;
    }
    if (observed_pc != expected_pc || observed_fault != 0 || observed_x10 != 0 || observed_x11 != marker) {
        fprintf(stderr, "bad fused addsub ldr16 fault expected_pc=%#lx pc=%#lx fault=%#lx x10=%#lx x11=%#lx\n",
                (unsigned long)expected_pc, (unsigned long)observed_pc,
                (unsigned long)observed_fault, (unsigned long)observed_x10,
                (unsigned long)observed_x11);
        return 1;
    }
    puts("fused-addsub-ldr16-fault-ok");
    return 0;
}
EOF

    cat >"$dir/addsub_ldr8_fusion.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

static uint8_t data[8] = {0x11, 0x22, 0xab, 0xcd, 0x55, 0x66, 0x77, 0x88};

int main(void) {
    uint64_t loaded0 = 0, loaded1 = 0;
    __asm__ volatile(
        "mov x9, %[base]\n"
        "add x10, x9, #1\n"
        "ldrb w11, [x10, #1]\n"
        "add x12, x9, #3\n"
        "ldrb w12, [x12]\n"
        "mov %[loaded0], x11\n"
        "mov %[loaded1], x12\n"
        : [loaded0] "=r"(loaded0), [loaded1] "=r"(loaded1)
        : [base] "r"(data)
        : "x9", "x10", "x11", "x12", "memory", "cc");
    if (loaded0 != data[2] || loaded1 != data[3]) {
        printf("addsub-ldr8-fail %llx %llx\n",
               (unsigned long long)loaded0, (unsigned long long)loaded1);
        return 1;
    }
    puts("addsub-ldr8-fusion-ok");
    return 0;
}
EOF

    cat >"$dir/fused_addsub_ldr8_fault.c" <<'EOF'
#define _GNU_SOURCE
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <ucontext.h>

uintptr_t expected_pc;
void fused_fault(void);

__asm__(
".text\n"
".align 2\n"
".global fused_fault\n"
"fused_fault:\n"
"    adrp x12, expected_pc\n"
"    add x12, x12, :lo12:expected_pc\n"
"    adr x13, 1f\n"
"    str x13, [x12]\n"
"    mov x9, #-1\n"
"    movz x11, #0x5678\n"
"    movk x11, #0x1234, lsl #16\n"
"    movk x11, #0x5678, lsl #32\n"
"    movk x11, #0x1234, lsl #48\n"
"    add x10, x9, #1\n"
"1:  ldrb w11, [x10]\n"
"    ret\n"
);

static sigjmp_buf jb;
static volatile uintptr_t observed_pc;
static volatile uintptr_t observed_fault;
static volatile uintptr_t observed_x10;
static volatile uintptr_t observed_x11;

static void handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    ucontext_t *uc = (ucontext_t *)uctx;
    observed_pc = (uintptr_t)uc->uc_mcontext.pc;
    observed_fault = (uintptr_t)si->si_addr;
    observed_x10 = (uintptr_t)uc->uc_mcontext.regs[10];
    observed_x11 = (uintptr_t)uc->uc_mcontext.regs[11];
    siglongjmp(jb, 1);
}

int main(void) {
    struct sigaction sa = {0};
    const uintptr_t marker = 0x1234567812345678ULL;
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) != 0)
        return 1;
    if (sigsetjmp(jb, 1) == 0) {
        fused_fault();
        return 1;
    }
    if (observed_pc != expected_pc || observed_fault != 0 || observed_x10 != 0 || observed_x11 != marker) {
        fprintf(stderr, "bad fused addsub ldr8 fault expected_pc=%#lx pc=%#lx fault=%#lx x10=%#lx x11=%#lx\n",
                (unsigned long)expected_pc, (unsigned long)observed_pc,
                (unsigned long)observed_fault, (unsigned long)observed_x10,
                (unsigned long)observed_x11);
        return 1;
    }
    puts("fused-addsub-ldr8-fault-ok");
    return 0;
}
EOF

    cat >"$dir/addsub_str_fusion.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

static uint64_t data[8] = {1,2,3,4,5,6,7,8};

int main(void) {
    uint64_t value = 0x123456789abcdef0ULL;
    uint64_t *base = data;
    __asm__ volatile(
        "mov x9, %[base]\n"
        "mov x11, %[value]\n"
        "add x10, x9, #8\n"
        "str x11, [x10, #8]\n"
        "add x12, x9, #24\n"
        "str x12, [x12]\n"
        :
        : [base] "r"(base), [value] "r"(value)
        : "x9", "x10", "x11", "x12", "memory", "cc");
    if (data[2] != value || data[3] != (uint64_t)&data[3]) {
        printf("addsub-str-fail %llx %llx\n",
               (unsigned long long)data[2], (unsigned long long)data[3]);
        return 1;
    }
    puts("addsub-str-fusion-ok");
    return 0;
}
EOF

    cat >"$dir/fused_addsub_str_fault.c" <<'EOF'
#define _GNU_SOURCE
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <ucontext.h>

uintptr_t expected_pc;
void fused_fault(void);

__asm__(
".text\n"
".align 2\n"
".global fused_fault\n"
"fused_fault:\n"
"    adrp x12, expected_pc\n"
"    add x12, x12, :lo12:expected_pc\n"
"    adr x13, 1f\n"
"    str x13, [x12]\n"
"    mov x9, #-8\n"
"    mov x10, #123\n"
"    add x11, x9, #8\n"
"1:  str x10, [x11]\n"
"    ret\n"
);

static sigjmp_buf jb;
static volatile uintptr_t observed_pc;
static volatile uintptr_t observed_fault;
static volatile uintptr_t observed_x10;
static volatile uintptr_t observed_x11;

static void handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    ucontext_t *uc = (ucontext_t *)uctx;
    observed_pc = (uintptr_t)uc->uc_mcontext.pc;
    observed_fault = (uintptr_t)si->si_addr;
    observed_x10 = (uintptr_t)uc->uc_mcontext.regs[10];
    observed_x11 = (uintptr_t)uc->uc_mcontext.regs[11];
    siglongjmp(jb, 1);
}

int main(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) != 0)
        return 1;
    if (sigsetjmp(jb, 1) == 0) {
        fused_fault();
        return 1;
    }
    if (observed_pc != expected_pc || observed_fault != 0 || observed_x10 != 123 || observed_x11 != 0) {
        fprintf(stderr, "bad fused addsub str fault expected_pc=%#lx pc=%#lx fault=%#lx x10=%#lx x11=%#lx\n",
                (unsigned long)expected_pc, (unsigned long)observed_pc,
                (unsigned long)observed_fault, (unsigned long)observed_x10,
                (unsigned long)observed_x11);
        return 1;
    }
    puts("fused-addsub-str-fault-ok");
    return 0;
}
EOF

    cat >"$dir/ldr_cbz_fusion.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

static uint64_t data[2] = {0, 7};

int main(void) {
    uint64_t a = 0, b = 0, loaded0 = 99, loaded1 = 0;
    __asm__ volatile(
        "mov x9, %[base]\n"
        "ldr %[loaded0], [x9, #0]\n"
        "cbz %[loaded0], 1f\n"
        "mov %[a], #99\n"
        "b 2f\n"
        "1: mov %[a], #11\n"
        "2:\n"
        "ldr %[loaded1], [x9, #8]\n"
        "cbnz %[loaded1], 3f\n"
        "mov %[b], #99\n"
        "b 4f\n"
        "3: mov %[b], #22\n"
        "4:\n"
        : [a] "=&r"(a), [b] "=&r"(b), [loaded0] "=&r"(loaded0), [loaded1] "=&r"(loaded1)
        : [base] "r"(data)
        : "x9", "memory", "cc");
    if (a != 11 || b != 22 || loaded0 != 0 || loaded1 != 7) {
        printf("ldr-cbz-fail %llu %llu %llu %llu\n",
               (unsigned long long)a, (unsigned long long)b,
               (unsigned long long)loaded0, (unsigned long long)loaded1);
        return 1;
    }
    puts("ldr-cbz-fusion-ok");
    return 0;
}
EOF

    cat >"$dir/ldr32_cbz_fusion.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

static uint32_t data[2] = {0, 0x80000001u};

int main(void) {
    uint64_t a = 0, b = 0, loaded0 = 99, loaded1 = 0;
    __asm__ volatile(
        "mov x9, %[base]\n"
        "ldr w11, [x9, #0]\n"
        "cbz w11, 1f\n"
        "mov %[a], #99\n"
        "b 2f\n"
        "1: mov %[a], #11\n"
        "2:\n"
        "ldr w12, [x9, #4]\n"
        "cbnz w12, 3f\n"
        "mov %[b], #99\n"
        "b 4f\n"
        "3: mov %[b], #22\n"
        "4:\n"
        "mov %[loaded0], x11\n"
        "mov %[loaded1], x12\n"
        : [a] "=&r"(a), [b] "=&r"(b), [loaded0] "=&r"(loaded0), [loaded1] "=&r"(loaded1)
        : [base] "r"(data)
        : "x9", "x11", "x12", "memory", "cc");
    if (a != 11 || b != 22 || loaded0 != 0 || loaded1 != data[1]) {
        printf("ldr32-cbz-fail %llu %llu %llx %llx\n",
               (unsigned long long)a, (unsigned long long)b,
               (unsigned long long)loaded0, (unsigned long long)loaded1);
        return 1;
    }
    puts("ldr32-cbz-fusion-ok");
    return 0;
}
EOF

    cat >"$dir/fused_ldr32_cbz_fault.c" <<'EOF'
#define _GNU_SOURCE
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <ucontext.h>

uintptr_t expected_pc;
void fused_fault(void);

__asm__(
".text\n"
".align 2\n"
".global fused_fault\n"
"fused_fault:\n"
"    adrp x12, expected_pc\n"
"    add x12, x12, :lo12:expected_pc\n"
"    adr x13, 1f\n"
"    str x13, [x12]\n"
"    mov x9, xzr\n"
"    mov x10, #123\n"
"1:  ldr w10, [x9]\n"
"    cbz w10, 2f\n"
"2:  ret\n"
);

static sigjmp_buf jb;
static volatile uintptr_t observed_pc;
static volatile uintptr_t observed_fault;
static volatile uintptr_t observed_x10;

static void handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    ucontext_t *uc = (ucontext_t *)uctx;
    observed_pc = (uintptr_t)uc->uc_mcontext.pc;
    observed_fault = (uintptr_t)si->si_addr;
    observed_x10 = (uintptr_t)uc->uc_mcontext.regs[10];
    siglongjmp(jb, 1);
}

int main(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) != 0)
        return 1;
    if (sigsetjmp(jb, 1) == 0) {
        fused_fault();
        return 1;
    }
    if (observed_pc != expected_pc || observed_fault != 0 || observed_x10 != 123) {
        fprintf(stderr, "bad fused ldr32 cbz fault expected_pc=%#lx pc=%#lx fault=%#lx x10=%#lx\n",
                (unsigned long)expected_pc, (unsigned long)observed_pc,
                (unsigned long)observed_fault, (unsigned long)observed_x10);
        return 1;
    }
    puts("fused-ldr32-cbz-fault-ok");
    return 0;
}
EOF

    cat >"$dir/ldr8_cbz_fusion.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>

static uint8_t data[2] = {0, 0x81u};

int main(void) {
    uint64_t a = 0, b = 0, loaded0 = 99, loaded1 = 0;
    __asm__ volatile(
        "mov x9, %[base]\n"
        "ldrb w11, [x9, #0]\n"
        "cbz w11, 1f\n"
        "mov %[a], #99\n"
        "b 2f\n"
        "1: mov %[a], #11\n"
        "2:\n"
        "ldrb w12, [x9, #1]\n"
        "cbnz w12, 3f\n"
        "mov %[b], #99\n"
        "b 4f\n"
        "3: mov %[b], #22\n"
        "4:\n"
        "mov %[loaded0], x11\n"
        "mov %[loaded1], x12\n"
        : [a] "=&r"(a), [b] "=&r"(b), [loaded0] "=&r"(loaded0), [loaded1] "=&r"(loaded1)
        : [base] "r"(data)
        : "x9", "x11", "x12", "memory", "cc");
    if (a != 11 || b != 22 || loaded0 != 0 || loaded1 != data[1]) {
        printf("ldr8-cbz-fail %llu %llu %llx %llx\n",
               (unsigned long long)a, (unsigned long long)b,
               (unsigned long long)loaded0, (unsigned long long)loaded1);
        return 1;
    }
    puts("ldr8-cbz-fusion-ok");
    return 0;
}
EOF

    cat >"$dir/fused_ldr8_cbz_fault.c" <<'EOF'
#define _GNU_SOURCE
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <ucontext.h>

uintptr_t expected_pc;
void fused_fault(void);

__asm__(
".text\n"
".align 2\n"
".global fused_fault\n"
"fused_fault:\n"
"    adrp x12, expected_pc\n"
"    add x12, x12, :lo12:expected_pc\n"
"    adr x13, 1f\n"
"    str x13, [x12]\n"
"    mov x9, xzr\n"
"    mov x10, #123\n"
"1:  ldrb w10, [x9]\n"
"    cbz w10, 2f\n"
"2:  ret\n"
);

static sigjmp_buf jb;
static volatile uintptr_t observed_pc;
static volatile uintptr_t observed_fault;
static volatile uintptr_t observed_x10;

static void handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    ucontext_t *uc = (ucontext_t *)uctx;
    observed_pc = (uintptr_t)uc->uc_mcontext.pc;
    observed_fault = (uintptr_t)si->si_addr;
    observed_x10 = (uintptr_t)uc->uc_mcontext.regs[10];
    siglongjmp(jb, 1);
}

int main(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) != 0)
        return 1;
    if (sigsetjmp(jb, 1) == 0) {
        fused_fault();
        return 1;
    }
    if (observed_pc != expected_pc || observed_fault != 0 || observed_x10 != 123) {
        fprintf(stderr, "bad fused ldr8 cbz fault expected_pc=%#lx pc=%#lx fault=%#lx x10=%#lx\n",
                (unsigned long)expected_pc, (unsigned long)observed_pc,
                (unsigned long)observed_fault, (unsigned long)observed_x10);
        return 1;
    }
    puts("fused-ldr8-cbz-fault-ok");
    return 0;
}
EOF

    cat >"$dir/fused_ldr_cbz_fault.c" <<'EOF'
#define _GNU_SOURCE
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <ucontext.h>

uintptr_t expected_pc;
void fused_fault(void);

__asm__(
".text\n"
".align 2\n"
".global fused_fault\n"
"fused_fault:\n"
"    adrp x12, expected_pc\n"
"    add x12, x12, :lo12:expected_pc\n"
"    adr x13, 1f\n"
"    str x13, [x12]\n"
"    mov x9, xzr\n"
"    mov x10, #123\n"
"1:  ldr x10, [x9]\n"
"    cbz x10, 2f\n"
"2:  ret\n"
);

static sigjmp_buf jb;
static volatile uintptr_t observed_pc;
static volatile uintptr_t observed_fault;
static volatile uintptr_t observed_x10;

static void handler(int sig, siginfo_t *si, void *uctx) {
    (void)sig;
    ucontext_t *uc = (ucontext_t *)uctx;
    observed_pc = (uintptr_t)uc->uc_mcontext.pc;
    observed_fault = (uintptr_t)si->si_addr;
    observed_x10 = (uintptr_t)uc->uc_mcontext.regs[10];
    siglongjmp(jb, 1);
}

int main(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) != 0)
        return 1;
    if (sigsetjmp(jb, 1) == 0) {
        fused_fault();
        return 1;
    }
    if (observed_pc != expected_pc || observed_fault != 0 || observed_x10 != 123) {
        fprintf(stderr, "bad fused ldr cbz fault expected_pc=%#lx pc=%#lx fault=%#lx x10=%#lx\n",
                (unsigned long)expected_pc, (unsigned long)observed_pc,
                (unsigned long)observed_fault, (unsigned long)observed_x10);
        return 1;
    }
    puts("fused-ldr-cbz-fault-ok");
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
- rootfs lanes: $ROOTFS_LANES
- timeout: ${TIMEOUT_S}s
- install timeout: ${INSTALL_TIMEOUT_S}s

## Summary

- Total: $TOTAL_COUNT
- Passed: $PASS_COUNT
- Failed: $FAIL_COUNT

## Results

| Lane | Stage | Test | Status | Detail |
|---|---|---|---|---|
$REPORT_ROWS
EOF
}

run_lane() {
    LANE_NAME="$1"
    ROOTFS="$2"

    [ -d "$ROOTFS" ] || { echo "missing rootfs for lane $LANE_NAME: $ROOTFS" >&2; return 1; }

    ensure_guest_basics

    run_test base "shell" "echo shell-ok | grep -qx shell-ok"
    run_test base "package manager" "if command -v apk >/dev/null 2>&1; then apk --version >/dev/null 2>&1; elif command -v apt-get >/dev/null 2>&1; then apt-get --version >/dev/null 2>&1; else exit 127; fi"
    run_test base "tmp file io" "echo file-ok > '$GUEST_WORK/base.txt' && grep -qx file-ok '$GUEST_WORK/base.txt'"
    run_test base "symlink retarget normalization" "rm -rf '$GUEST_WORK/path-cache' && mkdir -p '$GUEST_WORK/path-cache' && cd '$GUEST_WORK/path-cache' && echo old > old.txt && echo new > new.txt && ln -s old.txt current && grep -qx old current && rm -f current && ln -s new.txt current && grep -qx new current"

    ensure_tools 'build-base|gcc:gcc'
    prepare_c_fixture
    run_test c "gcc version" "gcc --version | head -1"
    run_test c "compile + run" "cd '$GUEST_WORK/c' && gcc -O0 hello.c -o hello && ./hello | grep -q '^c-runtime-ok '"
    run_test c "sysv shm/msg IPC" "cd '$GUEST_WORK/c' && gcc -O0 sysv_ipc.c -o sysv_ipc && ./sysv_ipc | grep -qx sysv-ipc-ok"
    run_test c "high-value syscall gaps" "cd '$GUEST_WORK/c' && gcc -O0 syscall_gaps.c -o syscall_gaps -lrt && ./syscall_gaps | grep -qx syscall-gaps-ok"
    run_test c "arm64 DC ZVA sysreg/instruction" "cd '$GUEST_WORK/c' && gcc -O0 dczva.c -o dczva && ./dczva | grep -qx dczva-ok"
    run_test c "arm64 signal ucontext layout" "cd '$GUEST_WORK/c' && gcc -O0 signal_ucontext.c -o signal_ucontext && ./signal_ucontext | grep -qx signal-ucontext-ok"
    run_test c "arm64 precise fault pc" "cd '$GUEST_WORK/c' && gcc -O0 -fno-pie -no-pie precise_fault_pc.c -o precise_fault_pc && ./precise_fault_pc | grep -qx precise-fault-pc-ok"
    run_test c "arm64 fused addsub ldr fault pc" "cd '$GUEST_WORK/c' && gcc -O0 -fno-pie -no-pie fused_addsub_ldr_fault.c -o fused_addsub_ldr_fault && ./fused_addsub_ldr_fault | grep -qx fused-addsub-ldr-fault-ok"
    run_test c "arm64 addsub ldr32 fusion" "cd '$GUEST_WORK/c' && gcc -O0 addsub_ldr32_fusion.c -o addsub_ldr32_fusion && ./addsub_ldr32_fusion | grep -qx addsub-ldr32-fusion-ok"
    run_test c "arm64 fused addsub ldr32 fault pc" "cd '$GUEST_WORK/c' && gcc -O0 -fno-pie -no-pie fused_addsub_ldr32_fault.c -o fused_addsub_ldr32_fault && ./fused_addsub_ldr32_fault | grep -qx fused-addsub-ldr32-fault-ok"
    run_test c "arm64 addsub ldr16 fusion" "cd '$GUEST_WORK/c' && gcc -O0 addsub_ldr16_fusion.c -o addsub_ldr16_fusion && ./addsub_ldr16_fusion | grep -qx addsub-ldr16-fusion-ok"
    run_test c "arm64 fused addsub ldr16 fault pc" "cd '$GUEST_WORK/c' && gcc -O0 -fno-pie -no-pie fused_addsub_ldr16_fault.c -o fused_addsub_ldr16_fault && ./fused_addsub_ldr16_fault | grep -qx fused-addsub-ldr16-fault-ok"
    run_test c "arm64 addsub ldr8 fusion" "cd '$GUEST_WORK/c' && gcc -O0 addsub_ldr8_fusion.c -o addsub_ldr8_fusion && ./addsub_ldr8_fusion | grep -qx addsub-ldr8-fusion-ok"
    run_test c "arm64 fused addsub ldr8 fault pc" "cd '$GUEST_WORK/c' && gcc -O0 -fno-pie -no-pie fused_addsub_ldr8_fault.c -o fused_addsub_ldr8_fault && ./fused_addsub_ldr8_fault | grep -qx fused-addsub-ldr8-fault-ok"
    run_test c "arm64 addsub str fusion" "cd '$GUEST_WORK/c' && gcc -O0 addsub_str_fusion.c -o addsub_str_fusion && ./addsub_str_fusion | grep -qx addsub-str-fusion-ok"
    run_test c "arm64 fused addsub str fault pc" "cd '$GUEST_WORK/c' && gcc -O0 -fno-pie -no-pie fused_addsub_str_fault.c -o fused_addsub_str_fault && ./fused_addsub_str_fault | grep -qx fused-addsub-str-fault-ok"
    run_test c "arm64 ldr cbz fusion" "cd '$GUEST_WORK/c' && gcc -O0 ldr_cbz_fusion.c -o ldr_cbz_fusion && ./ldr_cbz_fusion | grep -qx ldr-cbz-fusion-ok"
    run_test c "arm64 fused ldr cbz fault pc" "cd '$GUEST_WORK/c' && gcc -O0 -fno-pie -no-pie fused_ldr_cbz_fault.c -o fused_ldr_cbz_fault && ./fused_ldr_cbz_fault | grep -qx fused-ldr-cbz-fault-ok"
    run_test c "arm64 ldr32 cbz fusion" "cd '$GUEST_WORK/c' && gcc -O0 ldr32_cbz_fusion.c -o ldr32_cbz_fusion && ./ldr32_cbz_fusion | grep -qx ldr32-cbz-fusion-ok"
    run_test c "arm64 fused ldr32 cbz fault pc" "cd '$GUEST_WORK/c' && gcc -O0 -fno-pie -no-pie fused_ldr32_cbz_fault.c -o fused_ldr32_cbz_fault && ./fused_ldr32_cbz_fault | grep -qx fused-ldr32-cbz-fault-ok"
    run_test c "arm64 ldr8 cbz fusion" "cd '$GUEST_WORK/c' && gcc -O0 ldr8_cbz_fusion.c -o ldr8_cbz_fusion && ./ldr8_cbz_fusion | grep -qx ldr8-cbz-fusion-ok"
    run_test c "arm64 fused ldr8 cbz fault pc" "cd '$GUEST_WORK/c' && gcc -O0 -fno-pie -no-pie fused_ldr8_cbz_fault.c -o fused_ldr8_cbz_fault && ./fused_ldr8_cbz_fault | grep -qx fused-ldr8-cbz-fault-ok"
    run_test c "per-thread sigaltstack" "cd '$GUEST_WORK/c' && gcc -O0 sigaltstack_thread.c -o sigaltstack_thread -pthread && ./sigaltstack_thread | grep -qx sigaltstack-thread-ok"
    run_test c "arm64 CCMP/CCMN NV condition" "cd '$GUEST_WORK/c' && gcc -O0 ccmp_nv.c -o ccmp_nv && ./ccmp_nv | grep -qx ccmp-nv-ok"
    run_test c "arm64 barriers DMB/DSB/ISB" "cd '$GUEST_WORK/c' && gcc -O0 barriers.c -o barriers && ./barriers | grep -qx barriers-ok"
    run_test c "arm64 self-modifying code invalidation" "cd '$GUEST_WORK/c' && gcc -O0 smc.c -o smc && ./smc | grep -qx 'smc 1 2'"
    run_test c "arm64 add/sub cbz fusion" "cd '$GUEST_WORK/c' && gcc -O0 addsub_cbz.c -o addsub_cbz && ./addsub_cbz | grep -qx addsub-cbz-ok"

    ensure_tools 'go|golang-go:go'
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

    ensure_tools python3 lua5.4 'openjdk21-jdk|openjdk-21-jdk:javac' clojure
    run_test python "python3 version" "python3 --version"
    run_test python "python3 eval" "python3 -c 'print(\"python-runtime-ok\", sum(range(10)))' | grep -qx 'python-runtime-ok 45'"
    run_test lua "lua5.4 version" "lua5.4 -v"
    run_test lua "lua5.4 eval" "lua5.4 -e 'print(\"lua-runtime-ok\", 2+3)' | grep -q '^lua-runtime-ok[[:space:]]*5$'"
    run_test java "javac + java" "cd '$GUEST_WORK' && printf '%s\n' 'public class Hello { public static void main(String[] args) { System.out.println(\"java-runtime-ok\"); } }' > Hello.java && javac Hello.java && java -cp . Hello | grep -qx java-runtime-ok"
    run_test java "java interpreter fallback" "cd '$GUEST_WORK' && java -Xint -cp . Hello | grep -qx java-runtime-ok"
    run_test clojure "clojure.main eval" "java -cp /usr/share/clojure/clojure.jar clojure.main -e '(println \"clojure-runtime-ok\" (+ 1 2 3))' | grep -qx 'clojure-runtime-ok 6'"
    run_test pypy "availability probe" "if command -v pypy3 >/dev/null 2>&1; then pypy3 -c 'print(\"pypy-runtime-ok\")' | grep -qx pypy-runtime-ok; elif command -v apk >/dev/null 2>&1; then ! apk search pypy | grep -E '(^|-)pypy3?(-|$)' && echo pypy-unavailable-alpine-aarch64; elif command -v apt-cache >/dev/null 2>&1; then ! apt-cache search '^pypy3?$' | grep -E '(^|-)pypy3?(-|$)' && echo pypy-unavailable-debian-arm64; else echo pypy-unavailable; fi"
    run_test swift "availability probe" "if command -v swift >/dev/null 2>&1; then swift --version; elif command -v swiftc >/dev/null 2>&1; then swiftc --version; elif command -v apk >/dev/null 2>&1; then ! apk search swift | grep -E '(^|-)swift(c)?(-|$)' && echo swift-unavailable-alpine-aarch64; elif command -v apt-cache >/dev/null 2>&1; then ! apt-cache search '^swift(c)?$' | grep -E '(^|-)swift(c)?(-|$)' && echo swift-unavailable-debian-arm64; else echo swift-unavailable; fi"

    ensure_tools 'rust|rustc:rustc' cargo
    prepare_rust_fixture
    run_test rust "rustc version" "rustc --version"
    run_test rust "rustc compile + run" "cd '$GUEST_WORK/rust' && rustc hello.rs -o rustc_app && ./rustc_app | grep -qx 'rustc-runtime-ok 5050 10100'"
    run_test rust "rustc optimized std runtime" "cd '$GUEST_WORK/rust' && rustc -O std_runtime.rs -o rust_std && ./rust_std | grep -qx rust-std-ok"
    run_test rust "rustc unit tests" "cd '$GUEST_WORK/rust' && rustc --test src/lib.rs -o lib_tests && RUST_TEST_THREADS=1 ./lib_tests --quiet"
    run_test rust "cargo build" "cd '$GUEST_WORK/rust' && cargo build --quiet"
    run_test rust "cargo run" "cd '$GUEST_WORK/rust' && cargo run --quiet | grep -q '^rust-runtime-ok 9534429477999140727 500500 rust-channel-ok rust-file-ok pong rust-child-ok$'"
    run_test rust "cargo test" "cd '$GUEST_WORK/rust' && RUST_TEST_THREADS=1 cargo test --quiet --jobs 1"

    ensure_tools 'erlang|erlang-base:erl'
    prepare_erlang_fixture
    run_test erlang "erl version" "erl -version 2>&1 | grep -q 'BEAM.*emulator version'"

    ensure_tools zig
    prepare_zig_fixture
    run_test zig "zig version" "zig version"
    run_test zig "zig build-obj" "cd '$GUEST_WORK/zig' && zig build-obj main.zig -O Debug -femit-bin=zig_runtime.o && test -s zig_runtime.o"
    run_test zig "zig object link + run" "cd '$GUEST_WORK/zig' && zig build-obj main.zig -O Debug -femit-bin=zig_runtime.o && gcc harness.c zig_runtime.o -o zig_app && ./zig_app | grep -q '^zig-runtime-ok '"

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
