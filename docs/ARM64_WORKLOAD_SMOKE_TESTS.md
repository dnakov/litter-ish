# ARM64 iSH workload smoke tests

Updated: 2026-05-13

## Purpose

This file is the single index for non-trivial workloads we use to harden the ARM64 iSH Linux-host fakefs. The goal is to move beyond tiny instruction reproducers and run real language runtimes, package managers, compilers, filesystem walkers, network servers, and SIMD-heavy applications that resemble what users actually do inside iSH.

Current issue disposition and syscall coverage appraisal: [ARM64_SMOKE_ISSUES_AND_SYSCALL_COVERAGE.md](ARM64_SMOKE_ISSUES_AND_SYSCALL_COVERAGE.md).

A workload belongs here when it exercises at least one of these boundaries:

- Linux syscall fidelity: `mmap`, `mprotect`, `clone`, futexes, signals, timers, vector I/O, directory walking, sockets, file metadata, and `/proc` probes.
- ARM64 instruction coverage: baseline integer/FP, atomics, AdvSIMD/NEON, FP conversion, and guest fault retry correctness.
- Runtime stress: GC, JIT/AOT assumptions, thread scheduling, high-address mappings, memory reservation, and package manager filesystem behavior.
- Reproducibility: the workload can be rerun from a command line in the Linux-host harness and can produce a concise pass/fail log.

## Current workload groups

| Workload | Current status | Why it was chosen | Latest useful log/report |
|---|---:|---|---|
| Staged runtime coverage | Passing, 49/49 | Fast regression gate for shell, `apk`, tmp I/O, C, SysV IPC, high-value syscall gap and UDP/socket-option coverage, ARM64 DC ZVA coverage, ARM64 signal-ucontext and per-thread `sigaltstack` coverage, ARM64 CCMP/CCMN NV-condition coverage, ARM64 DMB/DSB/ISB barrier coverage, ARM64 self-modifying-code invalidation coverage, Go, Bun, Node/npm, Python, Lua, Java, Clojure, PyPy/Swift availability probes, Rust, Erlang, and Zig. Catches broad syscall/runtime regressions before heavier probes. | `/workspace/tmp/ish-arm64-runtime-coverage-20260513-203532.md` |
| Bun + PiClaw bootstrap/server | Passing for install/start/web listen | Exercises modern JS runtime behavior: high `mmap` reservations, JSC GC signaling/timers, recursive package/workspace copies, sockets, HTTP serving, and PiClaw's startup probes. | `/workspace/tmp/piclaw-yolo-run-enotsup-fixed.log` and exposed server logs |
| `rcarmo/go-gte` | Model conversion, `go test ./...`, and `make run-go` passing; `make go-build` still has upstream missing `cmd/test_gte` | Exercises Go toolchain, Python wheels, safetensors/numpy model conversion, 128 MB binary model I/O, FP16→FP32 AdvSIMD conversion, NEON math kernels, and Go runtime scheduling. | `docs/GO_GTE_PROGRESS.md`, `/workspace/tmp/go-gte-smoke-20260513-1500.log` |
| Benchmarks Game suite | GCC, G++, Go, Python, Node.js, PHP, Perl, Ruby, and Lua rows passing 10/10; Java-equivalent probe passing 10/10 in default mixed mode and interpreter fallback mode; source/language feasibility mapped | Broad cross-language benchmark corpus covering allocation, recursion, numeric FP, regex/text throughput, big integers, stdout/stdin streams, native compilers, managed runtimes, native compilers, SIMD portability, IPC, shared memory, and package availability. | [BENCHMARKSGAME_MATRIX.md](BENCHMARKSGAME_MATRIX.md), [BENCHMARKSGAME_GCC_SMOKE.md](BENCHMARKSGAME_GCC_SMOKE.md), [BENCHMARKSGAME_GPP_SMOKE.md](BENCHMARKSGAME_GPP_SMOKE.md), [BENCHMARKSGAME_GO_SMOKE.md](BENCHMARKSGAME_GO_SMOKE.md), [BENCHMARKSGAME_PYTHON_SMOKE.md](BENCHMARKSGAME_PYTHON_SMOKE.md), [BENCHMARKSGAME_NODE_SMOKE.md](BENCHMARKSGAME_NODE_SMOKE.md), [BENCHMARKSGAME_PHP_SMOKE.md](BENCHMARKSGAME_PHP_SMOKE.md), [BENCHMARKSGAME_PERL_SMOKE.md](BENCHMARKSGAME_PERL_SMOKE.md), [BENCHMARKSGAME_RUBY_SMOKE.md](BENCHMARKSGAME_RUBY_SMOKE.md), [BENCHMARKSGAME_LUA_SMOKE.md](BENCHMARKSGAME_LUA_SMOKE.md), [BENCHMARKSGAME_JAVA_EQUIVALENT_SMOKE.md](BENCHMARKSGAME_JAVA_EQUIVALENT_SMOKE.md) |

