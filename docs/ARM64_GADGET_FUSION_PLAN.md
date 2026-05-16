# ARM64 gadget fusion and trace/superblock plan

Date: 2026-05-15

This document tracks the structural speed work for the ARM64 guest backend. The current executor is upstream iSH Asbestos: a threaded-code interpreter that decodes each guest basic block into a stream of precompiled native gadget pointers plus inline operands. It is not a runtime-code-emitting JIT.

## Current baseline

Existing optimization infrastructure already includes:

- block cache and block chaining in `asbestos/asbestos.c` and `asbestos/guest-arm64/gadgets-aarch64/control.S`;
- ARM64 peephole/fused gadgets in `asbestos/guest-arm64/gen.c` and `gadgets-aarch64/`, including `CMP/SUBS + B.cond`, `ADRP+ADD`, `ADRP+LDR64`, and specialized add/sub immediate/register fast paths;
- precise load/store fault PC support through `gadget_set_jit_saved_pc` before memory instructions;
- self-modifying-code invalidation through page-indexed fiber blocks.

## Phase 0: measurement harness

Add a focused Bun/Node perf-table harness before changing executor semantics. It should produce Markdown rows with status and host wall time for:

- `node --version`, `node -e`;
- `bun --version`, `bun -e`;
- JSON parse/stringify loops;
- small-file create/stat/read loops;
- recursive copy;
- local package-manager fixture install where practical;
- test-runner and HTTP loopback rows once the short rows are stable.

This gives a stable before/after signal for dispatch, memory translation, filesystem, process startup, and event-loop costs.

## Phase 1: safe gadget-fusion cleanup

Start by extending existing peephole infrastructure rather than introducing a new IR.

Optional generation counters are enabled with:

```sh
ISH_ARM64_FUSION_STATS=1 ./build-arm64-linux/ish -f alpine-arm64-fakefs /bin/sh -lc 'node --version'
```

They are silent by default and print one line per one-shot emulator process, for example:

```text
ARM64_FUSION_STATS cmp_bcond=5532 subs_bcond=92 adrp_add=2636 adrp_ldr64=1638 addsub_fast=21935 addsub_cbz=6
```

The first counter-enabled Node/Bun perf-table run is `/workspace/tmp/ish-arm64-node-bun-perf-20260515-214650.md` with **10 / 10 passing**. The hottest current categories are existing `CMP + B.cond` fusion and specialized add/sub fast paths, especially in Node eval/JSON rows.

First Phase 1 tranche:

