# ios-linuxkit

![](docs/icon-256.png)

`ios-linuxkit` is an ARM64 Linux runtime for iOS projects. It builds on the `ish-arm64` work in [iSH](https://ish.app/) and focuses on a testable guest environment for shells, package managers, compilers, language runtimes, and CLI tooling on iPhone and iPad.

The terminal app in this repository is a reference shell. The reusable parts are the ARM64 guest runtime, syscall/filesystem/network compatibility work, and the Linux-host test harnesses used to keep regressions visible.

## Runtime goals

| Goal | Current shape |
|---|---|
| iOS-safe execution | iSH Asbestos threaded-code interpreter; no runtime code generation, RWX memory, or `MAP_JIT`. |
| ARM64 Linux guest | AArch64 guest support with a 48-bit guest address space for V8, JavaScriptCore, Go, Rust, JVM, and similar runtimes. |
| Reproducible testing | Linux-host harnesses boot the same ARM64 fakefs used for iOS work, so syscall/runtime failures can be reproduced outside Xcode. |
| Runtime coverage | Shell, `apk`, C/C++, Go, Rust/Cargo, Bun, Node/npm, Python, Lua, Java/OpenJDK, Clojure, Erlang, Zig, C# NativeAOT availability, and CLI smoke rows. |
| iOS terminal sample | Ghostty-Web frontend with Fira Code Nerd Font, Kitty graphics support, hardened ObjC/JS bridge handling, and validated theme/font paths. |

## Validation snapshot

| Gate | Result | Notes |
|---|---:|---|
| Core runtime coverage | **83 / 83 passing** | Alpine ARM64 fakefs; no `SAFETY-VALVE` or `NETDIAG` diagnostics in the latest report. |
| npm CLI package lane | **16 / 16 passing** | Kept separate because npm packages move quickly. |
| CLI corner-case smoke | **27 pass / 2 unsupported / 0 fail** | Docker daemon/container rows are recorded as unsupported when kernel primitives are absent. |
| Benchmarks Game rows | **10 / 10 per row** | GCC, G++, Go, Python, Node.js, PHP, Perl, Ruby, Lua. |
| Java-equivalent Benchmarks Game | **10 / 10** | Mixed-mode and interpreter fallback both pass. |

See [runtime validation](docs/RUNTIME_VALIDATION.md) for commands, reports, and failure rules. See [workload smoke tests](docs/ARM64_WORKLOAD_SMOKE_TESTS.md) for heavier workload coverage.

## Executor optimization status

ARM64 executor speed work is documented in [ARM64_GADGET_FUSION_PLAN.md](docs/ARM64_GADGET_FUSION_PLAN.md). Current Phase 4 hot-trace work is deliberately measurement-only and default-off: `ISH_ARM64_BLOCK_STATS=1 ISH_ARM64_HOT_TRACE=1` records candidate-edge counters/table output for future design, but the runtime does not build or execute traces, add guarded exits, change invalidation epochs, allocate executable memory, or change generated gadget streams.

## Validation host

The current Linux-host reports were produced on this board:

| Component | Detail |
|---|---|
| Board | Orange Pi 6 Plus |
| SoC | CIX P1 (CD8180/CD8160), ARMv8 AArch64 |
| CPU | 12 cores: 4× Cortex-A520 up to 1.8 GHz, 8× Cortex-A720 up to 2.6 GHz |
| RAM | 16 GB class; about 14 GiB visible to Linux |
| Storage | AirDisk 512 GB NVMe; root on `/dev/nvme0n1p2`, swap on `/dev/nvme0n1p3` |
| OS/kernel | Orange Pi 1.0.2 Trixie / Debian Trixie, Linux `6.6.89-cix`, `aarch64` |
| Toolchain | Clang 19.1.7, Meson 1.7.0, Ninja 1.12.1, GNU Make 4.4.1 |

## Testing workflows

| Workflow | Command |
|---|---|
| Build Linux ARM64 variants | `make build-arm64-linux-all` |
| Core runtime gate | `make test-arm64-runtime-coverage ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=180 INSTALL_TIMEOUT_S=1200` |
| CLI corner cases | `make test-arm64-cli-corner-smoke ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=240 INSTALL_TIMEOUT_S=1200` |
| npm CLI package lane | `make test-arm64-npm-cli-runtime-coverage ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=180 INSTALL_TIMEOUT_S=1800` |
| Node/Bun timing table | `make test-arm64-node-bun-perf ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs REPORT_DIR=/workspace/tmp TIMEOUT_S=180` |

Generated reports are Markdown files under `REPORT_DIR`. A row is not a pass if it times out, is force-killed, or emits diagnostics the harness classifies as runtime failure.

## FAQ

| Question | Short answer |
|---|---|
| Why not upstream iSH as-is? | The i386 guest limits address space and runtime compatibility. This fork targets ARM-on-ARM interactive use. |
| Is this an App Store product? | No. The checked-in app is a reference terminal and packaging harness. |
| Why rename it? | To avoid confusion with upstream iSH and make the runtime-kit goal explicit. |

## Documentation

- [docs/README.md](docs/README.md) — documentation map.
- [docs/RUNTIME_VALIDATION.md](docs/RUNTIME_VALIDATION.md) — gates, commands, coverage areas, failure rules.
- [docs/ARM64_WORKLOAD_SMOKE_TESTS.md](docs/ARM64_WORKLOAD_SMOKE_TESTS.md) — heavier workload matrix.
- [docs/ARM64_BACKEND.md](docs/ARM64_BACKEND.md) — ARM64 backend architecture notes.
- [docs/ARM64_GADGET_FUSION_PLAN.md](docs/ARM64_GADGET_FUSION_PLAN.md) — executor optimization notes.
- [docs/LINUX_BUILD_AND_HOST_ABI.md](docs/LINUX_BUILD_AND_HOST_ABI.md) — Linux-host build/platform notes.
- [docs/ORIGINAL_ISH_README.md](docs/ORIGINAL_ISH_README.md) — preserved upstream/fork README material.

## Attribution

`ios-linuxkit` builds on [iSH](https://ish.app/) and [ish-app/ish](https://github.com/ish-app/ish): user-mode Linux syscall translation, fakefs/realfs, the iOS app shell, and the Asbestos threaded-code interpreter. The ARM64 backend and runtime hardening come from the `ish-arm64` fork work in this repository. Legacy upstream README material is preserved under [`docs/`](docs/) and [`docs/legacy/`](docs/legacy/).

See [LICENSE.md](LICENSE.md) and [LICENSE.IOS](LICENSE.IOS).
