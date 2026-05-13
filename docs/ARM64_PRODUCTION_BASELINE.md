# ARM64 Production Baseline

Date: 2026-05-10
Reviewed: 2026-05-13

## Known-good code

- Code baseline: current `master` successor to `arm64-openjdk21-prod-20260510-r5`; this pass adds Rust/Erlang/Zig runtime coverage, Python/Lua/Java/Clojure/PyPy/Swift staged smoke/availability rows, ARM64 sysreg/FP16 conversion fixes, bounds-checked path/symlink expansion, and guest-signal-aware blocking I/O/exit cleanup.
- Previous tagged production audit baseline: `arm64-openjdk21-prod-20260510-r5` (post-production audit pass covering bounded logging, mount option parsing, exec/shebang argument safety, `PT_INTERP` bounds/NUL handling, and ptraceomatic `TERM` environment construction)
- Branch pushed: `master`
- Remote pushed: `https://github.com/rcarmo/ish-arm64.git`

## Host used for validation

- Board: Orange Pi 6 Plus
- SoC: CIX P1 (CD8180/CD8160), 12 CPU cores
- RAM: 16 GB class (about 14 GiB visible to Linux)
- Storage: NVMe root (`/dev/nvme0n1p2`)
- Host OS: Debian Linux (Trixie)
- Build target: ARM64 Linux iSH (`build-arm64-linux/ish`)

## Rootfs/package baseline

- Rootfs: `alpine-arm64-fakefs`
- Alpine release: `3.23.4`
- Guest architecture: `aarch64`
- OpenJDK packages:
  - `openjdk21-jdk-21.0.10_p7-r0`
  - `openjdk21-jre-headless-21.0.10_p7-r0`
  - `openjdk21-jmods-21.0.10_p7-r0`
- Java runtime:
  - `openjdk version "21.0.10" 2026-01-20`
  - `OpenJDK Runtime Environment (build 21.0.10+7-alpine-r0)`
  - `OpenJDK 64-Bit Server VM (build 21.0.10+7-alpine-r0, mixed mode, sharing)`
- `javac`: `21.0.10`
- Go: `go1.25.9-r0` (`go version go1.25.9 linux/arm64`)
- Node.js: `24.14.1-r0` (`v24.14.1`)
- Bun: `1.3.13`
- Python: `3.12.13`
- Lua: `5.4.8`
- Clojure: `1.12.3`
- Rust: `rustc 1.91.1` (Alpine `rust-1.91.1-r1`)
- Erlang: `erlang27-27.3.4.9-r0`, BEAM emulator `15.2.7.6`
- Zig: `0.15.2`
- GCC: `15.2.0-r2`
- musl: `1.2.5-r23`

## Validation artifacts

- Runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260513-203532.md`
  - Result: 49 / 49 passing
  - Includes no-safety-valve/no-NETDIAG Rust Cargo/std coverage, Erlang helper-thread cleanup validation, UDP/socket-option ABI coverage, and Python/Lua/Java/Clojure/PyPy/Swift/Rust/Erlang/Zig smoke or availability coverage.
- Go Benchmarks Game smoke: `/workspace/tmp/benchmarksgame-go-smoke-20260513-144802.md`
  - Result: 10 / 10 passing
- Default mixed-mode Java Hello smoke: `/workspace/tmp/java-hello-audit-r5-20260512.log`
  - `javac_rc:0`
  - `java_rc:0`
- Production baseline capture: `/workspace/tmp/ish-arm64-production-baseline-20260510.txt`
- Local production deployment/post-deploy smoke: [ARM64_PRODUCTION_DEPLOYMENT.md](ARM64_PRODUCTION_DEPLOYMENT.md)

## Production-readiness notes

- OpenJDK default mixed mode is enabled; no `-Xint`, `-XX:-UseCompiler`, `ReplayIgnoreInitErrors`, `DisableIntrinsic`, or runtime/user-data patch is required for the validated Java smoke.
- The final audit pass also hardens host/guest launch plumbing: initial argv construction is bounds-checked, ELF `PT_INTERP` names are bounded and explicitly NUL-terminated, shebang trimming no longer walks before the optional argument string, and ptraceomatic no longer reads before `getenv("TERM")` while constructing the initial environment.
- ARM64 synthetic non-null read-fault recovery remains compile-time gated by `ENABLE_ARM64_READ_FAULT_RECOVERY` and disabled in production builds.
- Guest self-modifying/JIT-patched code invalidation, `CLREX`, `LDXR` widths, `LDPSW`, `DMB`/`DSB`/`ISB`, per-thread `sigaltstack`, and Python/Lua/Java/Clojure/PyPy/Swift/Rust/Erlang/Zig toolchain startup/codegen or availability coverage are covered by runtime fixtures.
- Host OS differences for sysinfo, thread rusage, fd path lookup, stat timestamp fields, random bytes, thread naming, and memory-pressure hooks are centralized through `platform/platform.h`.

## Rollback point

- Roll back to `2074a6a4` if the exec/shebang/initial-argv audit tranche regresses production behavior.
- Roll back to `c4f10affbc99b0038f45fa659730d669c5b10aa2` if the final logging/mount-option audit tranche regresses production behavior.
- Roll back to `17d68ad6fbcedab918e883c1637f254f384c2a73` if the timed-wait cleanup tranche regresses production behavior.
- Roll back to `b38c6239b08270889fc32a33c7095cf376785ba6` if the barrier-audit tranche regresses production behavior.
- Roll back to `0711a849c96889c1225bf4e253607bbd8c4abd7d` if the platform/proc audit tranche regresses production behavior.
- Roll back to `6ea7153e` only if Java C2/LDPSW behavior must be isolated from the Go `sigaltstack` fix.

## Remaining known limitations

- Non-production diagnostic compatibility for ARM64 read-fault recovery exists behind `ENABLE_ARM64_READ_FAULT_RECOVERY`; keep it disabled unless explicitly debugging.
- Native offload and socket/poll implementations still contain host-specific implementation branches outside `platform/platform.h`; the second socket audit hardened Unix socket backing paths, receive buffer lengths, socket-option buffers, and bind-failure cleanup, but broader host-specific socket/poll cleanup remains a future candidate.
