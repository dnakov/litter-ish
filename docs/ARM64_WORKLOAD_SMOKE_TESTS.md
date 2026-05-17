# ios-linuxkit workload smoke tests

Updated: 2026-05-17

This file lists workload-level tests that sit above the core runtime gate. Each row should be reproducible from the Linux-host harness and should produce a bounded pass/fail/unsupported report.

## Workload matrix

| Workload | Status | Why it exists | Report / details |
|---|---:|---|---|
| Core runtime coverage | **83 / 83 passing** | Fast regression gate for startup, package manager, syscall ABI, ARM64 fixtures, and language smoke rows. | `/workspace/tmp/ish-arm64-runtime-coverage-20260517-130725.md`; [runtime validation](RUNTIME_VALIDATION.md) |
| CLI corner cases | **27 pass / 2 unsupported / 0 fail** | TUI, DNS/HTTPS, Git clone, Docker diagnostics, ptrace/netlink visibility, Unix tooling. | `/workspace/tmp/ish-arm64-cli-corner-smoke-20260516-223418.md` |
| npm CLI package lane | **16 / 16 passing** | Startup/help/version probes for fast-moving npm CLI packages. | `/workspace/tmp/ish-arm64-cli-package-runtime-coverage-20260515-200605.md` |
| Node/Bun timing | **10 / 10 passing** | Startup/eval/JSON/FS timings for executor work. | Latest prechain promotion pair: `/workspace/tmp/ish-arm64-node-bun-perf-20260517-130454.md`, opt-out `/workspace/tmp/ish-arm64-node-bun-perf-20260517-130528.md` |
| Bun workspace/server | Install/start/listen passing | JS workspace install, recursive copies, JSC behavior, HTTP serving. | internal workload log |
| `rcarmo/go-gte` | Convert/test/run passing | Go toolchain, Python model conversion, 128 MB model I/O, FP16/NEON paths. | [GO_GTE_PROGRESS.md](GO_GTE_PROGRESS.md) |
| Benchmarks Game | 10/10 rows for selected runtimes | Cross-language compile/runtime corpus. | [BENCHMARKSGAME_HARNESS.md](BENCHMARKSGAME_HARNESS.md), [BENCHMARKSGAME_MATRIX.md](BENCHMARKSGAME_MATRIX.md) |

## Commands

| Workflow | Command |
|---|---|
| Core runtime | `make test-arm64-runtime-coverage REPORT_DIR=/workspace/tmp TIMEOUT_S=180 INSTALL_TIMEOUT_S=1200` |
| CLI corner cases | `make test-arm64-cli-corner-smoke ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=240 INSTALL_TIMEOUT_S=1200` |
| npm CLI package lane | `make test-arm64-npm-cli-runtime-coverage ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=180 INSTALL_TIMEOUT_S=1800` |
| Node/Bun timing | `make test-arm64-node-bun-perf ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=180`; add `ISH_ARM64_BLOCK_STATS=1 ISH_ARM64_HOT_TRACE=1` only for opt-in Phase 4 diagnostics. |
| Benchmarks Game matrix | `tests/arm64/benchmarksgame/generate-matrix.py` |

## CLI corner-case coverage

| Area | Rows / notes |
|---|---|
| TUI | `htop` and `btop` run inside detached `tmux` sessions and exit through explicit key paths. |
| DNS/HTTPS | `curl https://github.com`, `git ls-remote`, and a shallow `rcarmo/go-gte` clone cover c-ares/libcurl and Git. |
| Docker | CLI and `dockerd --version` pass. Daemon startup and `hello-world` are `UNSUPPORTED` when namespaces/cgroups/mount behavior are absent. |
| Diagnostics | `strace` keeps the known `PTRACE_SETOPTIONS` limitation visible; `iproute2` accepts explicit AF_NETLINK-unavailable diagnostics. |
| Availability | `nushell`, `xonsh`, `tcpdump`, `bind-tools`, `jq`, Linuxbrew rows report package availability rather than failing silently. |

## npm CLI package lane

