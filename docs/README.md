# ios-linuxkit documentation

This directory holds project documentation. The top-level README is the product summary; this directory keeps validation, architecture, workload, and provenance details.

## Start here

| File | Purpose |
|---|---|
| [RUNTIME_VALIDATION.md](RUNTIME_VALIDATION.md) | Test gates, commands, report paths, coverage areas, and failure rules. |
| [ARM64_WORKLOAD_SMOKE_TESTS.md](ARM64_WORKLOAD_SMOKE_TESTS.md) | Workload matrix for language runtimes, package managers, CLIs, and Benchmarks Game rows. |
| [ARM64_BACKEND.md](ARM64_BACKEND.md) | ARM64 guest backend architecture inherited from `ish-arm64`. |
| [ARM64_GADGET_FUSION_PLAN.md](ARM64_GADGET_FUSION_PLAN.md) | Executor dispatch/chaining experiments, Phase 4 hot-trace reconnaissance, and constraints. |
| [LINUX_BUILD_AND_HOST_ABI.md](LINUX_BUILD_AND_HOST_ABI.md) | Linux-host build and platform abstraction notes. |

## Reports and ledgers

| Area | Files |
|---|---|
| Runtime/syscall issue ledger | [ARM64_SMOKE_ISSUES_AND_SYSCALL_COVERAGE.md](ARM64_SMOKE_ISSUES_AND_SYSCALL_COVERAGE.md) |
| Production baseline | [ARM64_PRODUCTION_BASELINE.md](ARM64_PRODUCTION_BASELINE.md), [ARM64_PRODUCTION_DEPLOYMENT.md](ARM64_PRODUCTION_DEPLOYMENT.md) |
| Benchmarks Game | [BENCHMARKSGAME_HARNESS.md](BENCHMARKSGAME_HARNESS.md), [BENCHMARKSGAME_MATRIX.md](BENCHMARKSGAME_MATRIX.md), per-language `BENCHMARKSGAME_*_SMOKE.md` reports |
| Historical benchmark reports | [benchmark/](benchmark/) |
| go-gte workload | [GO_GTE_PROGRESS.md](GO_GTE_PROGRESS.md) |

## Provenance

| Material | Location |
|---|---|
| Original iSH README material | [ORIGINAL_ISH_README.md](ORIGINAL_ISH_README.md) |
| Localized upstream README files | [legacy/](legacy/) |
| Repository root exceptions | `README.md`, `LICENSE.md`, `SECURITY.md`, `ISSUE_TEMPLATE.md`, generated `fastlane/README.md`, and executable skill manifests under `.pi/skills/*/SKILL.md`. |
