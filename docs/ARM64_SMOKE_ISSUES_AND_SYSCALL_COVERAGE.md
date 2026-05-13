# ARM64 smoke issues and syscall coverage appraisal

Updated: 2026-05-13

## Executive status

The current ARM64 Linux-host fakefs is in a good core-runtime state:

- Staged runtime coverage: **49 / 49 passing**.
- Benchmarks Game core tier: **9 official language rows × 10 benchmarks = 90 / 90 runs passing**.
- Java-equivalent probe: **10 / 10 passing** in HotSpot default mixed mode; interpreter fallback mode also passes.
- Native compiler rows additionally build inside the guest: **GCC 10 / 10 builds**, **G++ 10 / 10 builds**.
- The rows now include interpreted runtimes, managed runtimes, native compilers, big integers, regex engines, pipes/stdin/stdout, `fork()`, guest pthreads, futex-heavy language runtimes, SysV shared-memory/message-queue IPC, and staged Python/Lua/Java/Clojure/PyPy/Swift/Rust/Erlang/Zig smoke or availability coverage.

## Issues found by smoke workloads

| Area | Symptom | Root cause | Status |
|---|---|---|---|
| Python Benchmarks Game | `multiprocessing.SemLock` failed when `/dev/shm` did not exist. | Fakefs root did not provide the Linux-standard `/dev/shm` directory expected by musl/Python. | **Fixed**: iSH startup pre-creates `/dev/shm` with mode `1777`. |
| Go/cgo Benchmarks Game probe | cgo/GMP `pidigits` compile failed with `failed to get exit status: Interrupted system call`. | iSH's internal bounded `wait4` polling timeout leaked to the guest as `EINTR`. | **Fixed**: internal `_ETIMEDOUT` is retried and no longer returned as guest `EINTR`. |
| Go Benchmarks Game / signals | Transient `fatal: bad g in signal handler` at Go `binarytrees`. | `sigaltstack` state was stored in shared `sighand`, but Linux makes it per-thread. Go installs one signal stack per M/thread, so another thread could receive a signal on the wrong alternate stack. | **Fixed**: alternate signal stack state now lives on `task`; clone/fork inheritance follows Linux semantics; runtime coverage includes a pthread per-thread `sigaltstack` fixture. |
| Ruby Benchmarks Game | Thread/fork-heavy `regexredux-ruby-3` was killed by `SAFETY-VALVE[poll]`. | Poll safety valve treated one polling thread as whole-process idleness while other guest threads were still doing CPU work. | **Fixed**: poll valve only fires when there are no live children and all threads are blocking. |
| PHP Benchmarks Game | Fast official PHP variants failed in `shmop_*()` and `msg_*()` calls. | ARM64 direct SysV shared memory and message queue syscalls were stubs. | **Fixed**: implemented enough `shmget`/`shmctl`/`shmat`/`shmdt` and `msgget`/`msgctl`/`msgsnd`/`msgrcv` for forked worker result passing. Runtime coverage now includes a C SysV IPC across-`fork()` test. |
| Bun/PiClaw smoke | Bun recursive copy attempted file-copy on directories and hit `ENOTSUP`. | `getdents64` returned `DT_UNKNOWN` instead of directory entry types. | **Fixed**: directory entry `d_type` is now reported. |
| Bun/JSC smoke | Bun allocator/free-list crashes around high heap/cage mappings. | ARM64 fault retry was imprecise for translated load/store blocks; high mmap hints were also mishandled. | **Fixed**: precise memory-fault retry PC and high-address ARM64 mmap handling. |
| Bun/JSC smoke | `bun -e`, timers, and server startup could stall. | JSC parallel/concurrent GC uses signal coordination patterns that exposed iSH scheduling/signal-delivery limits. | **Mitigated correctly for this runtime**: ARM64 guest shim constrains JSC to one marker and disables concurrent GC. |
| go-gte workload | Model conversion trapped on AdvSIMD FP widening conversion. | Missing ARM64 `FCVTL`/`FCVTL2` instruction coverage. | **Fixed**: H→S and S→D widening conversion handlers added. |
| GCC/G++ Benchmarks Game | Several fastest native variants include `immintrin.h`, `x86intrin.h`, SSE, or AVX intrinsics. | Official source is x86-specific, not portable C/C++ and not an ARM64 emulation bug. | **Accounted for, not patched**: rows record these alternatives and select the next official portable source. |
| GCC/G++ Benchmarks Game | Some threaded `revcomp`/`fasta` variants segfault under Alpine/musl. | The source allocates large per-thread VLAs; musl's default pthread stack is much smaller than the Debian/glibc environment used by the benchmark site. | **Accounted for as source/environment limitation**: rows select the next official portable/non-overflowing variant rather than changing benchmark source. |
| G++ Benchmarks Game | `fannkuchredux-gpp-5` does not compile with Alpine's current GCC without a missing include fix. | Source uses `int64_t` without including `<cstdint>`. | **Accounted for as source portability issue**: row selects the next official variant instead of patching source. |
| Node.js Benchmarks Game | First Node row skipped `worker_threads` variants. | At the time this was kept as a scheduler/futex stress lane; after the poll-valve fix, worker creation itself works, but some official worker variants produce no output at smoke-sized inputs. | **No active iSH correctness blocker**; keep as a separate stress/validation lane if we want larger inputs or per-variant expected-output checks. |
| Java/OpenJDK probe | Startup, default mixed-mode `javac Hello.java`, `java Hello`, and Java-equivalent Benchmarks Game equivalents pass. | Fixed ARM64 ABI/runtime blockers (`DCZID_EL0`/`dc zva`, Linux/musl-compatible signal `ucontext_t`, null SIGSEGV delivery) and the later C2 compiler divergence caused by missing `LDPSW` pair-load sign extension. | **Closed for smoke scope**: default mixed-mode Java smoke passes; keep broader HotSpot/JIT workloads in the regression matrix. |
| External dependency alternatives | Perl GMP backend, Node `mpzjs`, Lua `bn`, and similar variants are not always packaged by Alpine. | Missing language-specific third-party packages, not emulator faults. | **Accounted for**: where a packaged/buildable dependency exists we use it (`php84-gmp`, `lua5.3` LGMP via luarocks, PCRE packages); otherwise variants remain external lanes. |