## Staged runtime coverage

Command:

```sh
make test-arm64-runtime-coverage REPORT_DIR=/workspace/tmp TIMEOUT_S=120 INSTALL_TIMEOUT_S=300
```

Latest result:

```text
49 / 49 passing
report: /workspace/tmp/ish-arm64-runtime-coverage-20260513-203532.md
```

Why it matters:

- Establishes the guest can boot, run shell commands, update package indexes, and do basic file I/O.
- Confirms C compile/execute, SysV shared-memory/message-queue IPC across `fork()`, high-value syscall gaps, UDP/socket-option receive and length handling, per-thread `sigaltstack`, Go compile/run/build/test paths, and broad language smoke coverage through Java/Clojure/Python/Lua/Rust/Erlang/Zig.
- Keeps ARM64 generated-code-sensitive fixtures in the standard gate, including DC ZVA, signal `ucontext_t`, CCMP/CCMN `NV`, DMB/DSB/ISB barriers, self-modifying-code invalidation, and Zig object-code generation/link execution.
- Keeps Bun, Node/npm, Python, Lua, Java, Clojure, PyPy/Swift availability probes, Rust, Erlang, and Zig smoke coverage in the standard gate so runtime/toolchain regressions are caught quickly. Current Rust coverage includes direct `rustc` compile/run, optimized std runtime, `rustc --test`, Cargo build/run/test, threads, atomics, channels, file I/O, TCP loopback, and child processes; Erlang coverage is BEAM version startup; Zig coverage uses `zig build-obj` plus a linked C harness while `zig test` is excluded pending the Alpine Zig 0.15.2 compiler-rt `f16` issue.

## Bun + PiClaw workload

Validated result:

```text
NO_ENOTSUP
Web UI listening ... port 18093
READY
```

Bugs exposed and fixed:

- Precise ARM64 memory-fault retry for Bun/JSC allocator correctness.
- Conservative JSC GC/timer shims for guest signal-delivery behavior.
- `REV16` SIMD support for Bun startup paths.
- `getdents64` `d_type` reporting so Bun recursive `fs.cpSync()` no longer attempts `copyfile` on directories during PiClaw bootstrap.

Why it matters:

- PiClaw is a real workspace application, not a synthetic microbenchmark.
- It stresses recursive filesystem copies, package-manager-installed trees, HTTP sockets, runtime worker startup, background indexing, SQLite, and `/proc`/CPU information fallbacks.

## go-gte workload

Detailed progress: [`docs/GO_GTE_PROGRESS.md`](GO_GTE_PROGRESS.md).

Validated in guest:

```sh
cd /tmp/go-gte
python3 convert_model.py models/gte-small gte-small.gtemodel
make run-go
```

Current key result:

```text
Model saved to gte-small.gtemodel
File size: 127.51 MB
CONVERT_RC:0

Model loaded in 5.64 s
Embedding dimension: 384
Max sequence length: 512
```

Bug exposed and fixed:

- Missing AdvSIMD `FCVTL`/`FCVTL2` support. `numpy`/safetensors conversion trapped on `fcvtl v30.4s, v31.4h`; the emulator now handles H→S and S→D widening conversions.

Patched upstream status:

- go-gte `d908cdb` fixes the direct ARM64 `SgemmNT` test failures by completing the `F0`→`F20` rename. `GTE_MODEL_PATH=gte-small.gtemodel go test -count=1 ./...` now passes inside iSH.
- `make run-go` passes.
- `make go-build` still references missing `./cmd/test_gte`; this is a repository Makefile issue rather than an iSH failure.

## Benchmarks Game as the next test case

Source site:

- <https://benchmarksgame-team.pages.debian.net/benchmarksgame/>
- Source repository: <https://salsa.debian.org/benchmarksgame-team/benchmarksgame>