| Area | Notes |
|---|---|
| Packages | Fast-moving npm/pip CLI packages with unauthenticated startup/help/version paths. |
| Scope | Unauthenticated install/startup/help/version probes only. |
| Reason for separate lane | These packages change too often for the stable runtime gate. |
| Known limit | Debian/glibc lane is still blocked by thread/libuv assertions. |

## Benchmarks Game rows

| Row | Status | Report |
|---|---:|---|
| GCC | 10/10 build, 10/10 run | [BENCHMARKSGAME_GCC_SMOKE.md](BENCHMARKSGAME_GCC_SMOKE.md) |
| G++ | 10/10 build, 10/10 run | [BENCHMARKSGAME_GPP_SMOKE.md](BENCHMARKSGAME_GPP_SMOKE.md) |
| Go | 10/10 | [BENCHMARKSGAME_GO_SMOKE.md](BENCHMARKSGAME_GO_SMOKE.md) |
| Python | 10/10 | [BENCHMARKSGAME_PYTHON_SMOKE.md](BENCHMARKSGAME_PYTHON_SMOKE.md) |
| Node.js | 10/10 | [BENCHMARKSGAME_NODE_SMOKE.md](BENCHMARKSGAME_NODE_SMOKE.md) |
| PHP | 10/10 | [BENCHMARKSGAME_PHP_SMOKE.md](BENCHMARKSGAME_PHP_SMOKE.md) |
| Perl | 10/10 | [BENCHMARKSGAME_PERL_SMOKE.md](BENCHMARKSGAME_PERL_SMOKE.md) |
| Ruby | 10/10 | [BENCHMARKSGAME_RUBY_SMOKE.md](BENCHMARKSGAME_RUBY_SMOKE.md) |
| Lua | 10/10 | [BENCHMARKSGAME_LUA_SMOKE.md](BENCHMARKSGAME_LUA_SMOKE.md) |
| Java equivalent | 10/10 mixed mode and `-Xint` fallback | [BENCHMARKSGAME_JAVA_EQUIVALENT_SMOKE.md](BENCHMARKSGAME_JAVA_EQUIVALENT_SMOKE.md) |

## Runtime bugs these workloads exposed

| Workload | Fixes covered |
|---|---|
| Bun workspace/server | ARM64 memory-fault retry, JSC GC/timer shims, `REV16`, `getdents64` `d_type`. |
| go-gte | AdvSIMD `FCVTL`/`FCVTL2`; Go test/run coverage for model I/O. |
| Python Benchmarks Game | Startup creation of `/dev/shm` for `multiprocessing.SemLock`. |
| Go Benchmarks Game | `wait4` polling timeout behavior; per-thread `sigaltstack`. |
| PHP Benchmarks Game | SysV shared memory and message queues across `fork()`. |
| Ruby Benchmarks Game | Poll safety valve now checks all threads before firing. |
| Java equivalent | `DCZID_EL0`/`dc zva`; `LDPSW` pair-load sign extension. |
| CLI corner cases | UDP `recvfrom()` now accepts oversized source-address buffers for c-ares/libcurl DNS. |

## Feasibility ledger

| Class | Examples | State |
|---|---|---|
| Ready rows | `gcc`, `gpp`, Go, Python, Node, PHP, Perl, Ruby, Lua | Run as repeatable smoke rows. |
| Ready but large | Rust, Erlang, GHC, OCaml, SBCL, Racket, GNAT | Package availability is known; promote only with time-budgeted harnesses. |
| Partial / external | C# NativeAOT, F#/.NET, GraalVM | Require opt-in SDK/toolchain work. |
| Blocked on Alpine aarch64 packaging | Chapel, Dart, Free Pascal, Intel Fortran, Julia, Pharo, Swift | Kept in the matrix as unsupported rather than skipped. |

## Harness rules

- Use bounded inputs and timeouts.
- Record pass, fail, or unsupported explicitly.
- Include enough detail to reproduce the row: command, package/toolchain state, report path, and diagnostic excerpt.
- Do not patch benchmark source to hide runtime bugs; skip architecture-specific variants and record why.
