# iSH ARM64 bring-up fork

This repository is an ARM64 bring-up fork of [iSH](https://ish.app/) focused on making an AArch64 Linux guest practical enough to run modern language runtimes and build tools on ARM64 hosts.

The upstream/original README has been preserved as [ORIGINAL_README.md](ORIGINAL_README.md). The deeper ARM64 technical notes are in [README_arm64.md](README_arm64.md).

## What we have been doing

We have been progressively hardening the ARM64 guest backend and replacing ad-hoc smoke tests with repeatable coverage. The current work is centered on the Linux-host harness in this repo, using the Alpine ARM64 fakefs root and the threaded-code Asbestos ARM64 backend.

### Build and harness work

- Added a top-level `Makefile` that captures the local Linux bring-up flow:
  - `make build-arm64-linux`
  - `make build-arm64-linux-debug`
  - `make build-arm64-linux-all`
  - `make test-arm64-runtime-coverage`
  - `make test-arm64-runtime-coverage-debug`
- Added `tests/arm64/runtime-coverage.sh`, a staged coverage gate for:
  - base shell, `apk`, tmp file I/O
  - C compile and execute
  - SysV IPC and high-value syscall gaps
  - ARM64 ISA/runtime fixtures: DC ZVA, signal `ucontext_t`, per-thread `sigaltstack`, CCMP/CCMN `NV`, DMB/DSB/ISB barriers, and self-modifying-code invalidation
  - Go compile/run/build/test
  - Bun install/run/test/build
  - Node/npm version/eval/run
  - Python and Lua version/eval smoke
  - Java default mixed-mode and interpreter fallback smoke
  - Clojure `clojure.main` eval smoke
  - PyPy and Swift Alpine aarch64 availability probes
  - Rust `rustc` compile/run/optimized-std/unit-test plus Cargo build/run/test smoke
  - Erlang BEAM version smoke
  - Zig object build/link/run smoke
- Added a Linux SDL/VNC terminal harness for interactive guest debugging:
  - `tools/ish_sdl_vnc.c`
  - `tools/run-sdl-vnc.sh`
- Documented Linux-host ABI details in [docs/LINUX_BUILD_AND_HOST_ABI.md](docs/LINUX_BUILD_AND_HOST_ABI.md).

### Platform separation

Host OS differences are being moved behind `platform/platform.h` with one implementation per host under `platform/`:

- `platform/linux.c`
- `platform/darwin.c` for macOS/iOS-family hosts

The current split centralizes FD-path lookup, stat timestamp fields, host random bytes, thread naming, host `sysinfo`, per-thread CPU usage, and memory-pressure hooks so core emulator/kernel code no longer needs direct `__linux__`/`__APPLE__` branches for those details.

### Emulator/runtime fixes so far

- Fixed stale threaded-code/TLB invalidation paths around mapping and exec transitions.
- Made ARM64 JIT memory-fault retry precise: faultable load/store gadgets now record the current guest PC, and async SIGSEGV/SIGBUS plus TLB/cross-page INT_GPF exits retry at that instruction instead of the containing block start. This fixed the Bun/JSC freelist corruption where `4897440: str x10, [x11]` could restart at `4897430: madd x11, x1, x11, x1` with `x11` already clobbered to the loop pointer.
- Added conservative JavaScriptCore runtime shims for the ARM64 guest (`JSC_numberOfGCMarkers=1`, `JSC_useConcurrentGC=0`) so Bun avoids multi-marker/concurrent GC signal and timer interactions that can spin forever under syscall/gadget-boundary signal delivery. GC remains enabled, but marker count and concurrent GC are constrained.
- Corrected ARM64 signal details found while tracing that hang: `siginfo_t` now keeps the 64-bit Linux padding before `_sifields`, `tkill`/`tgkill` report `SI_TKILL`, and syscall 240 is no longer miswired to `rt_sigreturn`.
- Fixed `getdents64` directory-entry type reporting. Bun's recursive `fs.cpSync()` depends on `d_type`; returning `DT_UNKNOWN` for directories made it attempt a file copy on subdirectories and throw `ENOTSUP: operation not supported on socket, copyfile` during PiClaw workspace bootstrap.
- Added ARM64 syscall coverage and quiet fallback stubs for modern runtime probes such as `rseq` and `io_uring_*`.
- Implemented ARM64 `preadv`/`pwritev` syscall wiring, removing noisy Node/npm fallback stubs.
- Fixed lazy `MAP_NORESERVE` reservation permissions so later `mprotect()` calls update reservation metadata before demand faults materialize pages.
- Re-enabled valid high ARM64 mmap hints within the 48-bit guest address space, which is required by modern JS runtimes that derive heap/cage pointers from returned mappings.
- Prefer the high 48-bit address space for large anonymous `MAP_NORESERVE` arenas so Bun/JSC/V8 do not exhaust the low 4GB mmap window.
- Fixed pair-exclusive `STXP/STLXP` state handling so the standalone 64-bit and 32-bit LDXP/STLXP atomic repros now pass.
- Added `CASP`/128-bit compare-exchange decode/helper plumbing; the standalone CAS128 repro now passes.
- Fixed ARM64 `CLREX` semantics: it now clears both single and pair exclusive monitor state instead of acting as a NOP, so post-`CLREX` `STXR`/`STXP` correctly fail.
- Added small atomic repro sources under `tests/arm64/atomics/` for LDXP/STLXP, CAS128, and CLREX+STXR/STXP semantics.
- Stopped advertising optional ARM64 crypto/LSE features in `AT_HWCAP` until those helper sets are fully coverage-clean; runtimes can fall back to baseline FP/ASIMD paths.
- Hardened production-adjacent launch and logging paths found during the final audit: bounded `printk`/`die` formatting, exact comma-separated mount-option parsing, bounded initial argv construction, safe `PT_INTERP` path loading, safe shebang argument trimming, and safe `TERM` environment construction in `ptraceomatic`.
- Added bounded path/symlink expansion checks, removed stale path-normalization caching, hardened socket address/option/receive buffer handling, added guest-signal-aware `EINTR` surfacing for blocking read/write/socket paths, and kept a longer exit-group drain window so runtime helper threads can unwind without safety-valve leaks.
- Extended user-readable ARM64 sysreg probes (`MIDR_EL1`, zero-valued feature/debug ID registers) and scalar FP16 conversion (`FCVT Sd,Hn` / `FCVT Dd,Hn`) for modern compiler/runtime CPU-feature paths.

## Current coverage status

Latest staged runtime report: **49 / 49 passing** (`/workspace/tmp/ish-arm64-runtime-coverage-20260513-203532.md`, `TIMEOUT_S=180`, `INSTALL_TIMEOUT_S=300`). Base shell/APK, C, SysV IPC, high-value syscall gap plus UDP/socket-option coverage, ARM64 DC ZVA coverage, ARM64 signal-ucontext and per-thread `sigaltstack` coverage, ARM64 CCMP/CCMN NV-condition coverage, ARM64 DMB/DSB/ISB barrier coverage, ARM64 self-modifying-code invalidation coverage, Go, Bun, Node/npm, Python, Lua, Java, Clojure, PyPy/Swift availability probes, Rust, Erlang, and Zig are green in the Linux-host coverage harness. The current production package baseline is recorded in [docs/ARM64_PRODUCTION_BASELINE.md](docs/ARM64_PRODUCTION_BASELINE.md), and the local Linux production deployment/post-deploy Java smoke is recorded in [docs/ARM64_PRODUCTION_DEPLOYMENT.md](docs/ARM64_PRODUCTION_DEPLOYMENT.md).

| Area | Status | Notes |
|---|---:|---|
| Base shell / apk / tmp I/O | Passing | Basic guest execution and filesystem operations are stable. |
| C toolchain | Passing | `gcc` can compile and execute a simple program. |
| SysV IPC / socket ABI | Passing | Shared memory and message queues work across `fork()`; staged syscall coverage also validates UDP `sendto`/`recvfrom`, `getsockname`, `setsockopt`, and `getsockopt` buffer/length handling. |
| ARM64 DC ZVA | Passing | `DCZID_EL0` reports a 64-byte block and `dc zva` zeros the expected aligned block. |
| ARM64 signal ucontext | Passing | Guest SIGSEGV handlers now see Linux/musl-compatible `ucontext_t` (`uc_mcontext` offset 176), and null read faults are delivered instead of synthesized as zero loads. |
| ARM64 CCMP/CCMN NV | Passing | Conditional compare now treats condition code 15 (`NV`) like AArch64 hardware does for these instructions: condition true, not false-immediate fallback. |
| ARM64 barriers | Passing | Guest `DMB`, `DSB`, and `ISB` decode to distinct host synchronization gadgets; folded CRm domains use conservative full-system host barriers. |
| ARM64 self-modifying code | Passing | Guest writes to previously translated code pages invalidate stale translated blocks at block boundaries; required for JIT/code-patching workloads. |
| Java/OpenJDK | Passing default mixed-mode smoke | OpenJDK 21.0.10 starts; default mixed-mode `javac Hello.java`/`java Hello` and `-Xint` interpreter fallback pass; Java-equivalent Benchmarks Game passes 10/10 in default mixed mode. |
| Go | Passing | `go version`, `go env`, `go tool compile`, `go run`, `go build`, `go test`, and Benchmarks Game Go 10/10 pass; per-thread `sigaltstack` handling now matches Linux for Go signal stacks. |
| Node/npm | Passing | `node -e`, `npm --version`, and `npm run` pass after mmap/reservation and `pwritev` fixes. |
| Bun | Passing | `bun --version`, local `file:` dependency install, TypeScript run, `bun test`, and `bun build` all pass in the staged harness. |
| Python / Lua / Clojure | Passing smoke | `python3 --version`/eval, `lua5.4 -v`/eval, and `clojure.main` eval pass in the staged harness. |
| PyPy / Swift | Accounted for | Availability probes pass by documenting that Alpine 3.23 aarch64 has no packaged PyPy or Swift toolchain in the current index. |
| Rust | Passing | `rustc --version`, direct compile/run, optimized std runtime, `rustc --test`, Cargo build/run/test, threads, atomics, channels, file I/O, TCP loopback, and child process coverage pass without safety-valve or NETDIAG noise. |
| Erlang | Passing version smoke | Alpine's BEAM package starts cleanly for `erl -version`; fuller `erl -noshell`/`erlc` module execution remains a follow-up lane. |
| Zig | Passing | `zig version`, `zig build-obj`, and linking the Zig object into a C harness all pass. The gate avoids `zig test` because Alpine Zig 0.15.2 currently fails compiler-rt `f16` comptime compilation before guest code runs. |

## Bun status snapshot

The previous Bun local `file:` install allocator/free-list failure is fixed. The root cause was imprecise ARM64 JIT memory-fault retry: a fault in the freelist-fill store at `0x4897440` could restart the block at `0x4897430` after `x11` had already been repurposed as the loop pointer, producing a huge bogus `next` pointer. The current fix records a precise retry PC before each load/store and uses it for async host faults and TLB/cross-page memory-fault exits.

The follow-on `bun -e`, TypeScript run, `bun test`, timer, and `Bun.serve` hangs were narrowed to JavaScriptCore GC interactions. JSC uses signal handlers plus `sem_post`/`sigsuspend` to stop marker threads, and concurrent GC can block timer-driven event-loop progress under iSH's syscall/gadget-boundary signal delivery. The current runtime shim injects `JSC_numberOfGCMarkers=1` and `JSC_useConcurrentGC=0` for ARM64 guest processes, which keeps GC enabled while avoiding those parallel/concurrent paths.

Validated so far:

- `make build-arm64-linux-all` passes.
- 50 consecutive minimal Bun local `file:` install repro runs passed (`RC:0`).
- 20 consecutive `bun -e "console.log(1)"` repro runs passed.
- `setTimeout`, a minimal `Bun.serve` + `wget`, and PiClaw's web server now respond inside the guest.
- PiClaw workspace bootstrap no longer logs the `ENOTSUP ... copyfile` warning when seeding `.pi/skills`.
- Staged runtime coverage is now **49 / 49 passing**, including SysV shared-memory/message-queue IPC, high-value syscall gap plus UDP/socket-option coverage, ARM64 DC ZVA coverage, ARM64 signal-ucontext and per-thread `sigaltstack` coverage, ARM64 CCMP/CCMN NV-condition coverage, ARM64 DMB/DSB/ISB barrier coverage, ARM64 self-modifying-code invalidation coverage, plus Bun install, TypeScript run, test, and build, and Python/Lua/Java/Clojure/PyPy/Swift/Rust/Erlang/Zig smoke or availability coverage.

## Workload smoke tests

The current non-trivial workload results are grouped in [docs/ARM64_WORKLOAD_SMOKE_TESTS.md](docs/ARM64_WORKLOAD_SMOKE_TESTS.md). That document explains why each workload was chosen, records the latest results, and tracks the next test case.

Current highlights:

- staged runtime coverage is **49 / 49 passing**;
- Bun + PiClaw now install/start far enough to serve the web UI and no longer hit the recursive `copyfile`/`ENOTSUP` bootstrap issue;
- `rcarmo/go-gte` can now build, convert `gte-small.gtemodel` inside the guest, and complete `make run-go`; this exposed and fixed missing AdvSIMD `FCVTL`/`FCVTL2` support;
- the Benchmarks Game core tier now has GCC, G++, Go, Python, Node.js, PHP, Perl, Ruby, and Lua rows passing, and the local Java-equivalent probe now passes 10/10 in HotSpot default mixed mode; all official language labels remain accounted for and tiered by Alpine aarch64 feasibility.

Detailed go-gte repro notes remain in [docs/GO_GTE_PROGRESS.md](docs/GO_GTE_PROGRESS.md).

## Quick start

```bash
make build-arm64-linux-all
make test-arm64-runtime-coverage REPORT_DIR=/workspace/tmp TIMEOUT_S=90 INSTALL_TIMEOUT_S=900
```

The coverage suite is now green on this Linux host. Keep it as the regression gate for future ARM64 backend/runtime changes.