The current site advertises 10 active benchmark families and 26 language/runtime labels through the performance pages. The generated full matrix is in [BENCHMARKSGAME_MATRIX.md](BENCHMARKSGAME_MATRIX.md). Execution rows passing so far: GCC ([BENCHMARKSGAME_GCC_SMOKE.md](BENCHMARKSGAME_GCC_SMOKE.md)), G++ ([BENCHMARKSGAME_GPP_SMOKE.md](BENCHMARKSGAME_GPP_SMOKE.md)), Go ([BENCHMARKSGAME_GO_SMOKE.md](BENCHMARKSGAME_GO_SMOKE.md)), Python ([BENCHMARKSGAME_PYTHON_SMOKE.md](BENCHMARKSGAME_PYTHON_SMOKE.md)), Node.js ([BENCHMARKSGAME_NODE_SMOKE.md](BENCHMARKSGAME_NODE_SMOKE.md)), PHP ([BENCHMARKSGAME_PHP_SMOKE.md](BENCHMARKSGAME_PHP_SMOKE.md)), Perl ([BENCHMARKSGAME_PERL_SMOKE.md](BENCHMARKSGAME_PERL_SMOKE.md)), Ruby ([BENCHMARKSGAME_RUBY_SMOKE.md](BENCHMARKSGAME_RUBY_SMOKE.md)), and Lua ([BENCHMARKSGAME_LUA_SMOKE.md](BENCHMARKSGAME_LUA_SMOKE.md)) across all 10 benchmark families:

| Benchmark | Why it exercises iSH |
|---|---|
| `binarytrees` | Allocation churn, recursion, GC, memory pressure, thread/runtime scheduling in some languages. |
| `fannkuchredux` | Integer-heavy loops, array mutation, native-code tight loops, bounds-check behavior. |
| `fasta` | Large stdout streams, string/byte generation, buffered I/O. |
| `knucleotide` | Hash tables, string slicing, stdin parsing, large text processing. |
| `mandelbrot` | Floating-point numeric loops, output encoding, SIMD/compiler optimization exposure. |
| `nbody` | Floating-point math and long-running numeric loops. |
| `pidigits` | Big integers, arbitrary precision libraries, stdout formatting. |
| `regexredux` | Regex engines, large stdin, text substitution throughput. |
| `revcomp` | Large stdin/stdout, byte transforms, streaming text processing. |
| `spectralnorm` | Floating-point kernels, numerical stability, compiler/runtime math paths. |

### Language/runtime feasibility on Alpine aarch64

Canonical generated matrix: [BENCHMARKSGAME_MATRIX.md](BENCHMARKSGAME_MATRIX.md). Regenerate it with:

```sh
tests/arm64/benchmarksgame/generate-matrix.py
```

Official labels observed in the site pages and first-pass Alpine 3.23 aarch64 package feasibility:

| Label | Guest feasibility | Notes |
|---|---:|---|
| `gcc` | ready | `gcc` package. |
| `gpp` | ready | `g++` package. |
| `gnat` | ready | `gcc-gnat` package is available. |
| `go` | ready | `go` package already validated. |
| `rust` | ready-large | `rust`/`cargo` available; expect large install and compile times. |
| `python3` | ready | Already validated. |
| `node` | ready | `nodejs`/`npm` already validated. |
| `php` | ready | `php84` package available. |
| `perl` | ready | `perl` available. |
| `ruby` | ready | `ruby` available. |
| `lua` | ready | Use `lua5.3` for the Benchmarks Game row because official LGMP `pidigits` variants require Lua < 5.4; `lua5.4` is still available for non-LGMP smoke. |
| `ghc` | ready-large | `ghc` available; large install/runtime. |
| `ocaml` | ready-large | `ocaml` available. |
| `sbcl` | ready-large | `sbcl` available. |
| `racket` | ready-large | `racket` available. |
| `csharpaot` | partial/external | `dotnet` packages exist, NativeAOT workload not yet verified. |
| `fsharpcore` | partial/external | `dotnet` packages exist, F# SDK/workload not yet verified. |
| `erlang` | ready-large | `erlang27` is available and BEAM startup/version is covered by staged runtime coverage; a full Benchmarks Game Erlang row is not run yet. |
| `chapel` | blocked | No Alpine aarch64 package found. |
| `dartexe` | blocked | No Dart SDK package found; only `dart-sass-js`. |
| `fpascal` | blocked | No Free Pascal package found. |
| `graalvmaot` | blocked/external | No GraalVM AOT package found. OpenJDK can be a JVM smoke substitute, but not the official label. |
| `ifx` | blocked | Intel Fortran unavailable on Alpine/aarch64. |
| `julia` | blocked | No Alpine aarch64 package found. |
| `pharo` | blocked | No obvious Alpine package. |
| `swift` | blocked | No Swift package. |