- Added a pure register/control-flow peephole for `ADD/SUB (imm, no flags) + CBZ/CBNZ` when the branch tests the just-written result register.
- Added `arm64 add/sub cbz fusion` runtime coverage with explicit 64-bit `SUB+CBNZ`, 64-bit `ADD+CBNZ`, 64-bit `SUB+CBZ`, and 32-bit `ADD+CBZ` cases.
- Hardened the Node/Bun perf table to assert expected output, not just exit status.
- Validation reports:
  - Targeted JS smoke: Node and Bun both returned `addsub-js-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260515-222649.md`, **10 / 10 passing**. Representative hits: Node eval `addsub_cbz=285`, Node JSON `384`, Bun eval `22`, Bun JSON `24`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260515-222729.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260515-221106.md`, all displayed checks passing including the new fusion fixture.

Next steps:

1. Treat `ADD/SUB + CBZ/CBNZ` as the first safe but modest-hit tranche.
2. Use more granular counters before selecting the next fused gadget.
3. Prefer pure register/control fusions first:
   - `ADRP+ADD` variants not already covered;
   - compare/test + branch gaps;
   - loop-carried `SUBS/ADDS + B.cond` variants;
   - simple `MOV/ADD/SUB` chains when flags are not live.
4. Keep all new fusions behind exact encoding checks and fallback to existing single-instruction gadgets.

Rules:

- Do not fuse across `SVC`, barriers, atomics, indirect branches, or unknown instructions.
- Do not introduce memory-op fusions until per-op fault PC metadata is proven for the fused gadget.
- Preserve flags exactly, especially when the first instruction writes NZCV and the second consumes it.

## Phase 2: memory-adjacent fusions

Precise fault-PC metadata has been verified for regular ARM64 load/store faults:

- `gadget_set_jit_saved_pc` is emitted before each `INSN_LD_ST` in `asbestos/guest-arm64/gen.c`.
- Regular TLB-miss paths in `gadgets-aarch64/gadgets.h` restore `CPU_pc` from `LOCAL_jit_saved_pc` before returning `INT_GPF`.
- Host SIGSEGV recovery in `main.c` also restores `CPU_pc` from `LOCAL_jit_saved_pc` where available.
- Runtime fixture `arm64 precise fault pc` verifies a guest SIGSEGV handler observes the exact faulting `LDR` and `STR` instruction PCs, not the containing block/function. Full coverage report: `/workspace/tmp/ish-arm64-runtime-coverage-20260515-224825.md`, **51 / 51 passing**.

Phase 2 may now be planned, but each fused memory gadget must carry the same precision guarantee. The safe initial allow-list is intentionally narrow:

1. `ADD/SUB (imm, no flags) -> LDR/STR unsigned-offset` when:
   - both instructions are adjacent and same page;
   - the address-generation result register is used only as the memory base;
   - no SP destination/source ambiguity unless a dedicated SP-safe gadget is written;
   - the fused gadget stores the address-generation result before the memory op if the original pair would have architecturally written it before faulting.
2. `ADRP+ADD -> LDR64` variants only when the currently fused `ADRP+LDR64` and `ADRP+ADD` semantics do not cover the pattern, and when the memory instruction remains the only faultable operation.
3. `LDR (integer, non-exclusive) -> CBZ/CBNZ` only after adding per-op metadata in the fused gadget so a fault reports the `LDR` PC, while a successful load branches from the `CBZ/CBNZ` PC/fallthrough model.

Explicit Phase 2 deny-list until separately proven:

- atomics/exclusive monitor instructions (`LDXR/STXR`, pair exclusives, CAS/CASP);
- SIMD interleaved loads/stores and multi-register memory ops;
- pre-index/post-index addressing modes where writeback ordering on fault is subtle;
- fusions spanning barriers, `SVC`, indirect branches, page boundaries, or self-modifying-code hazards;
- any memory fusion where the earlier instruction has guest-visible side effects that would be lost if the memory operation faults.

Implementation requirement: every fused memory sub-operation must emit/set a fault-PC slot for the specific faultable guest instruction before touching guest memory. If the fused gadget contains more than one faultable memory access, it needs per-access metadata, not a single block-level saved PC.

Phase 2A implementation tranche:

- Added opt-in candidate counters:
  - `addsub_ldr_cand` for `ADD/SUB (imm, no flags) -> integer LDR unsigned-offset` candidates.
  - `addsub_str_cand` for `ADD/SUB (imm, no flags) -> integer STR unsigned-offset` candidates.
  - `ldr_cbz_cand` for `LDR integer -> CBZ/CBNZ` candidates.
- Node/Bun counter run `/workspace/tmp/ish-arm64-node-bun-perf-20260515-230404.md` was **10 / 10 passing** and selected `ADD/SUB -> LDR` as the first target: Node JSON had `addsub_ldr_cand=178333`, Node eval `51063`, Bun JSON `1688`.
- Implemented a narrow `ADD/SUB (imm, 64-bit, no flags) + LDR Xt, [Xd, #imm]` fusion for adjacent same-page instructions. The fused gadget stores the ADD/SUB result before the LDR and writes the LDR guest PC into `LOCAL_jit_saved_pc` before the faultable memory access.
- Added runtime fixture `arm64 fused addsub ldr fault pc`, which verifies both precise LDR fault PC and the pre-fault ADD side effect in the guest signal context.
- Validation reports:
  - Targeted fused fault smoke: `fused-addsub-ldr-fault-ok` with `addsub_ldr64=702`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260515-230939.md`, **10 / 10 passing**. Representative fusion hits: Node JSON `addsub_ldr64=111223`, Node eval `24312`, Bun JSON `838`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260515-231042.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260515-231122.md`, **52 / 52 passing**.

Phase 2B implementation tranche:

- Added granular `ldr64_cbz64_cand` counter for safe `LDR64 unsigned-offset -> CBZ/CBNZ64` opportunities.
- Counter run `/workspace/tmp/ish-arm64-node-bun-perf-20260515-232611.md` was **10 / 10 passing** and showed meaningful hits: Node eval `ldr64_cbz64_cand=32303`, Node JSON `34092`, Bun eval `7535`, Bun JSON `13462`.
- Implemented narrow adjacent same-page `LDR Xt, [Xn, #imm] + CBZ/CBNZ Xt` fusion for non-SP base and non-XZR destination. The fused gadget stores the loaded register before branching and writes the LDR guest PC into `LOCAL_jit_saved_pc` before the faultable memory access.
- Added runtime fixtures:
  - `arm64 ldr cbz fusion` for taken/not-taken CBZ/CBNZ behavior plus loaded-register side effects.
  - `arm64 fused ldr cbz fault pc` for precise LDR fault PC and no destination-register write on fault.
- Validation reports:
  - Targeted branch/fault smokes: `ldr-cbz-smoke 11 22 0 7`, `fused-ldr-cbz-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260515-233210.md`, **10 / 10 passing**. Representative fusion hits: Node eval `ldr64_cbz64=26391`, Node JSON `28422`, Bun eval `5862`, Bun JSON `11331`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260515-233302.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260515-233343.md`, **54 / 54 passing**.

Phase 2C implementation tranche:

- Implemented narrow adjacent same-page `ADD/SUB (imm, 64-bit, no flags) + STR Xt, [Xd, #imm]` fusion for non-SP address-generation registers and non-XZR store sources.
- The fused gadget stores the ADD/SUB result before the STR and writes the STR guest PC into `LOCAL_jit_saved_pc` before the faultable memory access. It reads the store source after the ADD/SUB side effect so `STR Xd, [Xd, #imm]` preserves original architectural ordering.
- Added runtime fixtures:
  - `arm64 addsub str fusion` for successful stores, including `rt == rd` ordering.
  - `arm64 fused addsub str fault pc` for precise STR fault PC and visible pre-fault ADD side effect in the guest signal context.
- Validation reports:
  - Targeted success/fault smokes: `addsub-str-smoke 123456789abcdef0 efffd020`, `fused-addsub-str-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260515-235311.md`, **10 / 10 passing**. Representative fusion hits: Node eval `addsub_str64=5016`, Node JSON `17282`, Bun eval `40`, Bun JSON `71`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260515-235403.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260515-235700.md`, **56 / 56 passing**.

Phase 2D implementation tranche:

- Implemented narrow adjacent same-page `ADD/SUB (imm, 64-bit, no flags) + LDR Wt, [Xd, #imm]` fusion for non-SP address-generation registers and non-XZR load destinations.
- The fused gadget stores the ADD/SUB result before the LDR, writes the LDR guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, and zero-extends the 32-bit load result into the architectural X register. This preserves the pre-fault ADD/SUB side effect and `rt == rd` overwrite ordering.
- Added runtime fixtures:
  - `arm64 addsub ldr32 fusion` for successful zero-extending loads, including `rt == rd` ordering.
  - `arm64 fused addsub ldr32 fault pc` for precise LDR fault PC, visible pre-fault ADD side effect, and no destination-register write on fault.
- Validation reports:
  - Targeted success/fault smokes: `addsub-ldr32-fusion-ok 89abcdef fedcba98`, `fused-addsub-ldr32-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-001254.md`, **10 / 10 passing**. Representative fusion hits: Node eval `addsub_ldr32=5104`, Node JSON `17210`, Bun eval `33`, Bun JSON `123`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-001328.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-001406.md`, **58 / 58 passing**.

## Phase 3: linear superblocks

Phase 3 should wait until the Phase 1 fusion tranche is stable across repeated Node/Bun and core runtime runs. Initial design remains same-page and conservative:

- max 2-4 basic blocks;
- max 32-64 guest instructions;
- direct known branch/fallthrough only;
- same page initially;
- stop at syscall, indirect branch, barrier/atomic, page boundary, or any instruction with uncertain invalidation/fault behavior;
- stop before memory-adjacent fused gadgets unless their per-op fault metadata has a targeted regression test.

Use the existing page-index invalidation path: every page touched by a superblock must invalidate that superblock. For Phase 3A, require a single touched page and no new invalidation data structure. For Phase 3B, allow multi-page superblocks only after adding an explicit page-list/back-reference invalidation test.

## Phase 4: hot traces

Only after superblocks are stable:

- add low-overhead block execution/taken-target counters;
- build hot traces from observed dominant paths;
- add guarded exits back to normal blocks;
- enforce invalidation epochs so traces die on guest code writes.

## Validation gates

For each implementation tranche:

1. `make build-arm64-linux`.
2. Short Bun/Node perf-table run for before/after numbers.
3. Core Alpine runtime coverage (all current Alpine checks passing).
4. Targeted Bun/Node rows from runtime coverage.
5. AI CLI npm lane when changes affect JSC/V8 mmap/fault behavior.

Do not treat speedups as valid if diagnostics include `SAFETY-VALVE`, fault noise, missing syscall noise, host crash messages, or forced timeouts.