## Current syscall coverage snapshot

Static analysis of `kernel/arch/arm64/calls.c` as of this appraisal:

| Metric | Count | Notes |
|---|---:|---|
| ARM64 syscall table span | 440 slots | Numeric span `0..439`; includes many holes/newer syscalls that are not explicitly named. |
| Explicitly assigned slots | 286 | Includes the `[5 ... 16]` xattr range expanded to 12 slots. |
| Functional `sys_*` implementations | 207 | Real handlers, excluding xattr/success/silent/loud stubs. |
| Compatibility success stub | 1 | `sync` returns success. |
| xattr stub range | 12 | Extended attributes are recognized but not implemented as real storage semantics. |
| Loud `ENOSYS` stubs | 61 | Printed as stub syscall diagnostics when hit. |
| Silent `ENOSYS` stubs | 5 | Modern runtime probes where quiet fallback is expected (`io_uring_*`, `pidfd_*`). |
| Unassigned slots in span | 154 | Default to `ENOSYS`; mostly gaps between older asm-generic and newer syscall ranges. |

Useful ratios:

- Functional coverage of explicitly assigned ARM64 slots: **207 / 286 = 72.4%**.
- Functional coverage of the full numeric `0..439` span: **207 / 440 = 47.0%**. This denominator overstates practical workload exposure because it includes unassigned holes.
- Functional-or-benign assigned coverage, counting `sync` success and xattr-recognized stubs: **220 / 286 = 76.9%**.

## Coverage strengths

The implemented set is now strong for the workloads currently passing:

