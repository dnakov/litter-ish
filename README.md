# ios-linuxkit

![](docs/icon-256.png)

`ios-linuxkit` is a Linux runtime for iOS developers. It packages the ARM64 iSH work into a developer-focused environment for running shells, compilers, package managers, language runtimes, and agent/CLI tooling on iPhone and iPad.

The project is based on the `ish-arm64` branch of [iSH](https://ish.app/), but the current focus is no longer just ARM64 bring-up. The emphasis is a practical, _reproducible testing focused_ iOS Linux runtime backed by extensive runtime testing, workload smoke tests, and stabilization of the ARM64 threaded-code executor, Linux syscall layer, filesystem behavior, networking, signals, and modern runtime compatibility.

All the harness tests run in ARM64 Linux, providing direct introspection, debugging, and tracing capabilities that enable easier, reproducible fixes instead of fiddling with a mixed macOS/iOS/Linux environment. 

> **AI Usage:** The harness testing and subsequent fixes are designed to be AI-driven to enable a tight detection/fix loop, and was run under [`rcarmo/piclaw`](https://github.com/rcarmo/piclaw) using GPT-5.5 and a custom `gdb` skill that ships with the repository. The strategy for doing that, including performance optimizations and directions for coalescing gadget calls into faster code sections is entirely human-driven, and informed by years of fiddling with low-level runtimes.

## What it provides

- **AArch64 Linux guest support** using iSH's Asbestos threaded-code interpreter with precompiled ARM64 gadget dispatch; no runtime code generation, RWX memory, or `MAP_JIT` dependency.
- **A 48-bit guest address space** for modern runtimes that rely on large virtual reservations, including V8, JavaScriptCore, Go, Rust, and JVM-based tools.
- **Developer runtime coverage** across shell, `apk`, C/C++, Go, Rust/Cargo, Bun, Node/npm, Python, Lua, Java/OpenJDK, Clojure, Erlang, Zig, and AI CLI startup probes.
- **Stabilized Linux compatibility paths** for signals/ucontext, futex/thread behavior, vector I/O, `fchmodat2(AT_EMPTY_PATH)`, high-address `MAP_NORESERVE`, socket control messages, `SCM_RIGHTS`, path/symlink handling, and self-modifying-code invalidation.
- **iOS terminal/runtime integration** with the Ghostty-Web terminal frontend, hardened ObjC/JS bridge validation, theme validation, and async terminal callback lifetime fixes.

## Current validation baseline

The current core runtime gate is **82 / 82 passing** on the Alpine ARM64 fakefs, with no `SAFETY-VALVE` or `NETDIAG` diagnostics in the latest stable report. A separate AI CLI npm-lane suite is **16 / 16 passing**, covering unauthenticated install/startup/version/help probes for modern agent CLIs without contaminating the stable core gate.

Additional workload validation includes:

- Benchmarks Game rows passing **10 / 10** for GCC, G++, Go, Python, Node.js, PHP, Perl, Ruby, and Lua.
- Java-equivalent Benchmarks Game probes passing **10 / 10** in both mixed-mode and interpreter fallback modes.
- `rcarmo/go-gte` model conversion, `go test ./...`, and runtime execution.
- Bun/PiClaw bootstrap and web-listen smoke coverage for a real JS workspace/server workload.
- Node/Bun performance and executor-dispatch experiments with opt-in block/prechain statistics.

See [runtime validation](docs/RUNTIME_VALIDATION.md) and [workload smoke tests](docs/ARM64_WORKLOAD_SMOKE_TESTS.md) for the detailed matrix, commands, reports, and failure rules.

## Quick start

Build both Linux ARM64 variants:

```sh
make build-arm64-linux-all
```

Run the staged runtime coverage gate:

```sh
make test-arm64-runtime-coverage \
  ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs \
  REPORT_DIR=/workspace/tmp \
  TIMEOUT_S=180 \
  INSTALL_TIMEOUT_S=300
```

Run the separate AI CLI coverage lane:

```sh
make test-arm64-ai-cli-npm-runtime-coverage \
  ROOTFS_LANES=alpine=$(pwd)/alpine-arm64-fakefs \
  REPORT_DIR=/workspace/tmp \
  TIMEOUT_S=180 \
  INSTALL_TIMEOUT_S=1800
```

A passing core run writes `ish-arm64-runtime-coverage-YYYYMMDD-HHMMSS.md` under `REPORT_DIR`; AI CLI runs write `ish-arm64-ai-cli-runtime-coverage-YYYYMMDD-HHMMSS.md`.

## Documentation

- [Documentation index](docs/README.md) — organized map of architecture, validation, workloads, platform notes, and legacy upstream material.
- [Runtime validation](docs/RUNTIME_VALIDATION.md) — current gate, coverage groups, status table, major runtime fixes, and failure interpretation.
- [ARM64 backend notes](docs/ARM64_BACKEND.md) — architecture and implementation details inherited from the `ish-arm64` work.
- [Workload smoke tests](docs/ARM64_WORKLOAD_SMOKE_TESTS.md) — non-trivial language/runtime/application workloads used for stabilization.
- [Executor optimization roadmap](docs/ARM64_GADGET_FUSION_PLAN.md) — gadget fusion, block chaining, prechain experiments, and threaded-interpreter dispatch work.
- [Linux host/platform notes](docs/LINUX_BUILD_AND_HOST_ABI.md) — Linux build, host ABI, and platform abstraction work.
- [Original iSH README](docs/ORIGINAL_ISH_README.md) — preserved upstream/fork README material for historical context and attribution.

## Attribution

`ios-linuxkit` builds on [iSH](https://ish.app/) and the [ish-app/ish](https://github.com/ish-app/ish) project, including its user-mode Linux syscall layer, fakefs/realfs filesystem model, iOS app shell, and Asbestos threaded-code interpreter. The ARM64 backend and runtime stabilization come from the `ish-arm64` fork work in this repository. Original iSH documentation and localized README files are preserved under [`docs/`](docs/) and [`docs/legacy/`](docs/legacy/).

See [LICENSE.md](LICENSE.md) and [LICENSE.IOS](LICENSE.IOS) for license terms.
