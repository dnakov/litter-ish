# ios-linuxkit ARM64 gadget fusion and trace/superblock plan

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

Phase 2E implementation tranche:

- Implemented narrow adjacent same-page `ADD/SUB (imm, 64-bit, no flags) + LDRB Wt, [Xd, #imm]` fusion for non-SP address-generation registers and non-XZR load destinations.
- The fused gadget stores the ADD/SUB result before the LDRB, writes the LDRB guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, and zero-extends the 8-bit load result into the architectural X register. This preserves the pre-fault ADD/SUB side effect and `rt == rd` overwrite ordering.
- Added runtime fixtures:
  - `arm64 addsub ldr8 fusion` for successful zero-extending byte loads, including `rt == rd` ordering.
  - `arm64 fused addsub ldr8 fault pc` for precise LDRB fault PC, visible pre-fault ADD side effect, and no destination-register write on fault.
- Validation reports:
  - Targeted success/fault smokes: `addsub-ldr8-fusion-ok ab cd`, `fused-addsub-ldr8-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-002911.md`, **10 / 10 passing**. Representative fusion hits: Node eval `addsub_ldr8=5126`, Node JSON `5684`, Bun eval `130`, Bun JSON `675`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-002946.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-003025.md`, **60 / 60 passing**.

Phase 2F implementation tranche:

- Implemented narrow adjacent same-page `ADD/SUB (imm, 64-bit, no flags) + LDRH Wt, [Xd, #imm]` fusion for non-SP address-generation registers and non-XZR load destinations.
- The fused gadget stores the ADD/SUB result before the LDRH, writes the LDRH guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, and zero-extends the 16-bit load result into the architectural X register. This preserves the pre-fault ADD/SUB side effect and `rt == rd` overwrite ordering.
- Added runtime fixtures:
  - `arm64 addsub ldr16 fusion` for successful zero-extending halfword loads, including `rt == rd` ordering.
  - `arm64 fused addsub ldr16 fault pc` for precise LDRH fault PC, visible pre-fault ADD side effect, and no destination-register write on fault.
- Validation reports:
  - Targeted success/fault smokes: `addsub-ldr16-fusion-ok abcd cdef`, `fused-addsub-ldr16-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-004542.md`, **10 / 10 passing**. Representative fusion hits: Node eval `addsub_ldr16=16766`, Node JSON `41041`, Bun eval `5`, Bun JSON `5`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-004617.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-004655.md`, **62 / 62 passing**.

Phase 2G implementation tranche:

- Implemented narrow adjacent same-page `LDR Wt, [Xn, #imm] + CBZ/CBNZ Wt` fusion for non-SP bases and non-XZR destinations.
- The fused gadget writes the LDR guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, zero-extends and stores the loaded W register before branching, then applies the 32-bit CBZ/CBNZ condition.
- Added runtime fixtures:
  - `arm64 ldr32 cbz fusion` for taken/not-taken CBZ/CBNZ behavior plus zero-extended loaded-register side effects.
  - `arm64 fused ldr32 cbz fault pc` for precise LDR fault PC and no destination-register write on fault.
- Validation reports:
  - Targeted success/fault smokes: `ldr32-cbz-fusion-ok`, `fused-ldr32-cbz-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-010252.md`, **10 / 10 passing**. Representative fusion hits: Node eval `ldr32_cbz32=8157`, Node JSON `7657`, Bun eval `1999`, Bun JSON `7024`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-010341.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-010420.md`, **64 / 64 passing**.

Phase 2H implementation tranche:

- Implemented narrow adjacent same-page `LDRB Wt, [Xn, #imm] + CBZ/CBNZ Wt` fusion for non-SP bases and non-XZR destinations.
- The fused gadget writes the LDRB guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, zero-extends and stores the loaded byte before branching, then applies the 32-bit CBZ/CBNZ condition.
- Added runtime fixtures:
  - `arm64 ldr8 cbz fusion` for taken/not-taken CBZ/CBNZ behavior plus zero-extended loaded-register side effects.
  - `arm64 fused ldr8 cbz fault pc` for precise LDRB fault PC and no destination-register write on fault.
- Validation reports:
  - Targeted success/fault smokes: `ldr8-cbz-fusion-ok`, `fused-ldr8-cbz-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-012008.md`, **10 / 10 passing**. Representative fusion hits: Node eval `ldr8_cbz32=5574`, Node JSON `5978`, Bun eval `799`, Bun JSON `2010`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-012058.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-012138.md`, **66 / 66 passing**.

Phase 2I implementation tranche:

- Implemented narrow adjacent same-page `LDRH Wt, [Xn, #imm] + CBZ/CBNZ Wt` fusion for non-SP bases and non-XZR destinations.
- The fused gadget writes the LDRH guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, zero-extends and stores the loaded halfword before branching, then applies the 32-bit CBZ/CBNZ condition.
- Added runtime fixtures:
  - `arm64 ldr16 cbz fusion` for taken/not-taken CBZ/CBNZ behavior plus zero-extended loaded-register side effects.
  - `arm64 fused ldr16 cbz fault pc` for precise LDRH fault PC and no destination-register write on fault.
- Validation reports:
  - Targeted success/fault smokes: `ldr16-cbz-fusion-ok`, `fused-ldr16-cbz-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-013808.md`, **10 / 10 passing**. Representative fusion hits: Node eval `ldr16_cbz32=71`, Node JSON `144`, Bun eval `239`, Bun JSON `623`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-013858.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-013939.md`, **68 / 68 passing**.

Phase 2J implementation tranche:

- Implemented narrow adjacent same-page `ADD/SUB (imm, 64-bit, no flags) + STR Wt, [Xd, #imm]` fusion for non-SP address-generation registers and non-XZR store sources.
- The fused gadget stores the ADD/SUB result before the STR, writes the STR guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, reads the store source after the ADD/SUB side effect, and writes the low 32 bits for the architectural W store.
- Added runtime fixtures:
  - `arm64 addsub str32 fusion` for successful stores, including `rt == rd` ordering.
  - `arm64 fused addsub str32 fault pc` for precise STR fault PC and visible pre-fault ADD side effect in the guest signal context.
- Validation reports:
  - Targeted success/fault smokes: `addsub-str32-fusion-ok 9abcdef0 efffd014`, `fused-addsub-str32-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-015706.md`, **10 / 10 passing**. Representative fusion hits: Node eval `addsub_str32=326`, Node JSON `288`, Bun eval `6`, Bun JSON `10`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-015757.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-015841.md`, **70 / 70 passing**.

Phase 2K implementation tranche:

- Implemented narrow adjacent same-page `ADD/SUB (imm, 64-bit, no flags) + STRH Wt, [Xd, #imm]` fusion for non-SP address-generation registers and non-XZR store sources.
- The fused gadget stores the ADD/SUB result before the STRH, writes the STRH guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, reads the store source after the ADD/SUB side effect, and writes the low 16 bits for the architectural halfword store.
- Added runtime fixtures:
  - `arm64 addsub str16 fusion` for successful stores, including `rt == rd` ordering.
  - `arm64 fused addsub str16 fault pc` for precise STRH fault PC and visible pre-fault ADD side effect in the guest signal context.
- Validation reports:
  - Targeted success/fault smokes: `addsub-str16-fusion-ok def0 d00e`, `fused-addsub-str16-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-021441.md`, **10 / 10 passing**. Representative fusion hits: Node eval `addsub_str16=67`, Node JSON `279`, Bun eval `0`, Bun JSON `0`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-021533.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-021614.md`, **72 / 72 passing**.

Phase 2L implementation tranche:

- Implemented narrow adjacent same-page `ADD/SUB (imm, 64-bit, no flags) + STRB Wt, [Xd, #imm]` fusion for non-SP address-generation registers and non-XZR store sources.
- The fused gadget stores the ADD/SUB result before the STRB, writes the STRB guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, reads the store source after the ADD/SUB side effect, and writes the low 8 bits for the architectural byte store.
- Added runtime fixtures:
  - `arm64 addsub str8 fusion` for successful stores, including `rt == rd` ordering.
  - `arm64 fused addsub str8 fault pc` for precise STRB fault PC and visible pre-fault ADD side effect in the guest signal context.
- Validation reports:
  - Targeted success/fault smokes: `addsub-str8-fusion-ok f0 b`, `fused-addsub-str8-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-023219.md`, **10 / 10 passing**. Representative fusion hits: Node eval `addsub_str8=221`, Node JSON `231`, Bun eval `13`, Bun JSON `13`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-023314.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-023403.md`, **74 / 74 passing**.

Phase 2M implementation tranche:

- Implemented narrow adjacent same-page `LDR Xt, [SP, #imm] + CBZ/CBNZ Xt` fusion for 64-bit unsigned-offset loads from the guest stack pointer.
- This SP-base variant is separate from the non-SP `LDR64 + CBZ/CBNZ` gadget: it reads `CPU_sp` directly, writes the LDR guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, stores the loaded register before branching, and preserves the same target/fallthrough chaining model.
- Added runtime fixtures:
  - `arm64 ldr64 sp cbz fusion` for successful SP-relative `CBZ` and `CBNZ` behavior.
  - `arm64 fused ldr64 sp cbz fault pc` for precise LDR fault PC and no destination-register write on fault while guest SP is zero, delivered on a signal altstack.
- Validation reports:
  - Targeted success/fault smokes: `ldr64-sp-cbz-fusion-ok`, `fused-ldr64-sp-cbz-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-025605.md`, **10 / 10 passing**. Representative fusion hits: Node eval `ldr64_sp_cbz64=4502`, Node JSON `4901`, Bun eval `1647`, Bun JSON `2293`; total table hits `13640`, covering essentially all SP-specific candidates.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-025647.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-025733.md`, **76 / 76 passing**.

Phase 2N implementation tranche:

- Implemented narrow adjacent same-page `LDRSW Xt, [Xn/SP, #imm] + CBZ/CBNZ Xt` fusion for sign-extending 32-bit unsigned-offset loads followed by a 64-bit zero/nonzero branch.
- The fused gadget supports both general-register and SP bases, writes the LDRSW guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, sign-extends the loaded value to 64 bits, stores the destination register before branching, and preserves the existing target/fallthrough chaining model.
- Added runtime fixtures:
  - `arm64 ldrsw cbz fusion` for successful general-register and SP-relative `LDRSW + CBZ/CBNZ` behavior, including negative sign-extension.
  - `arm64 fused ldrsw cbz fault pc` for precise LDRSW fault PC and no destination-register write on fault while guest SP is zero, delivered on a signal altstack.
- Validation reports:
  - Targeted success/fault smokes: `ldrsw-cbz-fusion-ok`, `fused-ldrsw-cbz-fault-ok`; a counter-only fixture run showed `ldr32_sx_cbz64=4`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-031519.md`, **10 / 10 passing**. This tranche is safe but low-hit in the table: total `ldr32_sx_cbz64=4` and `ldr32_sx_cbz64_cand=4`; remaining `ldr_cbz` candidate gap is about `4912`, likely mostly signed 8/16-bit or other non-allow-listed shapes.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-031601.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-031642.md`, **78 / 78 passing**.

Phase 2O implementation tranche:

- Implemented narrow adjacent same-page `LDRSB/LDRSH Xt/Wt, [Xn/SP, #imm] + matching CBZ/CBNZ Xt/Wt` fusion for sign-extending byte/halfword unsigned-offset loads followed by same-width zero/nonzero branches.
- The fused gadget supports both general-register and SP bases, writes the LDRSB/LDRSH guest PC into `LOCAL_jit_saved_pc` before the faultable memory access, stores the sign-extended destination register before branching, and preserves the existing target/fallthrough chaining model.
- Added runtime fixtures:
  - `arm64 ldrsx8/16 cbz fusion` for successful general-register and SP-relative signed byte/halfword behavior, including 32-bit and 64-bit sign-extension cases.
  - `arm64 fused ldrsx8/16 cbz fault pc` for precise signed halfword fault PC and no destination-register write on fault while guest SP is zero, delivered on a signal altstack.
- Validation reports:
  - Targeted success/fault smokes: `ldrsx8-16-cbz-fusion-ok`, `fused-ldrsx8-16-cbz-fault-ok`; a counter-only fixture run showed signed-byte fusion hits (`ldr8_sx_cbz=4`).
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-033606.md`, **10 / 10 passing**. Current measured table hits are signed-byte only: total `ldr8_sx_cbz=545` and `ldr8_sx_cbz_cand=545`; signed-halfword candidate/hit counters were zero in this table. Remaining `ldr_cbz` candidate gap is about `4316`.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-033659.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-033750.md`, **80 / 80 passing**.

Phase 2P implementation tranche:

- Extended the existing zero-extending `LDR Wt/LDRH Wt/LDRB Wt, [Xn, #imm] + CBZ/CBNZ Wt` fusions to also accept `rn == 31` SP-relative bases.
- The fused gadgets now read `CPU_sp` directly for SP-base cases while preserving precise load fault PC via `LOCAL_jit_saved_pc`, destination-register store-before-branch ordering, and the existing target/fallthrough chaining model.
- Added runtime fixtures:
  - `arm64 ldrz sp cbz fusion` for successful SP-relative 32-bit, halfword, and byte zero-extending `CBZ`/`CBNZ` behavior.
  - `arm64 fused ldrz sp cbz fault pc` for precise byte-load fault PC and no destination-register write on fault while guest SP is zero, delivered on a signal altstack.
- Validation reports:
  - Targeted success/fault smokes: `ldrz-sp-cbz-fusion-ok`, `fused-ldrz-sp-cbz-fault-ok`.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-035402.md`, **10 / 10 passing**. The measured `ldr_cbz` residual gap dropped to about `803` (`137188` fused out of `137991` candidates in that table), indicating the previous remaining gap was mostly SP-base narrow zero-ext loads.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-035444.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-035535.md`, **82 / 82 passing**.

Phase 2Q implementation tranche:

- Relaxed sign-extending load branch fusions so `LDRSW`, `LDRSB`, and `LDRSH` may fuse with either 32-bit or 64-bit `CBZ/CBNZ` when the branch tests the same destination register. This is safe because zero/nonzero is invariant under the sign-extension result written by the load.
- Extended the existing `ldrsw` and `ldrsx8/16` runtime fixtures to include branch-width mismatch cases such as `LDRSW Xt + CBNZ Wt`, `LDRSB Xt + CBNZ Wt`, and `LDRSH Wt + CBZ Xt`.
- Validation reports:
  - Targeted success/fault smokes: `ldrsw-cbz-fusion-ok`, `fused-ldrsw-cbz-fault-ok`, `ldrsx8-16-cbz-fusion-ok`, and `fused-ldrsx8-16-cbz-fault-ok`; counter-only fixture runs showed `ldr32_sx_cbz64=6` and signed byte/halfword counters at `5` each.
  - Counter-enabled Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-041206.md`, **10 / 10 passing**. The measured `ldr_cbz` residual gap is about `773` (`137646` fused out of `138419` candidates), suggesting the remaining gap is mostly page/shape overcount rather than a high-value adjacent same-page width gap.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-041249.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-041337.md`, **82 / 82 passing**.

## Phase 3: linear superblocks

Phase 2 closeout / Phase 3A reconnaissance:

- After Phase 2Q, the measured `LDR -> CBZ` residual gap is about `773` out of `138419` candidates in `/workspace/tmp/ish-arm64-node-bun-perf-20260516-041206.md`, so Phase 2 peephole work is effectively complete for adjacent same-page patterns.
- Added opt-in block/chaining reconnaissance counters with `ISH_ARM64_BLOCK_STATS=1`. These are silent by default and print one `ARM64_BLOCK_STATS` line per process at exit, analogous to `ISH_ARM64_FUSION_STATS`.
- The counters track block entries, cache hits/misses, compiled blocks, generated code words, guest bytes, direct jump slots, chain attempts, chain patches, chain slot split, and same-page/cross-page patch split.
- Initial validation reports:
  - Fusion+block-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-043212.md`, **10 / 10 passing**. Aggregated table totals: `entries=13142739`, `compiled=4483554`, `chain_attempts=6046842`, `chain_patches=5296075`, patch rate about **87.6%**, average compiled block length about **23.6 guest bytes**.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-043257.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-043349.md`, **82 / 82 passing**.
- Refined same-page/slot split validation reports:
  - Fusion+block-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-044756.md`, **10 / 10 passing**. Aggregated table totals: `entries=13170583`, `compiled=4516350`, `chain_attempts=6084891`, `chain_patches=5337294`, `chain_patch_same_page=4055538`, `chain_patch_cross_page=1281756`, `chain_patch_slot0=2249708`, and `chain_patch_slot1=3087586`. Patch rate is about **87.7%**; same-page patches are about **76.0%** of patched chains; average compiled block length is about **23.7 guest bytes**.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-044839.md`, **10 / 10 passing**, no stats output.
  - Core Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-044925.md`, **82 / 82 passing**.
- Phase 3A should remain reconnaissance/design first. The high chain-patch rate and high same-page share confirm that a same-page direct-target superblock prototype may be worthwhile, but the first prototype should not weaken invalidation or precise fault-PC guarantees.

Phase 3 should wait until the Phase 1/2 fusion tranche is stable across repeated Node/Bun and core runtime runs. Initial design remains same-page and conservative:

- max 2-4 basic blocks;
- max 32-64 guest instructions;
- direct known branch/fallthrough only;
- same page initially;
- stop at syscall, indirect branch, barrier/atomic, page boundary, or any instruction with uncertain invalidation/fault behavior;
- stop before memory-adjacent fused gadgets unless their per-op fault metadata has a targeted regression test.

Use the existing page-index invalidation path: every page touched by a superblock must invalidate that superblock. For Phase 3A, require a single touched page and no new invalidation data structure. For Phase 3B, allow multi-page superblocks only after adding an explicit page-list/back-reference invalidation test.

Phase 3A scoping decision after refined counters:

- Do **not** prototype arbitrary internal superblock branch targets by writing raw pointers into existing `jump_ip` slots. Current `inline_chain` and `fiber_ret_chain` assume every bit-63-clear chain pointer is exactly `block->code`, not an interior gadget pointer. They recover `CPU_pc` and `LOCAL_last_block` by subtracting `FIBER_BLOCK_code` and reading `FIBER_BLOCK_addr`; an interior pointer would make those values wrong and could corrupt later chaining/invalidation behavior.
- A safe same-page superblock representation therefore needs one of these before code generation changes:
  1. a per-segment header/table so internal code pointers can map back to the correct guest PC and owning block;
  2. dedicated internal branch/continue gadgets that set `CPU_pc` explicitly and avoid the existing block-start pointer assumptions; or
  3. an eager same-page prechain experiment that still chains only whole `fiber_block` starts (useful but not a true superblock).
- The first true superblock prototype should be opt-in and should add a targeted invalidation fixture where code in the second segment is patched after the superblock is compiled. The test must prove page-index invalidation drops the whole superblock and that precise load/store fault PCs still report the faulting guest instruction, not the superblock entry.
- Given the current data, the best next implementation step is a design/representation tranche or a very narrow eager-prechain experiment, not internal-target concatenation.

Phase 3A eager same-page prechain experiment:

- Added default-off `ISH_ARM64_EAGER_PRECHAIN=1`. When enabled, `fiber_insert` scans a newly inserted block's outgoing `jump_ip` slots and patches only same-page fake-IP targets that already have compiled `fiber_block` entries. The patched value is still exactly `target->code`, and the existing `jumps_from` back-reference is recorded so invalidation restores the original fake IP. No interior code pointers or true superblock targets are introduced.
- Extended `ISH_ARM64_BLOCK_STATS=1` with `prechain_attempts`, `prechain_patches`, and outgoing/incoming split counters. These counters stay zero unless eager prechain is enabled.
- Added nested `ISH_ARM64_EAGER_PRECHAIN_INCOMING=1` for an incoming-edge measurement experiment under `ISH_ARM64_EAGER_PRECHAIN=1`. It scans only a small bounded set of already-compiled same-page predecessor blocks and patches still-fake slots that target the newly inserted block. This removed most same-page runtime chain patches in Node/Bun, but the first unbounded version made compile-heavy runtime coverage rows hit the 120s timeout; keep incoming prechain as a measurement/debug flag until there is a cheaper predecessor index. The promoted default-off experiment remains outgoing-only eager prechain.
- Dynamic ARM64 chain patching now validates the bit-63 fake-IP tag and full 48-bit target before replacing a slot with `block->code`. Block disconnect also restores a disconnected source block's own chained slots before unlinking them from target `jumps_from` lists, so a jetsam'd block that is still executing falls back through fake-IP dispatch instead of retaining stale direct-chain pointers.
- iOS/App Store posture: this executor should be described externally as a precompiled gadget executor, threaded interpreter, or dispatch cache rather than an App Store-facing “JIT”. The runtime block streams are data arrays of pointers/operands to native gadgets that are already shipped in the app binary; eager prechain only rewrites data slots to existing whole-block `fiber_block->code` starts. It does not allocate or generate new executable native code, does not require RWX pages, and does not require `MAP_JIT`/`mprotect(PROT_EXEC)`. On the iOS app path these Linux `main.c` env setters are not called, so eager flags remain false unless an app-specific initialization path deliberately enables them.
- App Review caveat: Apple can still scrutinize an emulator that runs user-provided binaries. Keep all native executable code in the app bundle, avoid runtime executable-memory generation on iOS, and avoid App Store/user-facing wording that claims “JIT compilation”.
- Validation reports:
  - Targeted smokes: default eager run produced no `ARM64_BLOCK_STATS`; stats-only without eager reported all prechain counters as zero; eager-only reported non-zero outgoing counters and zero incoming counters; nested incoming+stats reported non-zero incoming counters.
  - Nested incoming+fusion+block-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-071120.md`, **10 / 10 passing**. Aggregated table totals include `chain_attempts=4806787`, `chain_patches=1443421`, `chain_patch_same_page=324651`, `chain_patch_cross_page=1118770`, `prechain_patches=3473970`, `prechain_outgoing_patches=400984`, and `prechain_incoming_patches=3072986`.
  - Promoted outgoing-only eager+fusion+block-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-071228.md`, **10 / 10 passing**. Aggregated table totals include `chain_attempts=5160170`, `chain_patches=4435052`, `chain_patch_same_page=3297533`, `chain_patch_cross_page=1137519`, `prechain_patches=400574`, and zero incoming prechain counters.
  - Default/no-stats Node/Bun perf: `/workspace/tmp/ish-arm64-node-bun-perf-20260516-071258.md`, **10 / 10 passing**, no stats output.
  - Promoted outgoing-only eager Alpine runtime coverage: `/workspace/tmp/ish-arm64-runtime-coverage-20260516-071511.md`, **82 / 82 passing**.

Incoming-prechain predecessor-index design notes:

- Do not extend the current scan-based incoming experiment into production. Even with a small scan limit it is workload-sensitive, and the unbounded version proved it can turn dense compile pages into a compile-time timeout problem.
- A cheap incoming prechain needs an explicit pending-predecessor index keyed by same-page target guest PC, not a page-list scan. The index should store per-source-slot entries for only still-fake `jump_ip` slots.
- Do not reuse `jumps_from_links[2]` for pending entries. Those links are already owned by real patched target `jumps_from[i]` lists after a slot is chained. A pending index needs separate per-slot link storage or a small sidecar allocation so cleanup can distinguish “pending fake slot” from “patched back-reference”.
- Required cleanup points before implementation:
  1. when a source slot is patched, remove its pending entry before adding the existing `jumps_from_links[i]` back-reference;
  2. when a source block is disconnected/jetsam'd, remove any remaining pending entries for both slots;
  3. when a target block is inserted, consume only same-page pending entries whose fake target exactly matches `block->addr`;
  4. when a page is invalidated, the normal disconnect path must remove both pending entries and patched back-references without leaving stale list nodes.
- Keep all pending-index experiments opt-in behind `ISH_ARM64_EAGER_PRECHAIN_INCOMING=1` until a targeted invalidation fixture and the full Alpine runtime coverage pass without timeout regressions.

True-superblock representation scoping:

- Do not make existing `jump_ip` slots point at interior offsets. `inline_chain`, `fiber_ret_chain`, RET-cache continuations, poke exits, and `LOCAL_last_block` recovery all treat bit-63-clear targets as `fiber_block->code` starts and recover the owning block by subtracting `FIBER_BLOCK_code`.
- Preferred Phase 3B representation is an internal-continue gadget path, not fake `fiber_block` segment headers. Internal superblock branches should use new operands that are never exposed as normal chained pointers, for example `[guest_pc][internal_code_offset]` patched at `gen_end` to an absolute code-stream pointer. The gadget sets `CPU_pc` to `guest_pc`, sets `_pc` to the internal continuation, and `gret`s.
- External exits from a superblock must continue using the existing fake-IP/`block->code` mechanism so invalidation, `jumps_from`, ret-cache, poke/timer exits, and dynamic chain repair keep their current invariants. Internal continuation pointers must not be stored in `jump_ip`, ret-cache return continuations, or any structure consumed by `fiber_ret_chain`.
- Generation should store internal continuation targets as offsets while the block is still reallocatable, then patch them after final allocation in `gen_end`. This avoids stale absolute pointers if `gen()` grows the code array.
- Phase 3B should start with same-page, single-owner blocks only. `block->addr` remains the public entry guest PC; `block->end_addr` and page-list membership must conservatively cover every guest byte compiled into the superblock. Multi-page or discontinuous superblocks need explicit page back-references before they are allowed.
- Precise fault-PC rule: every faultable memory instruction inside an internal segment must still be preceded by `gadget_set_jit_saved_pc` for that exact guest instruction. Internal branch gadgets may update `CPU_pc` for observability, but signal recovery must continue to report the faulting instruction, not the superblock entry.
- Scheduling rule: because internal continues reduce normal block-transition checks, keep initial superblocks short and preserve existing syscall/indirect/barrier/atomic/page-boundary stops. Add a dedicated timer/poke budget only if superblocks become long enough to delay existing checks.
- Required fixtures before any true-superblock code lands: same-page invalidation of a patched second segment, precise load/store fault PC in a second segment, branch-taken and fallthrough internal continuations, ret-cache unaffected by an internal call-adjacent segment, and default-off iOS/App Store posture unchanged.
- Initial dormant scaffold added after this scoping pass: `gadget_internal_continue` consumes `[guest_pc][internal_code_ptr]`, sets `CPU_pc`, sets `_pc` to the internal continuation pointer, and `gret`s without using `fiber_ret_chain`. `gen_state` has zero-initialized internal-continue patch arrays so generation can store offsets while `state->block` is reallocatable and let `gen_end` patch final code-stream pointers.
- Scaffold validation: `make build-arm64-linux`, default/no-stats shell smoke, opt-in block-stats shell smoke, default Node/Bun perf `/workspace/tmp/ish-arm64-node-bun-perf-20260516-082912.md` (**10 / 10 passing**), and full Alpine runtime coverage `/workspace/tmp/ish-arm64-runtime-coverage-20260516-083022.md` (**82 / 82 passing**).
- Initial scaffold audit before the first call-site prototype: `gadget_internal_continue` was present in the ARM64 control object and final binary, immediately before `gadget_branch`, but no generator path emitted it. Disassembly showed the gadget only loads `guest_pc`, loads the internal continuation pointer, stores `CPU_pc`, assigns `_pc`, and performs normal `gret` dispatch. It does not call or branch to `fiber_ret_chain`, so it cannot be confused with normal external chained pointers unless a generator explicitly emits it.

First internal-continue call-site scope:

- Do not try to reuse existing conditional branch operands for internal targets. Current `bcond`, `cbz/cbnz`, `tbz/tbnz`, and fused branch gadgets run selected operands through `inline_chain`/`fiber_ret_chain`, so a bit-63-clear interior pointer would be misread as a `fiber_block->code` start.
- Narrowest first shape should be a new conditional gadget variant with exactly one internal successor and one normal external fake-IP successor. The internal successor should point to a `gadget_internal_continue` code-stream record; the external successor should remain a normal fake IP and be the only operand recorded in `jump_ip`.
- Start with non-call conditional branches only (`B.cond`, then optionally `CBZ/CBNZ`/`TBZ/TBNZ`). Exclude `BL`, `BLR`, `RET`, indirect branches, syscalls, barriers/atomics, page-boundary cases, and ret-cache-affecting shapes.
- Prefer fallthrough-internal first: compile the not-taken/fallthrough segment after the branch, let the taken side exit through fake-IP dispatch, and only add a taken-internal variant after branch/fallthrough fixtures pass.
- Generator requirements before implementation: add an emit helper that checks `internal_continue_count < GEN_INTERNAL_CONTINUE_MAX`, emits `[gadget_internal_continue][guest_pc][0]`, records the pointer operand slot in `internal_continue_patch_ip[]`, records the target code offset in `internal_continue_target_ip[]`, and increments the count only after all fields are valid.
- The first prototype should compile at most one extra segment, same page only, direct known successor only, no nested internal branches, and a small instruction budget. `block->end_addr` and page hash membership must conservatively cover the appended segment.
- Required first-call-site fixtures: forced taken external path, forced fallthrough internal path, page invalidation after compiling the internal segment, precise load/store fault PC inside the internal segment, ret-cache unaffected by nearby `BL`/`RET` code, default/no-env silence, and iOS default-off posture unchanged.
- Prototype status: the first executable call site is opt-in behind `ISH_ARM64_INTERNAL_CONTINUE=1` for the `B.cond` fallthrough-internal shape. It emits a dedicated `gadget_bcond_fallthrough_internal` with `[cond][fake_taken_target][internal_continue_record_ptr]`; only the taken external fake target is stored in `jump_ip[0]`. The not-taken path loads the private internal record pointer, sets `_pc` to that record, and `gret`s without passing the interior pointer to `fiber_ret_chain`.
- Taken-internal prototype status: the forward-taken `B.cond` shape is now implemented as a second-level opt-in behind `ISH_ARM64_INTERNAL_CONTINUE_TAKEN=1` in addition to `ISH_ARM64_INTERNAL_CONTINUE=1`. It emits `gadget_bcond_taken_internal` with `[cond][internal_continue_record_ptr][fake_fallthrough]`; only the external fallthrough fake target is stored in `jump_ip[0]`. The taken edge sets `_pc` to the private internal-continue record and `gret`s directly, while the not-taken edge uses the normal fake-IP/`fiber_ret_chain` path.
- Prototype generator limits: current emission requires a same-page continuation segment (`PAGE(state->ip) == PAGE(block->addr)` for fallthrough-internal, `PAGE(target) == PAGE(block->addr)` for taken-internal), at most one internal segment per block (`internal_continue_used`), enough patch slots for the branch operand plus `gadget_internal_continue` record, and a deliberately tight 2-instruction segment budget (`GEN_INTERNAL_CONTINUE_BUDGET_INSNS`). The `gadget_internal_continue` record still stores `guest_pc` for observability/fault recovery and patches its continuation pointer in `gen_end` after final block allocation.
- Prototype validation so far: `make build-arm64-linux`; default/no-env shell smoke stayed silent; `ISH_ARM64_FUSION_STATS=1` without `ISH_ARM64_INTERNAL_CONTINUE` reported `internal_continue=0` in `/workspace/tmp/ish-arm64-internal-continue-default-stats-20260516-102637.log`; opt-in shell smoke reported `internal_continue=491` in `/workspace/tmp/ish-arm64-internal-continue-smoke-20260516-102629.log`; Alpine-only Node/Bun default `/workspace/tmp/ish-arm64-node-bun-perf-20260516-102827.md` and opt-in `/workspace/tmp/ish-arm64-node-bun-perf-20260516-102901.md` were both **10 / 10 passing**; full Alpine runtime coverage default `/workspace/tmp/ish-arm64-runtime-coverage-20260516-102953.md` and opt-in `/workspace/tmp/ish-arm64-runtime-coverage-20260516-104032.md` were both **83 / 83 passing**.
- Non-Alpine validation note: the expanded Makefile multi-rootfs `test-arm64-node-bun-perf` run generated `/workspace/tmp/ish-arm64-node-bun-perf-20260516-102732.md` with Alpine **10 / 10 passing** but Debian **12 / 20 overall** due pre-existing-looking Debian lane failures (`uv_thread_create` assertion for Node evals and Bun `V8_SIGTRAP`). Do not use that multi-lane report as a speedup baseline for this Alpine-first tranche until the Debian lane is fixed or scoped separately.
- First-call-site fixture harness: `make test-arm64-internal-continue-fixtures` now builds a dedicated guest C/assembly fixture and generated `/workspace/tmp/ish-arm64-internal-continue-fixtures-20260516-110826.md` (**9 / 9 passing**). It verifies source/iOS default-off posture (`ios-default-off-audit-ok`, no `ISH_ARM64_INTERNAL_CONTINUE` in app `.m`/`.h`/`.c`/`.mm`/`.xcconfig`/`.plist` files, and enablement only through `main.c` reading `getenv("ISH_ARM64_INTERNAL_CONTINUE")`), default/no-stats silence, stats-only default-off `internal_continue=0`, opt-in `B.cond` taken-external plus fallthrough-internal execution (`internal_continue=263`), default and opt-in same-page invalidation after patching the fallthrough/internal segment (`internal_continue=268`), a call-adjacent/RET-cache smoke (`internal_continue=263`), and precise fault-PC reporting from a load fault inside the internal segment (`internal_continue=268`).
- Taken-internal final validation: after adding the second-level `ISH_ARM64_INTERNAL_CONTINUE_TAKEN=1` gate and the taken-edge gadget, `make test-arm64-internal-continue-fixtures` generated `/workspace/tmp/ish-arm64-internal-continue-fixtures-20260516-201003.md` (**10 / 10 passing**), including separate taken-internal and fallthrough-internal rows plus source/iOS default-off audit coverage for both env names. Focused Java/Clojure/Rust checks passed in default, normal internal-continue, and taken-internal modes; one earlier broad Java JIT crash was not mode-specific and did not reproduce in focused loops. Final Alpine gates: Node/Bun default/internal/taken reports `/workspace/tmp/ish-arm64-node-bun-perf-20260516-201007.md`, `/workspace/tmp/ish-arm64-node-bun-perf-20260516-201038.md`, and `/workspace/tmp/ish-arm64-node-bun-perf-20260516-201109.md` were all **10 / 10 passing**; full runtime coverage default/internal/taken reports `/workspace/tmp/ish-arm64-runtime-coverage-20260516-204934.md`, `/workspace/tmp/ish-arm64-runtime-coverage-20260516-210109.md`, and `/workspace/tmp/ish-arm64-runtime-coverage-20260516-211305.md` were all **83 / 83 passing** after adding the scheduler-syscall regression fixture.
- CBZ/CBNZ internal-continue tranche: `CBZ`/`CBNZ` now has dedicated `gadget_cbz_fallthrough_internal` and `gadget_cbz_taken_internal` variants using the same Phase 3B representation as `B.cond`: exactly one internal continuation record and one external fake-IP successor, no interior pointers stored in `jump_ip`, continuation pointers patched in `gen_end`, same-page/direct-known successor only, and the taken edge still requiring both `ISH_ARM64_INTERNAL_CONTINUE=1` and `ISH_ARM64_INTERNAL_CONTINUE_TAKEN=1`. This is still not a true hot trace or multi-segment superblock implementation; it is a narrow opt-in extension of the existing internal-continue call-site representation. Validation: focused fixtures `/workspace/tmp/ish-arm64-internal-continue-fixtures-20260516-224454.md` were **12 / 12 passing** with explicit CBZ/CBNZ taken-internal and fallthrough-internal rows; Node/Bun default/internal/taken reports `/workspace/tmp/ish-arm64-node-bun-perf-20260516-224515.md`, `/workspace/tmp/ish-arm64-node-bun-perf-20260516-224544.md`, and `/workspace/tmp/ish-arm64-node-bun-perf-20260516-224616.md` were all **10 / 10 passing**; full Alpine runtime coverage default/internal/taken reports `/workspace/tmp/ish-arm64-runtime-coverage-20260516-224657.md`, `/workspace/tmp/ish-arm64-runtime-coverage-20260516-225912.md`, and `/workspace/tmp/ish-arm64-runtime-coverage-20260516-231127.md` were all **83 / 83 passing**.
- TBZ/TBNZ internal-continue tranche: `TBZ`/`TBNZ` now has dedicated `gadget_tbz_fallthrough_internal` and `gadget_tbz_taken_internal` variants using the same Phase 3B representation as `B.cond` and `CBZ/CBNZ`: exactly one internal continuation record and one external fake-IP successor, no interior pointers stored in `jump_ip`, continuation pointers patched in `gen_end`, same-page/direct-known successor only, and the taken edge still requiring both `ISH_ARM64_INTERNAL_CONTINUE=1` and `ISH_ARM64_INTERNAL_CONTINUE_TAKEN=1`. This remains a narrow opt-in internal-continue extension, not a true hot trace/multi-segment superblock implementation. Validation: focused fixtures `/workspace/tmp/ish-arm64-internal-continue-fixtures-20260517-061538.md` were **14 / 14 passing** with explicit TBZ/TBNZ taken-internal and fallthrough-internal rows after final diff review; Node/Bun default/internal/taken reports `/workspace/tmp/ish-arm64-node-bun-perf-20260517-000539.md`, `/workspace/tmp/ish-arm64-node-bun-perf-20260517-000609.md`, and `/workspace/tmp/ish-arm64-node-bun-perf-20260517-000641.md` were all **10 / 10 passing**; full Alpine runtime coverage default/internal/taken reports `/workspace/tmp/ish-arm64-runtime-coverage-20260517-052625.md`, `/workspace/tmp/ish-arm64-runtime-coverage-20260517-053713.md`, and `/workspace/tmp/ish-arm64-runtime-coverage-20260517-054858.md` were all **83 / 83 passing**.
- Phase 3B closeout/recon counter tranche: `ISH_ARM64_FUSION_STATS=1` now splits `internal_continue` into per-shape/edge counters: `internal_continue_bcond_fallthrough`, `internal_continue_bcond_taken`, `internal_continue_cbz_fallthrough`, `internal_continue_cbz_taken`, `internal_continue_tbz_fallthrough`, and `internal_continue_tbz_taken`. This is measurement-only: default behavior is unchanged, no true hot traces or multi-segment superblocks are introduced, and the existing internal-continue invariants remain unchanged. Validation: focused fixtures `/workspace/tmp/ish-arm64-internal-continue-fixtures-20260517-061837.md` were **14 / 14 passing** and verified all new fields stay zero when only stats are enabled without `ISH_ARM64_INTERNAL_CONTINUE`; Node/Bun default/internal/taken reports `/workspace/tmp/ish-arm64-node-bun-perf-20260517-061902.md`, `/workspace/tmp/ish-arm64-node-bun-perf-20260517-061941.md`, and `/workspace/tmp/ish-arm64-node-bun-perf-20260517-062021.md` were all **10 / 10 passing**. Aggregated Node/Bun split in normal internal mode was `internal_continue=357768` with fallthrough-only shape split `bcond=145743`, `cbz=96952`, `tbz=115073`; taken mode was `internal_continue=440526` with `bcond_fallthrough=143686`, `bcond_taken=22931`, `cbz_fallthrough=93263`, `cbz_taken=17700`, `tbz_fallthrough=114393`, and `tbz_taken=48553`. Full Alpine runtime coverage default/internal/taken reports `/workspace/tmp/ish-arm64-runtime-coverage-20260517-062115.md`, `/workspace/tmp/ish-arm64-runtime-coverage-20260517-064342.md`, and `/workspace/tmp/ish-arm64-runtime-coverage-20260517-065504.md` were all **83 / 83 passing**. Keep stats-enabled runtime coverage out of the validation gate because `ARM64_FUSION_STATS` intentionally writes diagnostic lines that can pollute exact-output rows; use focused fixtures and Node/Bun stats reports for counter evidence.

## Phase 4: hot traces

Only after superblocks are stable:

- add low-overhead block execution/taken-target counters;
- build hot traces from observed dominant paths;
- add guarded exits back to normal blocks;
- enforce invalidation epochs so traces die on guest code writes.

Phase 4 reconnaissance counter tranche:

- Extended `ISH_ARM64_BLOCK_STATS=1` with chained-entry execution counters from the normal `fiber_ret_chain` fast path: `chain_entries`, `chain_entry_slot0`, `chain_entry_slot1`, `chain_entry_unknown_slot`, `chain_entry_same_page`, and `chain_entry_cross_page`. These count runtime transitions that stay inside chained gadget execution, complementing the older main-loop `entries`, compile, and chain-patch counters.
- Scope remains measurement-only: no trace builder, no guarded exits, no invalidation epoch changes, and no new superblock behavior. The stats probe is gated by the existing block-stats flag and default runs remain stats-silent.
- Focused smoke: default `/workspace/tmp/arm64-blockstats-default-20260517-071536.log` stayed silent; stats-enabled `/workspace/tmp/arm64-blockstats-enabled-20260517-071536.log` emitted non-zero chained-entry fields.
- Node/Bun validation: default `/workspace/tmp/ish-arm64-node-bun-perf-20260517-071603.md` and block-stats `/workspace/tmp/ish-arm64-node-bun-perf-20260517-071650.md` were both **10 / 10 passing**. Aggregated block-stats totals from the stats run: `entries=13238844`, `chain_entries=12493903`, `chain_entry_slot0=5885466`, `chain_entry_slot1=6608436`, `chain_entry_unknown_slot=1`, `chain_entry_same_page=12452595`, and `chain_entry_cross_page=41308`. This shows most observed chained executions stay same-page, and slot 1/fallthrough-style chains are slightly hotter in the Node/Bun table.
- Runtime validation: default full Alpine runtime coverage `/workspace/tmp/ish-arm64-runtime-coverage-20260517-071802.md` was **83 / 83 passing**. Keep `ISH_ARM64_BLOCK_STATS=1` out of exact-output runtime coverage gates for the same reason as fusion stats: diagnostics intentionally write extra lines.

Phase 4 hot-candidate reconnaissance tranche:

- Added bounded opt-in heavy-hitter tables under `ISH_ARM64_BLOCK_STATS=1` to surface candidate hot block PCs and chained edges without building traces. The dump now includes an `ARM64_BLOCK_HOT_STATS` line with top 8 approximate block entries (`hot_blockN_pc/count`) and top 8 approximate chained edges (`hot_edgeN_from/to/slot/count`) plus sample and eviction totals.
- Scope remains reconnaissance-only: no trace builder, no guarded exits, no invalidation epoch changes, no changes to normal generated gadget streams, and the default C path checks `arm64_block_stats_enabled` before calling the hot-block helper. The chained fast path already gates the C stats hook on the same flag.
- Focused smoke: default `/workspace/tmp/arm64-hotstats-default-20260517-073746.log` stayed silent; stats-enabled `/workspace/tmp/arm64-hotstats-enabled-20260517-073746.log` emitted both `ARM64_BLOCK_STATS` and `ARM64_BLOCK_HOT_STATS` with non-zero hot block/edge fields.
- Node/Bun validation: default `/workspace/tmp/ish-arm64-node-bun-perf-20260517-073802.md` and block-stats `/workspace/tmp/ish-arm64-node-bun-perf-20260517-073848.md` were both **10 / 10 passing**. Aggregated hot-candidate stats from the block-stats run: `block_samples=25674755`, `edge_samples=12503165`, `chain_entries=12503165`, `chain_entry_unknown_slot=0`; the hottest row-local block candidate observed was `hot_block0_pc=0xedfba7a8` with count `2216394`, and the hottest row-local edge candidate was `0xedfb379c -> 0xedfb37a8` on slot `1` with count `1752072`.
- Runtime validation: default full Alpine runtime coverage `/workspace/tmp/ish-arm64-runtime-coverage-20260517-074001.md` was **83 / 83 passing**.

Phase 4 dry-run trace-candidate classification tranche:

- Extended `ARM64_BLOCK_HOT_STATS` with aggregate chained-edge shape counters: `trace_edge_same_page`, `trace_edge_forward_same_page`, `trace_edge_backward_same_page`, `trace_edge_self_loop`, `trace_edge_cross_page`, and `trace_edge_unknown_slot`. These classify observed chained edges for future trace-builder eligibility without building traces or changing execution semantics.
- Scope remains stats-only and default-off: no trace builder, no guarded exits, no invalidation epoch changes, and no generated-code behavior changes.
- Focused smoke: default `/workspace/tmp/arm64-traceclass-default-20260517-075602.log` stayed silent; stats-enabled `/workspace/tmp/arm64-traceclass-enabled-20260517-075602.log` emitted the new classification fields with non-zero same-page, forward, backward, self-loop, and cross-page values.
- Node/Bun validation: default `/workspace/tmp/ish-arm64-node-bun-perf-20260517-075634.md` and block-stats `/workspace/tmp/ish-arm64-node-bun-perf-20260517-075720.md` were both **10 / 10 passing**. Aggregated classification from the stats run: `edge_samples=12497734`, `trace_edge_same_page=12455860`, `trace_edge_forward_same_page=9560299` (**76.50%**), `trace_edge_self_loop=2183638` (**17.47%**), `trace_edge_backward_same_page=711923` (**5.70%**), `trace_edge_cross_page=41874` (**0.34%**), and `trace_edge_unknown_slot=0`. This supports a future same-page forward-edge-only first trace prototype and suggests self-loops/backward edges should remain excluded until loop-specific guard behavior is designed.
- Runtime validation: default full Alpine runtime coverage `/workspace/tmp/ish-arm64-runtime-coverage-20260517-075835.md` was **83 / 83 passing**.

Phase 4 forward-edge distance/adjacency tranche:

- Extended `ARM64_BLOCK_HOT_STATS` with same-page forward-edge guardrail buckets: `trace_edge_forward_adjacent`, `trace_edge_forward_le16`, `trace_edge_forward_17_64`, `trace_edge_forward_65_256`, and `trace_edge_forward_gt256`. `trace_edge_forward_adjacent` uses `to->addr == from->end_addr + 1`; the distance buckets use `to->addr - from->addr` for same-page forward edges.
- Scope remains stats-only and default-off: no trace builder, no guarded exits, no invalidation epoch changes, and no generated-code behavior changes.
- Focused smoke: default `/workspace/tmp/arm64-tracedist-default-20260517-081419.log` stayed silent; stats-enabled `/workspace/tmp/arm64-tracedist-enabled-20260517-081419.log` emitted the new adjacency/distance fields.
- Node/Bun validation: default `/workspace/tmp/ish-arm64-node-bun-perf-20260517-081447.md` and block-stats `/workspace/tmp/ish-arm64-node-bun-perf-20260517-081536.md` were both **10 / 10 passing**. Aggregated same-page-forward bucket evidence from the stats run: `trace_edge_forward_same_page=9563135`, `trace_edge_forward_adjacent=6599987` (**69.01%** of forward edges), `trace_edge_forward_le16=6066876` (**63.44%**), `trace_edge_forward_17_64=3080110` (**32.21%**), `trace_edge_forward_65_256=251698` (**2.63%**), and `trace_edge_forward_gt256=164451` (**1.72%**). This supports keeping any first trace prototype constrained to adjacent or very-near same-page forward edges.
- Runtime validation: the first default runtime pass stopped around the known intermittent Java mixed-mode row without producing a report; the rerun passed full Alpine runtime coverage **83 / 83** at `/workspace/tmp/ish-arm64-runtime-coverage-20260517-082042.md`.

Phase 4 dormant hot-trace gate/guardrail scaffold:

- Added a Linux/local-runtime-only `ISH_ARM64_HOT_TRACE` env gate and surfaced its parsed state as `hot_trace_enabled=0/1` in the existing `ARM64_BLOCK_HOT_STATS` diagnostics. The gate is deliberately dormant: it does not build traces, does not add guarded exits, does not alter invalidation epochs, and does not change generated gadget streams or normal execution behavior.
- Default-off posture: setting `ISH_ARM64_HOT_TRACE=1` only records intent for future guard-gated trace work and is only externally visible when `ISH_ARM64_BLOCK_STATS=1` also enables the diagnostic dump. The iOS/app path remains unchanged; no app source/config file should reference `ISH_ARM64_HOT_TRACE` unless a future app-specific initialization path is designed.
- Focused smoke: default `/workspace/tmp/arm64-hottrace-default-20260517-084204.log` and hot-trace-only `/workspace/tmp/arm64-hottrace-hotonly-20260517-084204.log` stayed `ARM64_BLOCK` silent; stats-only `/workspace/tmp/arm64-hottrace-stats-20260517-084204.log` reported `hot_trace_enabled=0`; stats+hot-trace `/workspace/tmp/arm64-hottrace-enabled-20260517-084204.log` reported `hot_trace_enabled=1`.
- Node/Bun validation: default `/workspace/tmp/ish-arm64-node-bun-perf-20260517-084220.md` and `ISH_ARM64_BLOCK_STATS=1 ISH_ARM64_HOT_TRACE=1` `/workspace/tmp/ish-arm64-node-bun-perf-20260517-084252.md` were both **10 / 10 passing**. The default report stayed free of `ARM64_BLOCK` diagnostics, while the enabled report included `ARM64_BLOCK_HOT_STATS hot_trace_enabled=1`.
- Runtime validation: default Alpine runtime coverage was **83 / 83 passing** at `/workspace/tmp/ish-arm64-runtime-coverage-20260517-085451.md`.
- Guardrails before any real hot-trace builder lands:
  1. Candidate selection must start with observed same-page forward edges only, preferably adjacent or very-near edges supported by the current bucket evidence. Keep self-loops, backward edges, cross-page edges, indirect exits, syscalls, atomics/barriers, and page-boundary cases excluded until specific guard behavior is designed.
  2. External exits must continue to use fake-IP / normal block dispatch semantics unless a dedicated guarded-exit representation is added and tested. Do not store interior trace pointers in `jump_ip`, ret-cache continuations, or any structure consumed by `fiber_ret_chain`.
  3. Invalidation must be proven before executable traces are enabled: a guest write to any compiled trace segment must retire the whole trace, and any epoch/guard metadata must fail closed back to normal block execution.
  4. Precise fault-PC behavior must stay per-instruction inside any traced segment, matching the existing `gadget_set_jit_saved_pc` rule for faultable memory operations.
  5. Initial executable traces, if/when attempted, must be opt-in behind `ISH_ARM64_HOT_TRACE=1`, short, same-page, direct-known-successor only, and covered by focused invalidation, fault-PC, guarded-exit, default-silence, and iOS default-off audits before performance claims.

Phase 4 dry-run hot-trace eligibility tranche:

- Extended `ARM64_BLOCK_HOT_STATS` with `ISH_ARM64_HOT_TRACE`-gated dry-run eligibility counters for a possible first trace builder. These counters stay zero with `ISH_ARM64_BLOCK_STATS=1` alone and only classify edges when both `ISH_ARM64_BLOCK_STATS=1` and `ISH_ARM64_HOT_TRACE=1` are set.
- The dry-run candidate policy is intentionally conservative: a candidate edge must have a matched direct `jump_ip` slot, be same-page, be forward, and have `to->addr - from->addr <= 64`. Candidate sub-buckets count adjacent edges (`to->addr == from->end_addr + 1`) and very-near `<= 16` deltas. Reject counters split unknown-slot, self-loop, backward, cross-page, and far-forward edges. This still does not build traces, add guarded exits, change invalidation epochs, or alter generated gadget streams.
- Focused smoke: default `/workspace/tmp/arm64-hottrace-elig-default-20260517-090932.log` and hot-trace-only `/workspace/tmp/arm64-hottrace-elig-hotonly-20260517-090932.log` stayed `ARM64_BLOCK` silent; stats-only `/workspace/tmp/arm64-hottrace-elig-stats-20260517-090932.log` reported all `hot_trace_edge_*` counters as zero; stats+hot-trace `/workspace/tmp/arm64-hottrace-elig-enabled-20260517-090932.log` reported non-zero `hot_trace_edge_samples` and `hot_trace_edge_candidate`.
- Node/Bun validation: default `/workspace/tmp/ish-arm64-node-bun-perf-20260517-090948.md` and `ISH_ARM64_BLOCK_STATS=1 ISH_ARM64_HOT_TRACE=1` `/workspace/tmp/ish-arm64-node-bun-perf-20260517-091023.md` were both **10 / 10 passing**. Aggregated dry-run eligibility evidence from the gated run: `hot_trace_edge_samples=12499547`, `hot_trace_edge_candidate=9144734` (**73.16%**), `hot_trace_edge_candidate_adjacent=6555428` (**71.69%** of candidates), `hot_trace_edge_candidate_le16=6067139` (**66.35%** of candidates), `hot_trace_edge_reject_self_loop=2183640`, `hot_trace_edge_reject_backward=711973`, `hot_trace_edge_reject_cross_page=42931`, `hot_trace_edge_reject_far=416269`, and `hot_trace_edge_reject_unknown_slot=0`.
- Runtime validation: default Alpine runtime coverage was **83 / 83 passing** at `/workspace/tmp/ish-arm64-runtime-coverage-20260517-091128.md`.
- Next guardrail implication: the first executable hot-trace prototype, if attempted, should still start with adjacent or `<= 16` same-page forward edges and must add fail-closed guarded-exit and invalidation tests before enabling any trace execution path. The `<= 64` dry-run candidate bucket is useful for measurement breadth, not yet permission to trace far or loop-shaped paths.

Phase 4 eligible-edge heavy-hitter tranche:

- Added a separate top-8 `hot_trace_candidate_edgeN_*` heavy-hitter table under the existing `ISH_ARM64_BLOCK_STATS=1 ISH_ARM64_HOT_TRACE=1` dry-run gate. The table records only edges that pass the conservative eligibility filter from the previous tranche: matched direct slot, same-page, forward, and `delta <= 64`. Rejected self-loops, backward edges, cross-page edges, unknown-slot edges, and far-forward edges are excluded from this candidate table even if they are hot in the general `hot_edgeN_*` table.
- Scope remains measurement-only/default-off: no trace builder, no guarded exits, no invalidation epoch changes, no generated-code behavior changes, and no iOS/App config references. Stats-only runs without `ISH_ARM64_HOT_TRACE=1` keep the candidate table zeroed.
- Focused smoke: default `/workspace/tmp/arm64-hottrace-candtop-default-20260517-092609.log` and hot-trace-only `/workspace/tmp/arm64-hottrace-candtop-hotonly-20260517-092609.log` stayed `ARM64_BLOCK` silent; stats-only `/workspace/tmp/arm64-hottrace-candtop-stats-20260517-092609.log` kept `hot_trace_candidate_edge0_count=0`; stats+hot-trace `/workspace/tmp/arm64-hottrace-candtop-enabled-20260517-092609.log` reported non-zero candidate edge table entries.
- Node/Bun validation: default `/workspace/tmp/ish-arm64-node-bun-perf-20260517-092629.md` and `ISH_ARM64_BLOCK_STATS=1 ISH_ARM64_HOT_TRACE=1` `/workspace/tmp/ish-arm64-node-bun-perf-20260517-092700.md` were both **10 / 10 passing**. Aggregated gated evidence: `hot_trace_edge_samples=12505085`, `hot_trace_edge_candidate=9148801` (**73.16%**), `hot_trace_edge_candidate_adjacent=6560652` (**71.71%** of candidates), `hot_trace_edge_candidate_le16=6067462` (**66.32%** of candidates), and `hot_trace_candidate_edge_evictions=1317431`. The aggregate top candidate edges across rows were `0xedfb379c -> 0xedfb37a8` slot 1 (`1675280`), `0xedfba790 -> 0xedfba7a8` slot 0 (`1675276`), `0x56f8f98 -> 0x56f8fa0` slot 1 (`1593888`), `0xecfb6f4c -> 0xecfb6f54` slot 1 (`368991`), and `0xedc3bda4 -> 0xedc3bdac` slot 1 (`347102`).
- Runtime validation: default Alpine runtime coverage was **83 / 83 passing** at `/workspace/tmp/ish-arm64-runtime-coverage-20260517-092759.md`.
- Next guardrail implication: candidate edge heat is now visible without loop/backward noise, but execution is still intentionally absent. Before building a first trace, add a representation/guard design tranche that defines a fail-closed trace record, guarded external exits back to fake-IP dispatch, and page invalidation ownership for every candidate segment.

Phase 4 default chained-transition cleanup tranche:

- Shortened the default `fiber_ret_chain` block-stats flag check by loading `arm64_block_stats_enabled` directly from the binary's data segment instead of going through a GOT pointer load. This removes one load from every default stats-disabled chained transition while keeping the `ISH_ARM64_BLOCK_STATS=1` callout and all existing diagnostics intact. It does not build traces, add guarded exits, alter invalidation epochs, store interior pointers in `jump_ip`, or change generated gadget streams.
- Failed speed probes kept out of the code: outgoing eager prechain (`/workspace/tmp/ish-arm64-node-bun-perf-20260517-104936.md`, **10 / 10**, `34.212s`) and eager prechain plus internal-continue/taken (`/workspace/tmp/ish-arm64-node-bun-perf-20260517-105135.md`, **10 / 10**, `35.305s`) were slower than the earlier default reference (`/workspace/tmp/ish-arm64-node-bun-perf-20260517-092629.md`, `30.837s`), so neither was promoted.
- Same-time A/B around the retained assembly shortcut was modest but favorable in aggregate: baseline default reports `/workspace/tmp/ish-arm64-node-bun-perf-20260517-121855.md` (`34.044s`) and `/workspace/tmp/ish-arm64-node-bun-perf-20260517-122116.md` (`34.078s`) versus optimized default reports `/workspace/tmp/ish-arm64-node-bun-perf-20260517-121941.md` (`33.755s`), `/workspace/tmp/ish-arm64-node-bun-perf-20260517-122041.md` (`33.689s`), and `/workspace/tmp/ish-arm64-node-bun-perf-20260517-122237.md` (`34.032s`). Treat this as a small hot-path cleanup rather than a major speedup claim.
- Focused smoke: default `/workspace/tmp/arm64-retchain-fastflag-rebased-default-20260517-123748.log` stayed `ARM64_BLOCK` silent; stats-enabled `/workspace/tmp/arm64-retchain-fastflag-rebased-stats-20260517-123748.log` emitted both `ARM64_BLOCK_STATS` and `ARM64_BLOCK_HOT_STATS`.
- Runtime validation: default Alpine runtime coverage was **83 / 83 passing** at `/workspace/tmp/ish-arm64-runtime-coverage-20260517-123758.md`.

Phase 4 bounded same-page prechain promotion tranche:

- Promoted the existing bounded same-page eager prechain path to the Linux default by making `ISH_ARM64_EAGER_PRECHAIN` and nested `ISH_ARM64_EAGER_PRECHAIN_INCOMING` default-on when their Linux `main.c` env setters are called with an absent env var. Explicit `ISH_ARM64_EAGER_PRECHAIN=0` still disables both outgoing and incoming prechain, and `ISH_ARM64_EAGER_PRECHAIN_INCOMING=0` can keep outgoing-only behavior. The iOS/app path remains unchanged because those Linux env setters are not called there.
- This is still a whole-block-start optimization, not a true trace: it patches only existing fake-IP `jump_ip` slots to exact `target->code` pointers, records the existing `jumps_from` back-reference, and relies on the normal disconnect/invalidation path to restore original fake IPs. It does not create interior pointers, trace records, guarded exits, or invalidation epoch changes.
- Failed/default-off code kept out of this tranche: a stats-preserving fused-memory inline-chain prototype built and passed Node/Bun, but the A/B did not show a stable default win, so it was reverted before promotion.
- Focused smoke: default `/workspace/tmp/arm64-prechain-default-20260517-130427.log` stayed `ARM64_BLOCK` silent; stats-enabled `/workspace/tmp/arm64-prechain-stats-20260517-130427.log` showed non-zero prechain counters (`prechain_patches=23389`, including `prechain_incoming_patches=20050`); explicit opt-out `/workspace/tmp/arm64-prechain-optout-stats-20260517-130427.log` kept all prechain counters zero.
- Node/Bun validation: promoted default `/workspace/tmp/ish-arm64-node-bun-perf-20260517-130454.md` and explicit opt-out `/workspace/tmp/ish-arm64-node-bun-perf-20260517-130528.md` were both **10 / 10 passing**. The same-binary comparison was `33.635s` promoted default versus `34.587s` opt-out, about a **2.8%** wall-clock improvement in that table. Stats-enabled default `/workspace/tmp/ish-arm64-node-bun-perf-20260517-130603.md` was also **10 / 10 passing**.
- Runtime validation: default Alpine runtime coverage was **83 / 83 passing** at `/workspace/tmp/ish-arm64-runtime-coverage-20260517-130725.md`.

Phase 4 adjacent-edge trace-record design tranche (no execution yet):

- First executable trace scope, when implemented, must be narrower than the current dry-run `delta <= 64` candidate bucket: same-page **adjacent** forward edges only (`to->addr == from->end_addr + 1`), matched direct `jump_ip` slot only, source and target both non-jetsam `fiber_block` objects, and no self-loop, backward, cross-page, indirect, syscall, barrier/atomic, or page-boundary cases. The first trace should cover one edge / two public whole-block entries only; multi-edge traces and loops remain out of scope.
- Representation must stay separate from normal block chaining. Do not store a trace pointer, trace-stream pointer, or interior gadget pointer in `jump_ip`, ret-cache continuations, `LOCAL_last_block`, or any operand consumed by `fiber_ret_chain`/`inline_chain`. A future `arm64_trace_record` should be a sidecar object owned by `struct asbestos`, keyed by `(source_block, slot, target_block)` or `(source_pc, slot, target_pc)`, with explicit state such as `entry_pc`, `target_pc`, `slot`, `page`, source/target block pointers, an `invalidate_gen` snapshot, and a retired/armed flag. Normal `jump_ip` slots continue to contain either fake IPs or exact `fiber_block->code` starts.
- Entry must fail closed before executing any trace body. Required guards: `ISH_ARM64_HOT_TRACE=1`; source and target blocks are not jetsam; the trace record is armed and its saved `invalidate_gen` matches `asbestos->invalidate_gen`; the source slot still points to the expected `target->code` (or the expected fake IP before patching, depending on the chosen hook); source and target pages still match the recorded same page; poke/timer and TLB `mem_changes` checks are satisfied using the same semantics as `fiber_ret_chain`; and the first gadget pointer to enter is non-null. Any failed guard must fall back to normal block dispatch/chaining without changing guest-visible state.
- Exits must also fail closed. All external trace exits must go through existing fake-IP / whole-block dispatch paths, not through interior pointers. If a guarded side exit is needed, it should set the guest PC to the architectural external target and return to the normal main loop or `fiber_ret_chain` with a normal fake-IP/`block->code` value. Trace execution must not skip timer/poke checks longer than the current short internal-continue budget allows.
- Invalidation ownership must be explicit before execution lands. For the first same-page trace, link each trace record into a page-owned trace list for the single covered page and into per-source/per-target cleanup links or an equivalent table that `fiber_block_disconnect()`, `asbestos_invalidate_range()`, and `asbestos_invalidate_all()` can retire. Page invalidation should retire trace records before or while disconnecting covered blocks, increment the existing invalidate generation, and guarantee that no future trace guard can dereference a jetsam'd source/target block. Multi-page trace records require separate page-link arrays and are forbidden until tested.
- Precise fault-PC rule remains unchanged: every faultable memory instruction executed from any traced segment must still set `LOCAL_jit_saved_pc` for the exact guest instruction before touching guest memory. If the first trace reuses existing block gadget streams, the trace entry mechanism must not disturb those saved-PC updates. If it emits a new data stream, it must preserve the same `gadget_set_jit_saved_pc` placement and signal recovery behavior.
- Required fixtures before any execution hook is allowed: default-off silence and iOS source/config default-off audit; trace enabled but no eligible edge fallback; adjacent eligible edge taken through trace; guard failure after source slot is restored/changed; page invalidation of source and target after trace creation; source/target jetsam cleanup with no stale trace dereference; precise load/store fault PC in the target segment; poke/timer/TLB generation fallback; and Node/Bun default plus stats-enabled reports proving `ISH_ARM64_BLOCK_STATS=1` diagnostics remain meaningful.
- Implementation ordering after this design should be: (1) dormant sidecar data structures and retire hooks with no execution, (2) targeted invalidation/retirement fixtures, (3) trace-record creation behind `ISH_ARM64_HOT_TRACE=1` but still no execution, (4) a single adjacent-edge execution hook behind `ISH_ARM64_HOT_TRACE=1` after the fail-closed guard path and fixtures pass. Do not promote any trace path to default until repeated Node/Bun and full runtime gates show a stable win.

## Validation gates

For each implementation tranche:

1. `make build-arm64-linux`.
2. Short Bun/Node perf-table run for before/after numbers.
3. Core Alpine runtime coverage (all current Alpine checks passing).
4. Targeted Bun/Node rows from runtime coverage.
5. npm CLI package lane when changes affect JSC/V8 mmap/fault behavior.

Do not treat speedups as valid if diagnostics include `SAFETY-VALVE`, fault noise, missing syscall noise, host crash messages, or forced timeouts.