### Native compiler execution rows: GCC and G++

Commands:

```sh
tests/arm64/benchmarksgame/run-gcc-smoke.sh
tests/arm64/benchmarksgame/run-gpp-smoke.sh
```

Latest results:

```text
GCC: 10 / 10 build, 10 / 10 run
report: /workspace/tmp/benchmarksgame-gcc-smoke-20260513-143326.md

G++: 10 / 10 build, 10 / 10 run
report: /workspace/tmp/benchmarksgame-gpp-smoke-20260513-143434.md
```

These rows compile official native-code variants inside the guest and then run smoke-sized inputs. Architecture-specific x86 SIMD variants (`immintrin.h`, `x86intrin.h`, SSE/AVX intrinsics) are recorded and skipped rather than patched for ARM64. Two Alpine/musl source-environment limitations are also recorded: some threaded `revcomp`/`fasta` variants use large per-thread stack arrays that overflow musl's small default pthread stacks, and `fannkuchredux-gpp-5` relies on `int64_t` without including `<cstdint>`. The rows keep the next official portable variant instead of changing benchmark source.

### Go execution row

Command:

```sh
tests/arm64/benchmarksgame/run-go-smoke.sh
```

Latest result:

```text
10 / 10 passing
Safety-valve diagnostics: PASS
report: /workspace/tmp/benchmarksgame-go-smoke-20260513-144802.md
```

The Go row intentionally chooses self-contained official Go variants for the first tier. Faster `pidigits` and `regexredux` variants that require cgo/GMP/PCRE are tracked as a separate cgo/toolchain stress pass. During manual probing, the cgo `pidigits` variant exposed `cc: fatal error: failed to get exit status: Interrupted system call` while compiling `runtime/cgo`; this was fixed by treating the internal 1-second `wait4` poll timeout as a timeout, not as a guest `EINTR`. A later transient `fatal: bad g in signal handler` was traced to process-shared `sigaltstack` state; iSH now stores alternate signal stacks per task/thread, matching Linux and Go runtime expectations. A minimal cgo build and cgo/GMP `pidigits` now compile and run.

### Python execution row

Command:

```sh
tests/arm64/benchmarksgame/run-python-smoke.sh
```

Latest result:

```text
10 / 10 passing
report: /workspace/tmp/benchmarksgame-python-smoke-20260513-144843.md
```

Issue found and fixed: Python `multiprocessing.SemLock` fails with `FileNotFoundError` when `/dev/shm` is absent from the fakefs root. iSH startup now pre-creates `/dev/shm` with mode `1777`, and the Python row passes without creating it in the harness. Many Linux runtimes assume `/dev/shm` exists even when it is just a regular tmp-capable directory.


### Node.js execution row

Command:

```sh
tests/arm64/benchmarksgame/run-node-smoke.sh
```

Latest result:

```text
10 / 10 passing
report: /workspace/tmp/benchmarksgame-node-smoke-20260513-144925.md
```

The first Node.js row intentionally avoids `worker_threads` and external modules such as `mpzjs`, keeping this lane single-process and dependency-free. The skipped worker-thread variants should become a separate scheduler/futex stress lane.

### Perl execution row

Command:

```sh
tests/arm64/benchmarksgame/run-perl-smoke.sh
```

Latest result:

```text
10 / 10 passing
report: /workspace/tmp/benchmarksgame-perl-smoke-20260513-145010.md
```

The first Perl row adapts `pidigits` to use stdlib `Math::BigInt` because Alpine does not package `Math::BigInt::GMP`. The GMP variant remains useful as a separate dependency/native-extension stress lane.

### Ruby execution row

Command:

```sh
tests/arm64/benchmarksgame/run-ruby-smoke.sh
```

Latest result:

```text
10 / 10 passing
report: /workspace/tmp/benchmarksgame-ruby-smoke-20260513-145038.md
```

