# iSH ARM64 — Linux on iOS via Native Threaded-Code Interpreter

**Fork of [ish-app/ish](https://github.com/ish-app/ish)** — a userspace Linux emulator for iOS.

This fork adds a **native ARM64 guest backend** to upstream iSH's threaded-code interpreter
(*Asbestos*, formerly called *jit* — renamed upstream in 2024 because it doesn't actually emit
machine code). The new backend emulates AArch64 Linux on Apple Silicon, running alongside
the original x86 (i386) guest backend. The result is a dramatically faster and more
compatible Linux environment capable of running **Python, Node.js, Go, Rust, and native
CLI tools** directly on iPhone and iPad.

> ## 🚢 Production Use
>
> This engine is shipping in **[OpenMinis](https://openminis.app)** as the **Agent Shell Sandbox**,
> where it has been **stably used by over 10,000 users** to run Linux tools and shell workloads
> on iOS. The numbers and stability claims in this README are grounded in that real-world
> deployment, not just synthetic benchmarks.

> **Naming note**: *Asbestos* is the upstream project's name for its threaded-code
> interpreter (see the upstream commit [`d375656f` "Rename the JIT"](https://github.com/ish-app/ish/commit/d375656f)
> from June 2024). It is **not a JIT** — neither Asbestos nor its predecessor emits machine
> code at runtime. For each basic block it builds an array of pointers to pre-compiled
> native "gadget" functions that tail-call one another (the technique Forth interpreters use).
>
> What this fork adds is an **ARM64 guest backend** inside that same Asbestos infrastructure:
> new gadgets (`asbestos/guest-arm64/gadgets-aarch64/`) that map AArch64 guest instructions
> to a few ARM64 host instructions each — same-architecture dispatch, so each guest
> instruction costs only a handful of host instructions. The upstream x86 backend continues
> to ship unchanged alongside it. Some prose below says "JIT" as convenient shorthand —
> read it as "same-arch gadget dispatch," not runtime codegen.

---

## Why ARM64?

The original iSH translates **x86 (i386) instructions** on an ARM64 host — every guest instruction
must be cross-architecture decoded and emulated. This works well for simple tools but creates
fundamental limits:

| Limitation | x86 (original) | ARM64 (this fork) |
|---|---|---|
| Architecture translation | i386 → ARM64 (cross) | AArch64 → AArch64 (same) |
| Address space | 32-bit (4 GB) | 48-bit (256 TB) |
| SIMD | Partial SSE/SSE2 | Full NEON + Crypto |
| Node.js / V8 | Not possible (needs >4 GB VA) | Supported |
| Go / Rust | Not possible (large VA requirements) | Supported |
| Compute overhead | 15-100x native | 3-30x native |

## Architecture Overview

```
+--------------------------------------------------------------+
|  iOS App (iSH ARM64)                                         |
|                                                              |
|  +--------------------------------------------------------+  |
|  |  Asbestos (threaded-code interpreter)                  |  |
|  |                                                        |  |
|  |   Decoder  -->  Gadget program  -->  Fiber Blocks      |  |
|  |   (gen.c)       builder              (block cache)     |  |
|  |                                                        |  |
|  |   --- 48-bit Virtual Memory (4-level page table) ---   |  |
|  |       TLB (8192 entries) + CoW + Lazy Reservations     |  |
|  +--------------------------------------------------------+  |
|                                                              |
|  +-------------------+    +-------------------------------+  |
|  |  Linux Kernel     |    |  Agent Integration            |  |
|  |  (syscalls,       |    |  - Embed host API             |  |
|  |   signals,        |    |  - Native Offload             |  |
|  |   futex, epoll)   |    |  - Bind Mounts                |  |
|  +-------------------+    |  - RootfsPatch overlay        |  |
|                           +-------------------------------+  |
|  +-------------------+                                       |
|  |  Filesystem       |                                       |
|  |  fakefs + realfs  |                                       |
|  |  + bind mounts    |                                       |
|  +-------------------+                                       |
+--------------------------------------------------------------+
```

---

## Key Changes from Upstream

### 1. ARM64 Guest Backend inside Asbestos

This fork's main contribution. It plugs into upstream Asbestos (the existing threaded-code
interpreter) and replaces the per-instruction cost model: for each guest basic block the new
backend builds a **gadget program** — an array of `unsigned long` values alternating pointers
to pre-compiled ARM64 gadget functions with inline operands. Execution is a chain of tail
calls — each gadget loads the next pointer from the program stream and branches to it
(`br x8`). No executable memory is allocated, no machine code is generated at runtime.
The host-code overhead per guest instruction is a few ARM64 instructions inside the
corresponding gadget.

**Key files:**
- `asbestos/asbestos.c` — Block cache, block management, RCU-like jetsam cleanup
- `asbestos/guest-arm64/gen.c` — Instruction decoder + gadget program builder (~200+ opcodes)
- `asbestos/guest-arm64/gadgets-aarch64/` — Hand-written ARM64 assembly gadgets:
  - `entry.S` — fiber_enter/exit, crash recovery trampoline
  - `memory.S` — Load/store with inline TLB lookup (~12 instructions fast path)
  - `control.S` — Branches, conditionals, fused compare-and-branch
  - `math.S` — Arithmetic, shifts, bit manipulation, NEON/SIMD
  - `crypto.S` — AES, SHA, CRC32 instructions

**Design highlights:**
- **Block chaining**: Sequential basic blocks link directly, skipping dispatch overhead
- **Persistent TLB**: 8192-entry TLB survives across syscalls (not flushed on every entry)
- **Crash recovery**: SIGSEGV inside a gadget redirects to a trampoline for CoW resolution
- **Full NEON**: All 128-bit SIMD operations including crypto extensions

### 2. 48-bit Virtual Address Space

4-level page table (L0→L1→L2→L3, 9 bits each = 36-bit page number + 12-bit offset = 48 bits).

- Supports V8's 128GB+ pointer cage (via `MAP_NORESERVE` lazy reservations)
- Go's large virtual address requirements for heap/stack
- Guard pages at 0x0-0x100000 for V8 compressed pointer safety
- Layout kept compact (stack at `0xffffe000`, mmap at `0xefffd`) for TLB efficiency

**Key files:** `kernel/memory.h`, `kernel/memory.c`, `emu/tlb.h`

### 3. Node.js / V8 Support

Running Node.js on a userspace emulator required solving multiple V8-specific problems:

- **128GB MAP_NORESERVE**: Lazy address reservations that don't consume physical memory
- **Guard pages at 0x0-0x100000**: V8 compressed pointers dereference small integers —
  mapping the low 1MB as readable zeros prevents SIGSEGV
- **V8 binary patch**: 9-instruction code cave patch for `InterpreterEntryTrampoline`
  derived constructor bug (zero emulator overhead)
- **`--jitless --no-lazy`**: V8 flags to avoid Wasm compilation and lazy parsing issues
- **Exit cleanup**: Safety valves for stuck V8 threads during process exit

**Result**: `npm install`, `npm exec`, `npx`, and `create-next-app` all work.

### 4. Runtime Integration

#### Native Offload (`kernel/native_offload.c`)

Bypass emulation entirely for registered binaries. Guest `execve()` is intercepted and
routed to a native handler or host binary:

```c
// Register handler (call once at startup)
native_offload_add_handler("ffmpeg", ffmpeg_main);

// Now guest `ffmpeg -i input.mp4 output.mp3` runs natively
// Arguments auto-translated from guest paths to host paths
```

Supports both in-process handlers (iOS + macOS) and `posix_spawn` delegation (macOS CLI).

#### Bind Mounts (`fs/fake.c`)

Mount host directories into the guest filesystem:

```c
// Read-only bind mount of host directory
fakefs_bind_mount("/host/path/to/data", "/mnt/data", /*read_only=*/true);
```

Enables AI agents to share files between the host app and the Linux guest without copying.

### 5. Rootfs Management

- **Alpine 3.21 aarch64** with full apk package manager
- **RootfsPatch.bundle**: Versioned overlay system for incremental rootfs updates
- **Polyfills**: WebAssembly polyfill for undici/llhttp, fetch polyfill for HTTP downloads
- **OPENSSL_armcap=0** and **GODEBUG/GOMAXPROCS** injection in `sys_execve`

---

## Build Configuration

| Target | Scheme | xcconfig | Guest Arch | Bundle ID Suffix |
|--------|--------|----------|------------|------------------|
| ARM64 | iSH | `App.xcconfig` / `AppARM64.xcconfig` | aarch64 | — |
| ARM64 + FFmpeg | iSH-ARM64-ffmpeg | `AppARM64-ffmpeg.xcconfig` | aarch64 | `.arm64` |

The ARM64 target links meson-built libraries (`libish.a`, `libish_emu.a`, `libfakefs.a`) directly
from `build-arm64-release/`, bypassing Xcode's auto-discovery of x86 library targets.

```bash
# Build ARM64 CLI (macOS, for testing)
meson setup build-arm64-release --buildtype=release
ninja -C build-arm64-release

# Run
./build-arm64-release/ish -f ./alpine-arm64-fakefs /bin/sh
```

### Linux build + SDL/VNC debug harness

For Linux-side debugging and interactive bring-up, the repository also includes a
native Linux build path plus an SDL/VNC PTY harness similar to the other local
emulator projects.

```bash
# Build the Linux host binary
CC=clang meson setup build-arm64-linux --buildtype=release
ninja -C build-arm64-linux

# Build the Linux SDL/VNC harness (requires SDL2, SDL2_ttf, libvterm, libvncserver)
CC=clang meson setup build-linux-harness
ninja -C build-linux-harness tools/ish-sdl-vnc

# Run it against an existing ish binary + fakefs
./tools/run-sdl-vnc.sh
```

Defaults used by `tools/run-sdl-vnc.sh`:

- `ISH_BIN=./build-arm64-linux/ish`
- `ROOTFS_DIR=./alpine-arm64-fakefs`
- `VNC_PORT=5907`

The harness launches `ish` under a PTY, renders the terminal via SDL, and exports
same framebuffer over VNC for remote debugging.

### Runtime coverage harness

The local Linux bring-up flow is now captured in the top-level `Makefile` and the
staged coverage script `tests/arm64/runtime-coverage.sh`. Meson is still the
source of truth for build configuration; the Makefile only records the repeatable
commands used during ARM64 runtime debugging.

```bash
# Build both Linux host binaries used for release/debug comparisons
make build-arm64-linux-all

# Run the staged runtime suite against the release binary
make test-arm64-runtime-coverage

# Re-run the same suite against the debug binary when investigating failures
make test-arm64-runtime-coverage-debug
```

Useful knobs:

```bash
make test-arm64-runtime-coverage \
  ROOTFS_DIR=$PWD/alpine-arm64-fakefs \
  REPORT_DIR=/workspace/tmp \
  TIMEOUT_S=120 \
  INSTALL_TIMEOUT_S=1200
```

The coverage script currently exercises, in order:

1. base shell/apk/tmp file I/O sanity checks;
2. a C toolchain smoke test (`gcc --version`, compile, execute);
3. SysV shared-memory/message-queue IPC across `fork()`;
4. high-value syscall gap and socket ABI coverage (`signalfd4`, SysV semaphores, POSIX mqueues, `memfd_create`, `openat2`, `faccessat2`, `preadv2`, `pwritev2`, `process_vm_*`, UDP `sendto`/`recvfrom`, `getsockname`, `setsockopt`, `getsockopt`);
5. ARM64 `DCZID_EL0` / `dc zva` sysreg and instruction coverage;
6. ARM64 signal `ucontext_t` layout and null-SIGSEGV delivery coverage;
7. ARM64 `CCMP`/`CCMN` condition-code-15 (`NV`) coverage;
8. ARM64 `DMB`/`DSB`/`ISB` barrier decoding/execution coverage;
9. ARM64 self-modifying-code/code-patch invalidation coverage;
10. Per-thread `sigaltstack` coverage for pthread/Go-style signal stacks;
11. Go (`go version`, `go env`, `go tool compile`, `go run`, `go build`, `go test`);
12. Bun (`bun --version`, local `file:` dependency install, TypeScript run, test, build);
13. Node/npm (`node --version`, `node -e`, `npm --version`, `npm run`);
14. Python (`python3 --version`, eval) and Lua (`lua5.4 -v`, eval);
15. Java (`javac` + default mixed-mode `java`, interpreter fallback) and Clojure (`clojure.main` eval);
16. PyPy and Swift Alpine aarch64 availability probes;
17. Rust (`rustc --version`, direct compile/run, optimized std runtime, `rustc --test`, Cargo build/run/test with threads, atomics, channels, file I/O, TCP loopback, and child processes);
18. Erlang (`erl -version` BEAM startup smoke);
19. Zig (`zig version`, `zig build-obj`, linked object execution through a C harness).

Each run writes a Markdown report named
`ish-arm64-runtime-coverage-YYYYMMDD-HHMMSS.md` under `REPORT_DIR`. The suite is
intentionally red during bring-up: failures are treated as emulator/runtime bugs
to debug, not as cases to skip.

Current Linux-host status from this pass:

- Latest staged run: **49 / 49 passing** (`/workspace/tmp/ish-arm64-runtime-coverage-20260513-203532.md`, `TIMEOUT_S=180`, `INSTALL_TIMEOUT_S=300`).
- Production package baseline: [docs/ARM64_PRODUCTION_BASELINE.md](docs/ARM64_PRODUCTION_BASELINE.md) (`alpine-arm64-fakefs` on Alpine 3.23.4 with OpenJDK 21.0.10_p7-r0; current audit tag `arm64-openjdk21-prod-20260510-r5`).
- Non-trivial workload probes are grouped in [docs/ARM64_WORKLOAD_SMOKE_TESTS.md](docs/ARM64_WORKLOAD_SMOKE_TESTS.md): Bun/PiClaw, `rcarmo/go-gte`, and the Benchmarks Game rows.
- C coverage is green: `gcc --version`, compile, and execute all pass.
- SysV IPC coverage is green: shared memory and message queues work across `fork()`.
- High-value syscall gap and socket ABI coverage is green: `signalfd4`, SysV semaphores, POSIX mqueues, `memfd_create`, `openat2`, `faccessat2`, `preadv2`, `pwritev2`, `process_vm_*`, UDP `sendto`/`recvfrom`, `getsockname`, `setsockopt`, and `getsockopt` pass in the staged C fixture.
- ARM64 DC ZVA coverage is green: `DCZID_EL0` reports a 64-byte block and `dc zva` zeros the expected naturally aligned block.
- ARM64 signal ucontext coverage is green: guest SIGSEGV handlers see `uc_mcontext` at offset 176 with correct PC/SP/LR, and null read faults reach handlers instead of being converted to zero loads.
- ARM64 conditional-compare coverage is green: `CCMP`/`CCMN` with condition code 15 (`NV`) now follows AArch64 hardware and performs the compare instead of taking the false-immediate path.
- ARM64 barrier coverage is green: `DMB`, `DSB`, and `ISB` decode to distinct host synchronization gadgets; folded CRm domains use conservative full-system host barriers.
- ARM64 self-modifying-code coverage is green: writes to a previously translated RWX page invalidate stale translated blocks before a subsequent indirect call executes the patched bytes.
- Go coverage is green: `go version`, `go env`, `go tool compile`, `go run`,
  `go build` + execute, `go test`, and Benchmarks Game Go 10/10 all pass; iSH now keeps `sigaltstack` state per thread so Go signal handlers use the correct M/thread signal stack.
- Bun coverage is green: `bun --version`, local `file:` dependency install,
  TypeScript run, `bun test`, and `bun build` all pass. The local `file:`
  install allocator/free-list crash has been regression-tested with 50
  consecutive `RC:0` runs, and `bun -e "console.log(1)"` passed 20 consecutive
  repro runs after the GC shims. `setTimeout`, a minimal `Bun.serve` server,
  and a PiClaw YOLO direct install/web startup smoke also passed.
- Node/npm coverage is green: `node --version`, `node -e`, `npm --version`, and
  `npm run` pass without the previous noisy `pwritev` stubs.
- Python and Lua smoke coverage is green: `python3 --version`, Python eval,
  `lua5.4 -v`, and Lua eval all pass.
- Java and Clojure smoke coverage is green: default mixed-mode `javac`/`java`,
  Java interpreter fallback, and `clojure.main` eval all pass.
- PyPy and Swift availability probes are green by recording that Alpine 3.23
  aarch64 currently has no packaged PyPy or Swift toolchain in the index.
- Rust coverage is green for direct `rustc` and Cargo paths: version, compile/run, optimized std runtime, `rustc --test`, Cargo build/run/test, threads, atomics, channels, file I/O, TCP loopback, and child processes pass without safety-valve or NETDIAG noise.
- Erlang coverage is green for BEAM startup/version (`erl -version`). Fuller
  `erl -noshell`/`erlc` module execution remains follow-up work.
- Zig coverage is green for compiler/object paths: version, `zig build-obj`, and
  linked object execution through a C harness pass. `zig test` is kept out of the
  gate because Alpine Zig 0.15.2 fails compiler-rt `f16` comptime compilation
  before guest code runs; this is tracked separately from emulator execution.
- Fixed lazy `MAP_NORESERVE` reservation permissions: `mprotect()` now updates
  reservation metadata, so later demand faults materialize pages with the new
  permissions. This fixed the Node/V8 `0xb00c0000` write fault.
- High ARM64 mmap hints are honored again when they fit in the 48-bit guest
  address space. Bun/JSC heap/cage code stores pointers derived from returned
  high mappings; silently relocating these reservations into low memory corrupts
  allocator metadata.
- Large anonymous `MAP_NORESERVE` arenas are now placed in the high 48-bit address space first, instead of burning the low 4GB mmap window. This removes Bun/JSC startup `ENOMEM` on repeated 1-8GB arena probes.
- Fixed the pair-exclusive `STXP/STLXP` gadget clobbering `_pc` (`x28`) while
  loading the expected high word. The standalone `tests/arm64/atomics/ldxp-stlxp.c` now covers both 64-bit and 32-bit pair exclusives and passes.
- Fixed `CAS`/`CASP` decode separation so pair exclusives are no longer misdecoded as single-register CAS. The standalone `tests/arm64/atomics/cas128.c` now passes.
- Fixed ARM64 `CLREX` handling: it now clears both single and pair exclusive monitor state instead of being treated as a NOP, so `STXR`/`STXP` after `CLREX` fail as required.
- Added standalone `tests/arm64/atomics/clrex-stxr.c` coverage for `CLREX` + `STXR`/`STXP` failure semantics (32/64-bit single + pair).
- Fixed `LDXR` size dispatch to use size-matched TLB prep/cross-page paths (8/16/32/64) instead of always routing through 32-bit prep.
- Added standalone `tests/arm64/atomics/ldxr-widths.c` coverage for `LDXRB`/`LDXRH`/`LDXR W`/`LDXR X` near page-end addresses.
- Added trace-gating controls (`ISH_TRACE_GATE_PC`, `ISH_TRACE_GATE_X4`, `ISH_TRACE_GATE_BUDGET`) plus block-entry tracepoints for replay triage; this made it possible to isolate the deterministic crash path through `libjvm+0x34710c`/`+0x3471e4` where iSH returns slot-index-1 (`[x5+936]=1`) object `0xc99b6fd8` before the later `libjvm+0x80334c` null dereference.
- Fixed ARM64 `LDPSW` pair-load decoding/execution. GPR pair opcode `opc=01,L=1` is now handled as sign-extending `LDPSW` rather than zero-extending `LDP W`, and unallocated GPR pair encodings are rejected. This clears the deterministic HotSpot C2 replay crash for `ConcurrentHashMap::tabAt` and lets default mixed-mode `javac Hello.java` complete.
- Added standalone `tests/arm64/loadstore/ldpsw-pair.c` coverage for signed-offset and post-indexed `LDPSW`, including a cross-page pair load.
- Gated ARM64 guest SIGSEGV stack/map dumps behind `ISH_TRACE_FAULTS` so runtimes that deliberately handle null/check traps (HotSpot included) no longer emit production noise by default.
- Stopped advertising optional crypto/LSE features in `AT_HWCAP` until those helper sets are fully coverage-clean; runtimes can fall back to baseline FP/ASIMD paths.
- Added `LDNP`/`STNP` handling by treating non-temporal pair loads/stores like ordinary no-writeback pair transfers. This removes the `0xa8007c3f` illegal-instruction trap seen in Bun TypeScript runs.
- Hardened production-adjacent launch/logging paths during the final audit: bounded `printk`/`die`, exact mount-option token parsing, bounded initial argv construction, safe `PT_INTERP` loading, shebang optional-argument trimming, and safe ptraceomatic `TERM` environment construction.
- Added ARM64 `preadv`/`pwritev` implementations and wired syscalls 69/70 to
  remove Node/npm fallback noise.
- Reclassified the earlier `HIGHBITS pc=0xefec3698` noise as an invalid
  diagnostic invariant, not an emulator failure by itself. At
  `/lib/ld-musl-aarch64.so.1` `_dlstart+0x15c`, musl executes
  `ldr x3, [x5,#8]` and intentionally loads a 64-bit relocation word such as
  `0x66900000401`, then immediately masks it with `and x3, x3, #0x7fffffff`.
  Because normal AArch64 code can keep 64-bit tagged/masked values in GP
  registers, the per-instruction high-bit tracer is opt-in via
  `ISH_TRACE_HIGHBITS=1` instead of enabled for every runtime run.
- Fixed the Bun/JSC freelist corruption by making ARM64 JIT memory-fault retry
  precise. Faultable load/store instructions now record the current guest PC in
  `fiber_frame::jit_saved_pc`; async host SIGSEGV/SIGBUS recovery and
  TLB/cross-page `INT_GPF` exits retry at that instruction instead of the block
  start. This prevents a fault at `4897440: str x10, [x11]` from restarting at
  `4897430: madd x11, x1, x11, x1` after `x11` has been repurposed as the
  freelist loop pointer.
- Fixed the follow-on Bun script/timer/server execution hangs with conservative
  JavaScriptCore GC shims: `JSC_numberOfGCMarkers=1` and
  `JSC_useConcurrentGC=0` are injected for ARM64 guest processes. The first
  avoids the parallel marker signal-suspend handshake spinning on marker threads
  parked in futex/syscall context; the second keeps Bun timers and `Bun.serve`
  progressing reliably while preserving GC.
- Tightened ARM64 signal ABI details found during the same trace: `siginfo_t` now
  includes the 64-bit Linux padding before `_sifields`, `tkill`/`tgkill` deliver
  `SI_TKILL`, and syscall 240 (`rt_tgsigqueueinfo`) is no longer accidentally
  wired to `rt_sigreturn`.
- Fixed `getdents64` `d_type` reporting for realfs/fakefs/tmpfs/proc/devpts. Bun
  `fs.cpSync(..., {recursive:true})` uses directory-entry types while walking
  trees; returning `DT_UNKNOWN` caused PiClaw's bootstrap copy of `.pi/skills`
  to try `copyfile` on subdirectories and fail with `ENOTSUP`.

Immediate plan:

1. keep the Makefile target as the single command for coverage regressions;
2. run longer Bun/npm workloads to find the next post-coverage failure instead
   of expanding the suite blindly;
3. finish optional crypto/LSE helper validation before re-advertising those HWCAP bits;
4. revisit JSC parallel/concurrent GC suspension if/when we need to remove the
   `JSC_numberOfGCMarkers=1` / `JSC_useConcurrentGC=0` compatibility shims.

### Host ABI notes

The Linux build now makes the host-specific ABI seams explicit instead of assuming
Darwin-only structures and APIs:

- `platform/host_context_aarch64.h` normalizes the AArch64 signal/ucontext ABI
  used by JIT crash recovery on macOS and Linux.
- `platform/platform.h` now exposes host fd-path lookup, stat timestamps, random
  bytes, `sysinfo`, per-thread CPU usage, thread naming, and memory-pressure
  hooks with Linux and Darwin implementations.
- remaining host-specific branches in native offload, sockets/polling, and low-level synchronization are documented as future cleanup candidates rather than part of the Java/OpenJDK production path.

See also:

- `docs/LINUX_BUILD_AND_HOST_ABI.md`

---

## Workload Validation

This tree is ARM64-only. The active workload checks live under `tests/arm64/`
and the current validation notes are in:

- `docs/ARM64_WORKLOAD_SMOKE_TESTS.md`
- `docs/ARM64_SMOKE_ISSUES_AND_SYSCALL_COVERAGE.md`
- `tests/arm64/runtime-coverage.sh`

The embedded Litter acceptance path is `embed/host/tests/acceptance.rs`, which
boots an aarch64 Alpine fakefs and verifies `/bin/sh`, Python, Node/npm, Go, and
a basic Cargo/Rust workload.

---

## Supported Software

### Fully Working

| Category | Examples |
|----------|---------|
| **Package managers** | apk, pip, npm, npx, uv |
| **Languages** | Python 3, Node.js 22, Go, Perl, Ruby, Lua |
| **Dev tools** | git, curl, wget, ssh, vim, nano |
| **Build tools** | gcc, g++, cmake, make, meson |
| **Data tools** | sqlite3, jq, yt-dlp, ffmpeg (via native offload) |
| **Network** | curl, wget, dig, netstat, ss |
| **Node frameworks** | Express, Koa, Fastify, Axios, Socket.io |
| **npm ecosystem** | lodash, moment, dayjs, uuid, chalk, commander, glob, semver |

### Not Supported

- **GUI applications** (no X11/Wayland)
- **Docker / containers** (no kernel namespace support)
- **Kernel modules** (userspace emulator)
- **Hardware access** (no /dev/gpu, no USB passthrough)

---

## Commit History

This branch has accumulated a focused ARM64 bring-up stack on top of upstream iSH; exact commit/file counts vary as the production audit is rebased and documented, so treat the list below as the durable milestone map rather than a static diffstat.

Major milestones:
1. **Interpreter foundation**: fiber_enter/exit, basic block compilation (to gadget program), TLB
2. **Instruction coverage**: 200+ ARM64 opcodes including full NEON/Crypto
3. **48-bit address space**: 4-level page table, lazy reservations
4. **Node.js support**: V8 guard pages, MAP_NORESERVE, binary patch, exit cleanup
5. **Go support**: Signal frame alignment, per-thread `sigaltstack`, sigreturn fixes, NZCV preservation
6. **Rust/uv support**: FUTEX_WAIT_BITSET, PMULL, BFM, demand-mapped reads
7. **Runtime integration**: embed host API, native offload, bind mounts, rootfs overlay
8. **Stability**: 50+ bug fixes for concurrency, memory leaks, use-after-free, deadlocks

---

## Project Structure

```
iSH/
├── asbestos/                    # ARM64 threaded-code interpreter
│   ├── asbestos.c/h             # Block cache, RCU cleanup
│   └── guest-arm64/
│       ├── gen.c                # Instruction decoder → gadgets
│       ├── crypto_helpers.c     # AES/SHA/CRC32 helpers
│       └── gadgets-aarch64/     # Assembly gadgets
│           ├── entry.S          # Fiber enter/exit, crash handler
│           ├── memory.S         # Load/store, TLB inline lookup
│           ├── control.S        # Branches, conditionals
│           ├── math.S           # ALU, shifts, NEON/SIMD
│           ├── crypto.S         # AES, SHA, PMULL, CRC32
│           ├── bits.S           # Bitfield operations
│           └── gadgets.h        # Register map, TLB macros
├── emu/
│   ├── tlb.c/h                  # TLB miss handling, cross-page
│   └── arch/arm64/
│       ├── cpu.h                # CPU state (regs, NEON, flags)
│       └── decode.h             # Instruction field extraction
├── kernel/
│   ├── arch/arm64/calls.c       # ARM64 syscall table
│   ├── memory.c/h               # Page table, CoW, fault handling
│   ├── mmap.c                   # mmap, lazy reservations
│   ├── native_offload.c/h       # Binary offload system
│   ├── signal.c/h               # Signal delivery/frame
│   ├── futex.c                  # Futex with pipe wakeup
│   ├── exec.c                   # ELF loader, V8 guard pages
│   └── exit.c                   # Thread cleanup, safety valves
├── fs/
│   ├── fake.c/h                 # fakefs + bind mount support
│   ├── real.c                   # Host filesystem access
│   ├── sock.c/h                 # Socket emulation
│   └── poll.c                   # epoll/poll/select
├── app/
│   ├── AppARM64.xcconfig        # ARM64 build config
│   ├── GuestARM64.xcconfig      # Guest arch definition
│   └── RootfsPatch.bundle/      # Versioned rootfs overlay
└── tests/arm64/
    ├── runtime-coverage.sh       # Full ARM64 runtime coverage script
    ├── atomics/                  # Focused atomic instruction fixtures
    ├── loadstore/                # Load/store fixtures
    └── benchmarksgame/           # ARM64 workload smoke scripts
```

---

## License

Same as upstream iSH. See [LICENSE](LICENSE.md).
