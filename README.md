# iSH ARM64 bring-up fork

This repository is an ARM64 bring-up fork of [iSH](https://ish.app/) focused on making an AArch64 Linux guest practical enough to run modern language runtimes, compilers, package managers, and real workload smoke tests on ARM64 hosts.

The upstream/original README is preserved as [ORIGINAL_README.md](ORIGINAL_README.md). Deeper ARM64 implementation notes are in [README_arm64.md](README_arm64.md), workload status is tracked in [docs/ARM64_WORKLOAD_SMOKE_TESTS.md](docs/ARM64_WORKLOAD_SMOKE_TESTS.md), and the executor speedup roadmap is tracked in [docs/ARM64_GADGET_FUSION_PLAN.md](docs/ARM64_GADGET_FUSION_PLAN.md).

## Current validation baseline

Latest staged runtime report: **49 / 49 passing**

- Report: `/workspace/tmp/ish-arm64-runtime-coverage-20260515-132014.md`
- Binary: `build-arm64-linux/ish`
- Rootfs: `alpine-arm64-fakefs`
- Timeout: `TIMEOUT_S=180`
- Install timeout: `INSTALL_TIMEOUT_S=300`
- `SAFETY-VALVE` diagnostics in report: **0**
- `NETDIAG` diagnostics in report: **0**

AI CLI runtime coverage is tracked as a separate second-stage suite because it installs fast-moving agent packages and should not contaminate the stable 49-test core gate. Latest Alpine npm-only report: **16 / 16 passing** at `/workspace/tmp/ish-arm64-ai-cli-runtime-coverage-20260515-200605.md`, now including the community `grok-cli` Grok/xAI proxy wrapper. The Claude Code standalone Bun binary crash was traced to high-address `MAP_NORESERVE` reservation overlap; high-hole allocation and alignment are now reservation-aware. Debian AI CLI remains a background lane while glibc thread creation is still blocked by `pthread_create()`/libuv assertions.

This README reflects the validation sequence after tagged point `arm64-openjdk21-prod-20260513-r6`, including the later Rust/Cargo and socket ABI audit fixes, lane-aware runtime coverage, `fchmodat2(AT_EMPTY_PATH)`, reservation-aware high-address `MAP_NORESERVE` handling, and the separate AI CLI coverage harness.

## Quick start

Build both Linux ARM64 variants:

```bash
make build-arm64-linux-all
```

Run the staged runtime coverage gate (defaults to all configured lanes; use `ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs` for the current Alpine-only baseline):

```bash
make test-arm64-runtime-coverage REPORT_DIR=/workspace/tmp TIMEOUT_S=180 INSTALL_TIMEOUT_S=300
```

Run the focused Node/Bun perf table before and after executor optimization work. Latest baseline: **10 / 10 passing** at `/workspace/tmp/ish-arm64-node-bun-perf-20260515-213520.md`. To include opt-in ARM64 peephole generation counters, set `ISH_ARM64_FUSION_STATS=1`; the first counter-enabled run is `/workspace/tmp/ish-arm64-node-bun-perf-20260515-214650.md`. The table now validates expected Node/Bun output as well as exit status; the first `ADD/SUB + CBZ/CBNZ` fusion run is `/workspace/tmp/ish-arm64-node-bun-perf-20260515-222649.md`.

```bash
make test-arm64-node-bun-perf ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=180
```

Run the separate AI CLI coverage suite:

```bash
make test-arm64-ai-cli-npm-runtime-coverage ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=180 INSTALL_TIMEOUT_S=1800
```

Useful overrides:

```bash
ISH_BIN=/path/to/ish \
ROOTFS=/path/to/alpine-arm64-fakefs \
REPORT_DIR=/workspace/tmp \
TIMEOUT_S=180 \
INSTALL_TIMEOUT_S=300 \
./tests/arm64/runtime-coverage.sh
```

A passing core run writes `ish-arm64-runtime-coverage-YYYYMMDD-HHMMSS.md` under `REPORT_DIR`. The suite is intentionally strict: a test is not considered passing if it has to be force-killed or if `SAFETY-VALVE` diagnostics appear in captured output. The AI CLI suite writes `ish-arm64-ai-cli-runtime-coverage-YYYYMMDD-HHMMSS.md` and is stricter about runtime diagnostics (`SAFETY-VALVE`, futex noise, V8/Bun crashes, page faults, and illegal-instruction traces all fail the row even when a package manager exits zero).

## Runtime coverage gate

`tests/arm64/runtime-coverage.sh` is the main fast regression gate for ARM64 backend/runtime work. It boots the Alpine ARM64 fakefs under the Linux-host iSH binary, installs missing guest packages as needed, pushes generated fixtures into `/tmp/runtime-coverage`, runs each test with a bounded timeout, and writes a Markdown result table.

### Coverage groups

| Stage | Tests | What it protects |
|---|---|---|
| `base` | shell execution, `apk`, tmp file I/O, symlink retarget normalization | Guest startup, package-manager basics, fakefs path behavior, and the removed stale path-normalization cache. |
| `c` | GCC version, compile/run, SysV shared memory/message queues, high-value syscall gaps, ARM64 ISA/runtime fixtures | Native compilation, process/IPC behavior, socket ABI, modern syscall probes, signal ABI, barriers, self-modifying code, and ARM64 instruction correctness. |
| `go` | `go version`, `go env`, `go tool compile`, `go run`, `go build`, `go test` | Go toolchain startup/codegen, module/test flow, signal-stack behavior, futex/thread scheduling, and larger mmap/runtime assumptions. |
| `bun` | `bun --version`, local `file:` dependency install, TypeScript run, `bun test`, `bun build` | JavaScriptCore allocation, high-address mmap reservations, timers, package install filesystem behavior, and JSC GC compatibility shims. |
| `node` | `node --version`, `node -e`, `npm --version`, `npm run` | V8/Node startup, npm process/filesystem paths, mmap reservation behavior, and quiet vector-I/O syscall coverage. |
| `python` / `lua` | version and eval smoke | Interpreted runtime startup, stdio, basic arithmetic/eval, and package availability assumptions. |
| `java` / `clojure` | `javac` + default mixed-mode `java`, `java -Xint`, `clojure.main` eval | OpenJDK startup, mixed-mode compiler/JIT smoke, interpreter fallback, signal/ucontext compatibility, and Clojure-on-JVM startup. |
| `pypy` / `swift` | Alpine aarch64 availability probes | Keeps unsupported toolchains explicit instead of silently skipping them. |
| `rust` | `rustc --version`, direct compile/run, optimized std runtime, `rustc --test`, Cargo build/run/test | Rust toolchain startup/codegen plus std coverage for threads, atomics, channels, file I/O, TCP loopback, and child processes. |
| `erlang` | `erl -version` | BEAM startup and helper-thread cleanup without exit safety-valve leaks. |
| `zig` | `zig version`, `zig build-obj`, C harness link/run | Zig frontend/object generation plus ARM64 object execution through a linked native harness. |

### C/syscall and ARM64 fixture details

The C stage is the broadest low-level coverage lane:

- **SysV IPC:** `shmget`/`shmat`/`shmdt`/`shmctl`, `msgget`/`msgsnd`/`msgrcv`/`msgctl` across `fork()`.
- **High-value syscall gaps:** `signalfd4`, SysV semaphores, POSIX message queues, `memfd_create`, `openat2`, `faccessat2`, `fchmodat2(AT_EMPTY_PATH)`, `preadv2`, `pwritev2`, `process_vm_readv`, and `process_vm_writev`.
- **Socket ABI:** UDP `sendto`/`recvfrom`, TCP `listen`/`accept`, `getsockname`, `setsockopt`, `getsockopt`, socketpair `sendmsg`/`recvmsg`, and ARM64 `SCM_RIGHTS` fd passing with guest `cmsghdr` layout validation.
- **ARM64 sysreg/instruction fixtures:** `DCZID_EL0`/`dc zva`, signal `ucontext_t`, per-thread `sigaltstack`, CCMP/CCMN condition-code-15 (`NV`), DMB/DSB/ISB barriers, and self-modifying-code invalidation.

### Rust fixture details

The Rust lane is now intentionally more than a `rustc hello.rs` smoke:

- standalone `rustc` compile/run with std collections
- optimized `rustc -O` std runtime program
- `rustc --test` unit tests
- Cargo build/run/test for a generated crate
- threads, atomics, mutexes, channels, file roundtrips, TCP loopback, and child process spawning

This makes Rust a useful proxy for pthread/futex behavior, socket blocking semantics, process spawning, file metadata, and toolchain codegen.

## Current coverage status

| Area | Status | Notes |
|---|---:|---|
| Base shell / apk / tmp I/O | Passing | Basic guest execution and filesystem operations are stable. |
| Path normalization | Passing | Rapid symlink retargeting resolves the new target; stale path-normalization caching was removed. |
| C toolchain | Passing | `gcc` can compile and execute generated fixtures. |
| SysV IPC / socket ABI | Passing | Shared memory/message queues work across `fork()`; staged coverage validates UDP/TCP socket options, `sendmsg`/`recvmsg`, and `SCM_RIGHTS` fd passing. |
| High-value syscall gaps | Passing | Modern runtime probes and IPC/syscall paths are implemented or have quiet fallback behavior where appropriate. |
| ARM64 DC ZVA | Passing | `DCZID_EL0` reports a 64-byte block and `dc zva` zeros the expected aligned block. |
| ARM64 signal ucontext | Passing | Guest SIGSEGV handlers see Linux/musl-compatible `ucontext_t`; null read faults are delivered to handlers. |
| Per-thread `sigaltstack` | Passing | Alternate signal stacks are per-task, matching Linux behavior needed by Go and other runtimes. |
| ARM64 CCMP/CCMN NV | Passing | Condition code 15 (`NV`) follows AArch64 hardware behavior for conditional compare instructions. |
| ARM64 barriers | Passing | `DMB`, `DSB`, and `ISB` decode to distinct synchronization gadgets with conservative folded domains. |
| ARM64 self-modifying code | Passing | Writes to translated code pages invalidate stale blocks before patched code is executed. |
| Go | Passing | `go tool compile`, `go run`, `go build`, `go test`, and Benchmarks Game Go 10/10 pass. |
| Bun | Passing | Local dependency install, TypeScript run, `bun test`, and `bun build` pass with current JSC compatibility shims. |
| Node/npm | Passing | `node -e`, `npm --version`, and `npm run` pass without the earlier noisy fallback stubs. |
| Python / Lua / Clojure | Passing | Version/eval smoke passes in the staged harness. |
| Java/OpenJDK | Passing | OpenJDK 21 default mixed-mode `javac`/`java`, `-Xint`, and Java-equivalent Benchmarks Game probe pass. |
| PyPy / Swift | Accounted for | Alpine 3.23 aarch64 currently has no packaged PyPy or Swift toolchain in the index. |
| Rust | Passing | Direct `rustc`, optimized std runtime, `rustc --test`, and Cargo build/run/test pass without safety-valve or NETDIAG noise. |
| Erlang | Passing | BEAM starts cleanly for `erl -version`; fuller module execution remains a follow-up lane. |
| Zig | Passing | `zig version`, `zig build-obj`, and linked object execution through a C harness pass; `zig test` is excluded pending Alpine Zig compiler-rt `f16` behavior. |

## Workload smoke tests beyond the staged gate

The staged gate is complemented by heavier workload probes documented under `docs/`:

- [ARM64_WORKLOAD_SMOKE_TESTS.md](docs/ARM64_WORKLOAD_SMOKE_TESTS.md) — overview and rationale for non-trivial workloads.
- [ARM64_SMOKE_ISSUES_AND_SYSCALL_COVERAGE.md](docs/ARM64_SMOKE_ISSUES_AND_SYSCALL_COVERAGE.md) — issue disposition and syscall coverage appraisal.
- [GO_GTE_PROGRESS.md](docs/GO_GTE_PROGRESS.md) — `rcarmo/go-gte` numerical/model-conversion workload.
- [BENCHMARKSGAME_MATRIX.md](docs/BENCHMARKSGAME_MATRIX.md) plus per-language `BENCHMARKSGAME_*_SMOKE.md` reports — Benchmarks Game rows.
- [ARM64_PRODUCTION_BASELINE.md](docs/ARM64_PRODUCTION_BASELINE.md) — current known-good package/rootfs/code baseline.

Current workload highlights:

- Benchmarks Game GCC, G++, Go, Python, Node.js, PHP, Perl, Ruby, and Lua rows pass **10/10** each.
- Java-equivalent Benchmarks Game probe passes **10/10** in default mixed mode and interpreter fallback mode.
- `rcarmo/go-gte` can build, convert `gte-small.gtemodel`, complete `go test -count=1 ./...`, and run `make run-go`.
- Bun/PiClaw install/start far enough to serve the web UI and no longer hit the recursive `copyfile`/`ENOTSUP` bootstrap issue.

## Major runtime fixes covered by the tests

The runtime gate and workload smokes cover the fixes that made the ARM64 guest practical:

- precise ARM64 JIT memory-fault retry for Bun/JSC allocator correctness
- JSC compatibility shims: `JSC_numberOfGCMarkers=1`, `JSC_useConcurrentGC=0`
- ARM64 signal ABI fixes (`siginfo_t`, `SI_TKILL`, correct syscall 240 handling)
- `getdents64` directory-entry type reporting
- ARM64 `preadv`/`pwritev` and `fchmodat2(AT_EMPTY_PATH)` syscall wiring
- high 48-bit mmap hints and high anonymous `MAP_NORESERVE` arenas, including reservation-safe high-hole alignment
- lazy `MAP_NORESERVE` permission updates on `mprotect()`
- LDXP/STLXP, CASP, CLREX, LDXR width, LDPSW, FP16 conversion, barrier, and self-modifying-code fixes
- bounded logging/launch/shebang/`PT_INTERP` handling
- bounded path/symlink expansion and removal of stale path-normalization caching
- guest-signal-aware blocking realfs/socket I/O and longer `exit_group` drain behavior
- socket address, option, receive, `sendmsg`/`recvmsg`, and ARM64 `SCM_RIGHTS` control-message hardening

## Build and platform notes

The Linux-host build flow is captured in the top-level `Makefile`:

- `make build-arm64-linux`
- `make build-arm64-linux-debug`
- `make build-arm64-linux-all`
- `make test-arm64-runtime-coverage`
- `make test-arm64-runtime-coverage-debug`

Host OS differences are being moved behind `platform/platform.h` with one implementation per host under `platform/`:

- `platform/linux.c`
- `platform/darwin.c`

The split currently centralizes fd-path lookup, stat timestamp fields, host random bytes, thread naming, host `sysinfo`, per-thread CPU usage, and memory-pressure hooks. Remaining host-specific socket/poll/native-offload branches are documented in [docs/LINUX_BUILD_AND_HOST_ABI.md](docs/LINUX_BUILD_AND_HOST_ABI.md).

A Linux SDL/VNC terminal harness is available for interactive guest debugging:

- `tools/ish_sdl_vnc.c`
- `tools/run-sdl-vnc.sh`

## Interpreting failures

When the staged runtime gate fails:

1. Open the generated Markdown report under `REPORT_DIR`.
2. Check the failing stage/test row and captured detail.
3. Treat `SAFETY-VALVE` output as a real failure, not a pass.
4. Treat unexpected `NETDIAG` in clean smoke logs as a regression signal unless the test is explicitly diagnostic.
5. Prefer adding a focused fixture to `tests/arm64/runtime-coverage.sh` when a runtime bug is fixed, so the regression remains covered.

## Immediate next cleanup candidates

- Run longer Bun/npm workloads to find the next post-coverage failure.
- Finish optional crypto/LSE helper validation before re-advertising those HWCAP bits.
- Revisit JSC parallel/concurrent GC suspension if the compatibility shims need to be removed.
- Continue moving host-specific socket/poll/native-offload branches behind platform helpers when a second call site or correctness issue justifies it.