The Ruby row now includes Thread/fork-heavy variants. Manual probing of `regexredux-ruby-3` found a false positive in the poll safety valve while other guest threads were still doing CPU work. iSH now only fires that safety valve when all threads are blocking; the Thread/fork-heavy Ruby row now passes.


### PHP execution row

Command:

```sh
tests/arm64/benchmarksgame/run-php-smoke.sh
```

Latest result:

```text
10 / 10 passing
report: /workspace/tmp/benchmarksgame-php-smoke-20260513-144957.md
```

Issue found and fixed: the fastest official PHP variants use `shmop` and SysV message queues around `pcntl_fork()`. ARM64 iSH had direct `shmget`/`shmctl`/`shmat`/`shmdt` and `msgget`/`msgctl`/`msgrcv`/`msgsnd` as stubs. iSH now implements enough SysV shared memory and message queue semantics for these workloads: shared mappings survive fork as shared pages, `IPC_STAT` reports segment size for PHP `shmop_open()`, and message receives block until forked workers send their result strings.

### Lua execution row

Command:

```sh
tests/arm64/benchmarksgame/run-lua-smoke.sh
```

Latest result:

```text
10 / 10 passing
report: /workspace/tmp/benchmarksgame-lua-smoke-20260513-145120.md
```

The Lua row uses official Lua sources under `lua5.3` because the official GMP-backed `pidigits` variants depend on LGMP, which explicitly supports Lua >= 5.1 and < 5.4. The runner installs/builds LGMP through `luarocks-5.3` and uses Alpine's packaged `lua5.3-rex-pcre2` for official `regexredux`. The first `pidigits-lua-1` alternative is skipped because its `bn` module is not packaged in Alpine.

### Java equivalent probe

Command:

```sh
tests/arm64/benchmarksgame/run-java-equivalent-smoke.sh
```

Current result:

```text
Java startup: PASS
Build result: PASS
Result: 10 / 10 passing
Safety-valve diagnostics: PASS
report: /workspace/tmp/benchmarksgame-java-equivalent-smoke-20260513-145338.md
interpreter fallback report: /workspace/tmp/benchmarksgame-java-equivalent-smoke-20260513-145716.md
```

The current Benchmarks Game performance pages do not advertise a Java row. The probe therefore generates local Java equivalents for the ten benchmark families. OpenJDK 21 now starts after fixing ARM64 `DCZID_EL0`/`dc zva` handling: ARM64 iSH advertises a 64-byte DC ZVA block and implements the zeroing instruction. The default `javac`/C2 crash was later traced to missing `LDPSW` pair-load sign extension and fixed. The Java-equivalent lane now runs `javac` and benchmark execution in HotSpot default mixed mode by default and passes all ten equivalents; `JAVA_SMOKE_MODE=interpreter` remains available and was revalidated as conservative fallback coverage.

### Proposed harness shape

The next repeatable test should be tiered instead of pretending all 26 official labels are equally installable on Alpine aarch64:

1. **Discovery tier** — scrape the active performance pages, list benchmark/language/source variants, and record unavailable labels explicitly.
2. **Core tier** — run one representative implementation per benchmark for already-validated runtimes: `gcc`, `gpp`, `go`, `python3`, `node`, `php`, `perl`, `ruby`, `lua`.
3. **Compiler/large-runtime tier** — add large but packaged compilers/runtimes: `rust`, `erlang`, `ghc`, `ocaml`, `sbcl`, `racket`, `gnat`.
4. **External tier** — only after explicit setup: .NET NativeAOT/F#, GraalVM, and other non-Alpine toolchains if we decide to vendor or install them manually.
5. **Unsupported ledger** — keep blocked official labels in the report so "all languages" means "all official labels accounted for", not silently skipped.

The pass/fail artifact should include:

- benchmark name;
- official language label;
- source URL or page;
- compiler/interpreter command;
- input size used for smoke mode;
- exit code;
- elapsed time;
- first/last output checksum or byte count;
- whether the failure is setup/toolchain, iSH syscall/instruction, or benchmark-source related.

### First commands used for feasibility mapping

```sh
curl -fsSL https://benchmarksgame-team.pages.debian.net/benchmarksgame/ -o index.html
git clone --depth 1 https://salsa.debian.org/benchmarksgame-team/benchmarksgame.git /workspace/tmp/benchmarksgame-src
```

The site pages were scraped for `../program/...` links; the package feasibility table was checked against Alpine 3.23 aarch64 `APKINDEX` files for `main` and `community`.