- process basics: `clone`, `clone3` fallback behavior, `execve`, `wait4`, `waitid`, `exit`, `exit_group`, tids/pids, groups/users, sessions/process groups;
- memory: `mmap`, high ARM64 mmap hints, `munmap`, `mprotect`, `mremap`, `madvise`, `mincore`, `mlock`, `msync`, lazy `MAP_NORESERVE` reservations;
- synchronization: futex wait/wake/requeue/wake-op, robust lists, nanosleep/timers;
- filesystems: `openat`, `read`/`write`, `readv`/`writev`, `pread`/`pwrite`, `preadv`/`pwritev`, `getdents64`, `statx`, `fstatat`, `copy_file_range`, `sendfile`, `splice`, chmod/chown/link/symlink/rename/unlink/mkdir, `statfs`/`fstatfs`;
- sockets: core TCP/UDP/Unix socket paths, UDP `sendto`/`recvfrom`, `getsockname`, socket options, `socketpair`, `accept4`, `sendmsg`/`recvmsg`, `sendmmsg`/`recvmmsg`, fd passing;
- IPC: SysV shared memory, SysV semaphores, SysV message queues, POSIX message queues, eventfd, epoll, timerfd, inotify;
- runtime probes: `rseq`, `memfd_create`, `openat2`, `faccessat2`, `preadv2`, `pwritev2`, `process_vm_readv`, `process_vm_writev`, and quiet fallback stubs for remaining modern optional probes.

## Known syscall gaps and likely priority

These are not blocking the current smoke set, but they frame the next coverage work:

| Priority | Gap | Why it matters |
|---|---|---|
| Closed for smoke scope | OpenJDK mixed-mode compiler/JIT | Default mixed-mode `java -version`, `javac Hello.java`, `java Hello`, and Java-equivalent Benchmarks Game pass after the `LDPSW` pair-load fix; keep larger HotSpot/JIT stress workloads as future expansion. |
| Closed | SysV semaphores: `semget`, `semctl`, `semop`, `semtimedop` | Implemented and covered in staged runtime coverage. |
| Closed | `signalfd4` | Implemented and covered with blocked-signal delivery through a signalfd. |
| Closed | `memfd_create` | Implemented with anonymous realfs-backed temp fd semantics and covered with read/write/vector I/O. |
| Closed | `openat2`, `faccessat2` | Implemented for common no-`resolve` `openat2` and full `faccessat2` forwarding; covered in staged runtime coverage. |
| Closed | `preadv2`/`pwritev2` | Implemented for `flags == 0` fallback-equivalent semantics; covered in staged runtime coverage. |
| Closed | `process_vm_readv`/`process_vm_writev` | Implemented for permitted in-emulator task memory copies and covered for self-process copies. |
| Closed | POSIX message queues `mq_*` | Implemented enough named queue send/receive/attr/unlink semantics for runtime coverage. |
| Low/currently niche | AIO, `io_uring_*` | Currently quiet fallback works for Node/Bun/npm; true support is a larger subsystem. |
| Low/currently niche | namespaces, keyrings, fanotify, perf, bpf, seccomp, pkeys, NUMA policy | Important for container/security/profiling workloads, not for current language/runtime smoke. |
| Deliberately absent | kernel module, swap, reboot, mount-heavy privileged paths | Not expected to be meaningful inside this fakefs/user-mode emulator environment. |

## Appraisal

For userland development workloads, ARM64 iSH is now past the fragile bring-up phase. The strongest evidence is that the same fakefs can run package installs, C/C++ compilation, Go/Bun/Node/Python/PHP/Perl/Ruby/Lua runtime rows, Java in HotSpot default mixed mode plus interpreter fallback mode, GMP/PCRE/APR/Boost/TBB-linked native code, `fork()` plus SysV IPC, and the go-gte numerical workload.

The remaining risk is now concentrated less in common development syscalls and more in larger optional subsystems: `io_uring`, AIO, namespace/security/profiling APIs, and larger HotSpot/JIT stress workloads beyond the current smoke lane. The highest-value incremental syscall and signal-runtime gaps identified earlier have been closed and are now part of staged runtime coverage.

## 2026-05-04 high-value syscall gap closure

Implemented and validated in `/workspace/tmp/ish-arm64-runtime-coverage-20260505-102146.md`:

- `signalfd4`
- SysV semaphores: `semget`, `semctl`, `semop`, `semtimedop`
- POSIX message queues: `mq_open`, `mq_unlink`, `mq_timedsend`, `mq_timedreceive`, `mq_notify`, `mq_getsetattr`
- `memfd_create`
- `openat2` / `faccessat2`
- `preadv2` / `pwritev2` with `flags == 0`
- `process_vm_readv` / `process_vm_writev`

The staged runtime suite now has a dedicated C fixture named `high-value syscall gaps` that compiles and executes these paths inside the guest, plus UDP loopback and socket option length/buffer checks.

