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

After Phase 1 validation, add fusions that reduce dispatch around hot object/array accesses:

- simple address-generation + load;
- simple address-generation + store;
- load + compare/test + branch.

Each memory sub-operation in a fused gadget must either set `LOCAL_jit_saved_pc` before the memory access or carry equivalent per-op fault metadata, so page faults and guest signals report the correct guest PC.

## Phase 3: linear superblocks

Build small same-page linear superblocks without profiling:

- max 2-4 basic blocks;
- max 32-64 guest instructions;
- direct known branch/fallthrough only;
- same page initially;
- stop at syscall, indirect branch, barrier/atomic, page boundary, or any instruction with uncertain invalidation/fault behavior.

Use the existing page-index invalidation path: every page touched by a superblock must invalidate that superblock.

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
3. Core Alpine runtime coverage (`49/49`).
4. Targeted Bun/Node rows from runtime coverage.
5. AI CLI npm lane when changes affect JSC/V8 mmap/fault behavior.

Do not treat speedups as valid if diagnostics include `SAFETY-VALVE`, fault noise, missing syscall noise, host crash messages, or forced timeouts.
