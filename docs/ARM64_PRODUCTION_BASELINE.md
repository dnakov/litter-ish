# ARM64 Production Baseline

Date: 2026-05-10
Reviewed: 2026-05-12

## Known-good code

- Code commit: `4c1bc37c` (`util: fix timed wait normalization`)
- Baseline tag: `arm64-openjdk21-prod-20260510-r3`
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
- GCC: `15.2.0-r2`
- musl: `1.2.5-r23`

## Validation artifacts

- Runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260510-102148.md`
  - Result: 28 / 28 passing
- Go Benchmarks Game smoke: `/workspace/tmp/benchmarksgame-go-smoke-20260510-084223.md`
  - Result: 10 / 10 passing
- Default mixed-mode Java Hello smoke: `/workspace/tmp/java-hello-sync-audit-20260510.log`
  - `javac_rc:0`
  - `java_rc:0`
- Production baseline capture: `/workspace/tmp/ish-arm64-production-baseline-20260510.txt`
- Local production deployment/post-deploy smoke: [ARM64_PRODUCTION_DEPLOYMENT.md](ARM64_PRODUCTION_DEPLOYMENT.md)

## Production-readiness notes

- OpenJDK default mixed mode is enabled; no `-Xint`, `-XX:-UseCompiler`, `ReplayIgnoreInitErrors`, `DisableIntrinsic`, or runtime/user-data patch is required for the validated Java smoke.
- ARM64 synthetic non-null read-fault recovery remains compile-time gated by `ENABLE_ARM64_READ_FAULT_RECOVERY` and disabled in production builds.
- Guest self-modifying/JIT-patched code invalidation, `CLREX`, `LDXR` widths, `LDPSW`, `DMB`/`DSB`/`ISB`, and per-thread `sigaltstack` are covered by runtime fixtures.
- Host OS differences for sysinfo, thread rusage, fd path lookup, stat timestamp fields, random bytes, thread naming, and memory-pressure hooks are centralized through `platform/platform.h`.

## Rollback point

- Roll back to `17d68ad6fbcedab918e883c1637f254f384c2a73` if the timed-wait cleanup tranche regresses production behavior.
- Roll back to `b38c6239b08270889fc32a33c7095cf376785ba6` if the barrier-audit tranche regresses production behavior.
- Roll back to `0711a849c96889c1225bf4e253607bbd8c4abd7d` if the platform/proc audit tranche regresses production behavior.
- Roll back to `6ea7153e` only if Java C2/LDPSW behavior must be isolated from the Go `sigaltstack` fix.

## Remaining known limitations

- Non-production diagnostic compatibility for ARM64 read-fault recovery exists behind `ENABLE_ARM64_READ_FAULT_RECOVERY`; keep it disabled unless explicitly debugging.
- Native offload and socket/poll implementations still contain host-specific implementation branches outside `platform/platform.h`; these are not involved in the Linux ARM64 Java production path but remain candidates for future cleanup.
