# ios-linuxkit ARM64 production deployment notes

Date: 2026-05-12
Reviewed: 2026-05-17

## Scope

This host can validate and stage the ARM64 Linux iSH production binary/rootfs baseline. It is not a macOS/iOS signing host and has no configured App Store/TestFlight/OpenMinis deployment credentials, so external iOS distribution remains a separate macOS CI/release step.

## Local production deployment artifact

- Artifact directory: `/workspace/tmp/ish-arm64-production-deploy-20260512`
- Binary: `/workspace/tmp/ish-arm64-production-deploy-20260512/ish`
- Source binary copied from: `/workspace/projects/ish-arm64/build-arm64-linux/ish`
- Rootfs used for post-deploy smoke: `/workspace/projects/ish-arm64/alpine-arm64-fakefs`
- Manifest: `/workspace/tmp/ish-arm64-production-deploy-20260512/manifest.txt`
- Checksums: `/workspace/tmp/ish-arm64-production-deploy-20260512/SHA256SUMS`

## Code/rootfs baseline

- Repository HEAD at deployment-documentation time: `241d77eb` (`docs: refresh arm64 production audit documentation`)
- Code baseline for the deployed binary: `4c1bc37c` (`util: fix timed wait normalization`)
- Baseline tag: `arm64-openjdk21-prod-20260510-r3`
- Rootfs: `alpine-arm64-fakefs`
- Alpine release: `3.23.4`
- OpenJDK package baseline: `openjdk21-jdk-21.0.10_p7-r0`

Note: later audit tags through `arm64-openjdk21-prod-20260513-r6` and subsequent `master` audit commits were validated on the same rootfs with staged runtime coverage, default mixed-mode Java Hello, expanded Rust/Cargo coverage, socket ABI/`SCM_RIGHTS` coverage, `fchmodat2(AT_EMPTY_PATH)` and scheduler priority syscall coverage, high-address `MAP_NORESERVE` reservation-overlap regression coverage, C# NativeAOT SDK availability, Docker CLI/daemon unsupported diagnostics, opt-in ARM64 internal-continue/taken-internal validation, Alpine npm CLI package startup coverage, and Phase 4 ARM64 executor reconnaissance diagnostics. The latest Phase 4 hot-trace candidate work is default-off and measurement-only: it adds counters/table output behind `ISH_ARM64_BLOCK_STATS=1 ISH_ARM64_HOT_TRACE=1` but does not build or execute traces, add guarded exits, or change invalidation behavior. The local deployment artifact above intentionally records the binary/rootfs staged at deployment time; regenerate the artifact directory if an external release wants the exact current master payload. The working repository `origin` is configured for `rcarmo/ios-linuxkit`; verified bundle/patch exports remain a fallback handoff path.

## Post-deploy Java smoke

Command shape:

```sh
/workspace/tmp/ish-arm64-production-deploy-20260512/ish \
  -f /workspace/projects/ish-arm64/alpine-arm64-fakefs \
  /bin/sh -lc 'java -version; javac -version; javac Hello.java; java Hello'
```

Result log: `/workspace/tmp/ish-arm64-production-deploy-20260512/postdeploy-java-smoke.log`

Observed result:

```text
openjdk version "21.0.10" 2026-01-20
OpenJDK Runtime Environment (build 21.0.10+7-alpine-r0)
OpenJDK 64-Bit Server VM (build 21.0.10+7-alpine-r0, mixed mode, sharing)
javac 21.0.10
javac_rc:0
postdeploy-hi
java_rc:0
```

Host exit status: `0`.

## External production handoff

For an actual iOS/OpenMinis production rollout, use the macOS signing/release path (`fastlane`, `xcodebuild`, configured Apple credentials, and the app/rootfs packaging pipeline). This Debian host should be treated as the Linux validation/staging source of truth, not the final App Store/TestFlight deploy host.
