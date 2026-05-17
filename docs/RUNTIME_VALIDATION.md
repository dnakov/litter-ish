# ios-linuxkit runtime validation

This file describes the validation gates used before advertising a runtime change. It is a workflow reference, not a changelog.

## Baseline

| Item | Value |
|---|---|
| Core report | `/workspace/tmp/ish-arm64-runtime-coverage-20260517-092759.md` |
| Core result | **83 / 83 passing** |
| Binary | `build-arm64-linux/ish` |
| Rootfs | `alpine-arm64-fakefs` |
| Validation host | Orange Pi 6 Plus, CIX P1 (CD8180/CD8160), 12-core AArch64 |
| Host OS/kernel | Orange Pi 1.0.2 Trixie / Debian Trixie, Linux `6.6.89-cix` |
| Host toolchain | Clang 19.1.7, Meson 1.7.0, Ninja 1.12.1, GNU Make 4.4.1 |
| Timeouts | Latest Alpine gate used `TIMEOUT_S=120`, `INSTALL_TIMEOUT_S=1200`; broad/local gate command below keeps `TIMEOUT_S=180` for margin. |
| Required diagnostics | `SAFETY-VALVE=0`, `NETDIAG=0` in clean core logs |

Related docs: [workload smoke tests](ARM64_WORKLOAD_SMOKE_TESTS.md), [syscall coverage ledger](ARM64_SMOKE_ISSUES_AND_SYSCALL_COVERAGE.md), [executor plan](ARM64_GADGET_FUSION_PLAN.md).

## Gates

| Gate | Command | Expected output |
|---|---|---|
| Build | `make build-arm64-linux-all` | Linux ARM64 release/debug variants build. |
| Core runtime | `make test-arm64-runtime-coverage REPORT_DIR=/workspace/tmp TIMEOUT_S=180 INSTALL_TIMEOUT_S=1200` | Markdown report; current baseline **83 / 83**. |
| CLI corner cases | `make test-arm64-cli-corner-smoke ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=240 INSTALL_TIMEOUT_S=1200` | Current baseline **27 pass / 2 unsupported / 0 fail**. |
| npm CLI package lane | `make test-arm64-npm-cli-runtime-coverage ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=180 INSTALL_TIMEOUT_S=1800` | Current baseline **16 / 16**. |
| Node/Bun timing | `make test-arm64-node-bun-perf ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=180` | Timing/status table for executor changes. |

## Core coverage

| Stage | Covers | Regression class |
|---|---|---|
| `base` | Shell, `apk`, temporary files, symlink retargeting | Guest boot, package-manager basics, fakefs path behavior. |
| `c` | GCC compile/run, SysV IPC, syscall probes, sockets, ARM64 fixtures | Syscall ABI, signal ABI, instruction correctness, self-modifying-code invalidation. |
| `go` | `go version/env/tool compile/run/build/test` | Threads, futexes, signal stacks, large mappings, toolchain startup. |
| `bun` | Bun version, local install, TypeScript, tests, build | JavaScriptCore allocation, high mappings, timers, package filesystem behavior. |
| `node` | Node/npm version/eval/run | V8 startup, npm filesystem/process paths, mmap reservations. |
| `python` / `lua` | Version and eval rows | Interpreter startup and stdio. |
| `java` / `clojure` | `javac`, mixed-mode `java`, `java -Xint`, Clojure eval | JVM startup, ucontext/signal compatibility, interpreter fallback. |
| `rust` | `rustc`, optimized std, unit tests, Cargo build/run/test | Threads, atomics, channels, TCP loopback, child processes. |
| `erlang` / `zig` | BEAM version; Zig version/object/link/run | Runtime startup and generated object execution. |
| Availability rows | PyPy, Swift, C# NativeAOT SDK | Unsupported or opt-in toolchains remain explicit. |

## Low-level fixtures

| Area | Rows |
|---|---|
| IPC | SysV shared memory, SysV message queues, semaphores, POSIX message queues. |
| Modern syscalls | `signalfd4`, scheduler priority calls, `memfd_create`, `openat2`, `faccessat2`, `fchmodat2(AT_EMPTY_PATH)`, `preadv2`, `pwritev2`, `process_vm_readv`, `process_vm_writev`. |
| Sockets | UDP/TCP, socket options, `sendmsg`/`recvmsg`, ARM64 `SCM_RIGHTS`, oversized UDP `recvfrom()` source buffers. |
| ARM64 | `DCZID_EL0`/`dc zva`, signal `ucontext_t`, per-thread `sigaltstack`, CCMP/CCMN `NV`, DMB/DSB/ISB, self-modifying code. |

## Optional/diagnostic lanes

| Lane | Purpose | Current status |
|---|---|---|
| CLI corner cases | TUI tools, DNS/HTTPS, GitHub clone, Docker CLI/daemon diagnostics, `strace`, `lsof`, netlink visibility. | **27 pass / 2 unsupported / 0 fail**. Docker daemon/container rows are unsupported without container kernel primitives. |
| npm CLI package lane | Unauthenticated install/startup/help/version probes for npm-installed CLIs. | **16 / 16** in Alpine npm lane. Debian/glibc lane remains blocked by thread/libuv assertions. |
| Node/Bun perf | Timing table for executor changes and optional block/prechain/hot-trace statistics. | Use before/after dispatch optimization work; default reports must stay free of stats output. Latest default/gated Phase 4 pair: `/workspace/tmp/ish-arm64-node-bun-perf-20260517-092629.md` and `/workspace/tmp/ish-arm64-node-bun-perf-20260517-092700.md`, both **10 / 10**. |
| ARM64 executor diagnostics | `ISH_ARM64_BLOCK_STATS=1`, `ISH_ARM64_FUSION_STATS=1`, and dry-run `ISH_ARM64_HOT_TRACE=1` counters. | Opt-in only; do not run exact-output runtime coverage with these diagnostics because they intentionally write `ARM64_*_STATS` lines. Current hot-trace diagnostics are measurement-only and default-off: no trace builder, guarded exits, invalidation epoch changes, or generated-code behavior changes. |
| NativeAOT publish | Full `dotnet publish -p:PublishAot=true`. | Opt-in only via `ISH_ARM64_DOTNET_AOT_PUBLISH=1`; current focused probes stall in Roslyn `csc` after restore. |

## Failure rules

A row is not a pass when any of these happen:

1. The harness kills it for timeout.
2. `SAFETY-VALVE` appears in a clean runtime log.
3. Unexpected `NETDIAG`, page-fault, illegal-instruction, V8/Bun crash, or futex-noise diagnostics appear in a row that is not explicitly diagnostic.
4. A row is silently skipped instead of reported as passing, failing, or unsupported.

When fixing a runtime bug, add or update a focused row in the relevant harness so the failure stays covered.