## 2026-05-04 OpenJDK DC ZVA closure

OpenJDK 21 startup now passes after ARM64 iSH reports `DCZID_EL0 == 4` (64-byte DC ZVA block) and implements `dc zva` as a 64-byte naturally aligned zeroing operation. The staged runtime suite includes `arm64 DC ZVA sysreg/instruction`, and `/workspace/tmp/benchmarksgame-java-equivalent-smoke-20260505-102308.md` shows the Java-equivalent Benchmarks Game probe passing **10 / 10** under `-Xint -Xshare:off`.

2026-05-08 update: default mixed-mode `java -version`, `javac Hello.java`, `java Hello`, and the Java-equivalent Benchmarks Game smoke now pass after fixing ARM64 `LDPSW` pair-load sign extension. Keep larger HotSpot/JIT workloads in the regression matrix, but the previous default `javac` smoke blocker is closed.

## 2026-05-04 ARM64 signal ucontext / null-SIGSEGV correction

HotSpot uses guest SIGSEGV handlers for implicit null checks. ARM64 iSH now:

- aligns the ARM64 signal extension area to 16 bytes, matching Linux/musl `mcontext_t`;
- places `ucontext_t.uc_mcontext` at offset **176**;
- stops synthesizing zero-valued loads for null-page read faults (`addr < 0x1000`) and delivers those faults to guest handlers instead.

The staged runtime suite includes `arm64 signal ucontext layout`, which intentionally dereferences null under a `SA_SIGINFO` handler and verifies the handler sees the expected PC/SP/LR context.

2026-05-08 update: the later default mixed-mode `javac` blocker is closed by the ARM64 `LDPSW` pair-load sign-extension fix. Keep larger HotSpot/JIT stress workloads beyond the current smoke lane as future expansion.

## 2026-05-04 ARM64 CCMP/CCMN condition-code correction

AArch64 conditional compare instructions (`CCMP`/`CCMN`) treat condition code 15 (`NV`) as condition-true, matching `AL` behavior for these instructions on hardware. ARM64 iSH previously treated `NV` as false and loaded the immediate NZCV fallback. The staged runtime suite now includes `arm64 CCMP/CCMN NV condition`, covering both subtract and add conditional-compare forms plus a false-condition NZCV fallback check.

This is an ARM64 ISA correctness fix found while narrowing the OpenJDK mixed-mode lane. The later default mixed-mode `javac` blocker was closed separately by the ARM64 `LDPSW` pair-load sign-extension fix.

## 2026-05-05 ARM64 self-modifying-code invalidation

Guest stores now mark the last written page dirty, and the ARM64 asbestos loop invalidates compiled fiber blocks for that page at block boundaries. This closes a stale-translation bug for JIT/code-patching workloads: a guest can execute code from an RWX page, patch the instructions, then branch back through the same address and receive freshly translated bytes.

The staged runtime suite includes `arm64 self-modifying code invalidation`, which executes a tiny `mov w0,#1; ret` function from an RWX page, patches it to `mov w0,#2; ret`, and verifies the second indirect call returns `2`. This is necessary production groundwork for HotSpot nmethod/inline-cache patching.

## 2026-05-05 ARM64 generic read-fault recovery disabled

The broad ARM64 fallback that synthesized zero for a small number of non-null unmapped read faults is now compile-time gated behind `ENABLE_ARM64_READ_FAULT_RECOVERY` and disabled in production builds. It was useful as a diagnostic compatibility shim, but it can hide real emulator/runtime bugs and corrupt compiler/JIT state by turning bad pointers into null-like values. HotSpot mixed-mode debugging now sees the real guest `SIGSEGV` path instead of a synthesized zero load.

## 2026-05-05 ARM64 fault diagnostics gated

Noisy ARM64 fault diagnostics (`page fault ...`, register dumps, block instruction dumps, and `SIGNAL_TRACE`) are now quiet by default in production builds. Set `ISH_TRACE_FAULTS=1` when debugging guest fault delivery or JIT crashes. This keeps expected guest signal paths, including HotSpot implicit null checks, from spamming stderr while preserving an opt-in diagnostic path.

## 2026-05-10 ARM64 barrier synchronization correction

