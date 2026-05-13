# ARM64 Production Deployment Notes

Date: 2026-05-12

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

Note: later audit tags through `arm64-openjdk21-prod-20260513-r6` and subsequent pushed `master` audit commits through `80ac6966` were validated on the same rootfs with staged runtime coverage, default mixed-mode Java Hello, expanded Rust/Cargo coverage, and socket ABI/`SCM_RIGHTS` coverage. The local deployment artifact above intentionally records the binary/rootfs staged at deployment time; regenerate the artifact directory if an external release wants the exact current master payload.

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