ARM64 iSH now keeps guest barrier classes distinct at translation time: `DMB` emits a host `dmb`, `DSB` emits a host `dsb`, and `ISB` emits a host `isb`. Because the current decoder folds all CRm shareability/domain variants into one gadget per barrier class, the `DMB` and `DSB` gadgets use the strongest host `sy` domain so guest `SY`/`LD`/`ST` forms are not under-serialized.

The staged runtime suite includes `arm64 barriers DMB/DSB/ISB`, which compiles and executes common barrier encodings (`dmb sy`, `dmb ish`, `dmb ishld`, `dmb ishst`, `dsb sy`, `dsb ish`, and `isb`) inside the guest. Latest staged coverage is `/workspace/tmp/ish-arm64-runtime-coverage-20260513-203532.md` with **49 / 49 passing**.

## 2026-05-12 production audit hardening

The post-production code-smell/logic audit fixed several low-risk but concrete robustness issues outside the ARM64 instruction core:

- `kernel/log.c` now uses bounded `vsnprintf()` for `printk`/`die` formatting instead of unbounded `vsprintf()`.
- `fs/mount.c` now parses comma-separated mount option flags as exact tokens and advances past commas correctly, avoiding prefix matches and an infinite-loop edge case.
- Initial launch argument construction in `xX_main_Xx.h` is bounds-checked before copying argv entries and injected Node flags into the fixed-size startup buffer.
- ELF `PT_INTERP` loading in `kernel/exec.c` now rejects empty/oversized interpreter names, checks short reads safely, and explicitly NUL-terminates the path before opening it.
- Shebang optional-argument trimming no longer walks before the argument string when there is no optional argument.
- `tools/ptraceomatic.c` now constructs `TERM=...` directly instead of reading memory before the pointer returned by `getenv("TERM")`.

Validation after these changes: `make build-arm64-linux-all`, staged runtime coverage **28 / 28 passing** (`/workspace/tmp/ish-arm64-runtime-coverage-20260512-181051.md`), and default mixed-mode Java Hello (`/workspace/tmp/java-hello-audit-r5-20260512.log`, `javac_rc:0`, `java_rc:0`).

## 2026-05-13 runtime coverage expansion and cleanup fixes

The staged runtime suite now includes additional language/toolchain smoke or availability coverage and validates **49 / 49 passing** in `/workspace/tmp/ish-arm64-runtime-coverage-20260513-203532.md`:

- Python/Lua: version and eval smoke.
- Java/Clojure: default mixed-mode `javac`/`java`, Java interpreter fallback, and `clojure.main` eval smoke.
- PyPy/Swift: Alpine aarch64 availability probes record that neither toolchain is packaged in the current index.
- Rust: `rustc --version`, direct compile/run, optimized std runtime, `rustc --test`, and Cargo build/run/test execution covering threads, atomics, channels, file I/O, TCP loopback, and child processes, now without safety-valve or NETDIAG noise.
- Erlang: BEAM startup/version via `erl -version`, now without exit safety-valve leaks; fuller `erl -noshell`/`erlc` module execution remains a follow-up lane.
- Zig: `zig version`, `zig build-obj`, and linked object execution through a C harness. During this audit, Zig also exposed missing scalar FP16-to-FP64 conversion (`FCVT Dd,Hn`, instruction `0x1ee2c001`); the ARM64 generator now handles it alongside `FCVT Sd,Hn`. `zig test` remains outside the default gate pending Alpine Zig 0.15.2 compiler-rt `f16` comptime behavior.

This pass also fixed robustness issues exposed by the broader toolchain set: path normalization now bounds at-path and symlink expansion copies, stale path-normalization caching was removed so rapid symlink retargeting cannot resolve to an old target, normal blocking `recvfrom`/`recvmsg` paths no longer print stale `NETDIAG` debug lines in clean workload logs, socket receive paths now copy only the actual byte count and validate sockaddr lengths, `setsockopt`/`getsockopt` avoid guest-sized VLAs and respect returned lengths, Unix socket backing paths are bounded, failed Unix `bind()` cleanup clears released name references, blocking realfs/socket read paths surface guest signals instead of retrying all host `EINTR`s, and `exit_group` waits long enough for helper threads to observe shutdown cleanly.
