# Benchmarks Game ios-linuxkit ARM64 harness

Status: active workload gate for the currently feasible Alpine aarch64 rows.

Primary design document: [ARM64_WORKLOAD_SMOKE_TESTS.md](ARM64_WORKLOAD_SMOKE_TESTS.md).

This directory contains the repeatable harnesses that turn the Benchmarks Game corpus into ios-linuxkit ARM64 smoke tests. The active shape is:

1. discover active benchmark/language/source variants from the official performance pages;
2. install or verify the selected Alpine aarch64 toolchains;
3. run a smoke-sized input for every feasible benchmark/language pair;
4. record unsupported official language labels explicitly instead of silently skipping them;
5. classify failures as toolchain/setup, benchmark-source, or iSH syscall/instruction/runtime bugs.

The first target tier now covers one representative implementation per active benchmark for the already-validated runtimes: `gcc`, `gpp`, `go`, `python3`, `node`, `php`, `perl`, `ruby`, and `lua`. A local Java-equivalent lane covers OpenJDK because the current Benchmarks Game pages do not advertise a Java row.

## Discovery matrix

Generate the full official-language matrix with:

```sh
tests/arm64/benchmarksgame/generate-matrix.py
```

The output is committed at `docs/BENCHMARKSGAME_MATRIX.md` so changes in the upstream Benchmarks Game site are visible in diffs.

## GCC execution row

Run the C/GCC benchmark row with:

```sh
tests/arm64/benchmarksgame/run-gcc-smoke.sh
```

Latest validated result: 10/10 builds and 10/10 runs. This row uses official portable C variants, installing packaged APR/GMP/PCRE dependencies and recording x86-SIMD or musl-thread-stack alternatives explicitly.

## G++ execution row

Run the C++/G++ benchmark row with:

```sh
tests/arm64/benchmarksgame/run-gpp-smoke.sh
```

Latest validated result: 10/10 builds and 10/10 runs. This row uses official portable C++ variants, including Boost/TBB/GMP/PCRE dependencies where needed, and records skipped x86-SIMD/source-portability alternatives.

## Go execution row

Run the first actual benchmark row with:

```sh
tests/arm64/benchmarksgame/run-go-smoke.sh
```

This fetches official Go source variants from the public Benchmarks Game pages, prefers self-contained variants for the first tier, pushes them into the guest, builds them with guest `go`, and records a Markdown report. Latest validated result: 10/10 passing.

## Python execution row

Run the Python benchmark row with:

```sh
tests/arm64/benchmarksgame/run-python-smoke.sh
```

Latest validated result: 10/10 passing. The row verifies iSH startup pre-creates `/dev/shm` because Python multiprocessing semaphores require it on musl-based Alpine.

## Node.js execution row

Run the Node.js benchmark row with:

```sh
tests/arm64/benchmarksgame/run-node-smoke.sh
```

Latest validated result: 10/10 passing. The first row avoids `worker_threads` and external modules so we can add those as separate stress lanes.

## Perl execution row

Run the Perl benchmark row with:

```sh
tests/arm64/benchmarksgame/run-perl-smoke.sh
```

Latest validated result: 10/10 passing. `pidigits` is adapted to stdlib `Math::BigInt` because Alpine does not package `Math::BigInt::GMP`.

## Ruby execution row

Run the Ruby benchmark row with:

```sh
tests/arm64/benchmarksgame/run-ruby-smoke.sh
```

Latest validated result: 10/10 passing. This row includes Thread/fork variants after fixing a poll safety-valve false positive found by `regexredux-ruby-3`.

## PHP execution row

Run the PHP benchmark row with:

```sh
tests/arm64/benchmarksgame/run-php-smoke.sh
```

Latest validated result: 10/10 passing. This row includes official `pcntl`/`shmop`/SysV-message variants after adding ios-linuxkit ARM64 SysV shared memory and message queue support.

## Lua execution row

Run the Lua benchmark row with:

```sh
tests/arm64/benchmarksgame/run-lua-smoke.sh
```

Latest validated result: 10/10 passing. The row runs official Lua sources under `lua5.3` so the official LGMP-backed `pidigits` variant can run; `regexredux` uses Alpine's `lua5.3-rex-pcre2`.

## Java equivalent probe

The current Benchmarks Game pages do not advertise a Java row. To keep Java visible as a runtime lane, run the local equivalent probe with:

```sh
tests/arm64/benchmarksgame/run-java-equivalent-smoke.sh
```

Current result: 10/10 passing in HotSpot default mixed mode (`JAVA_SMOKE_MODE=mixed`, the default). The previous OpenJDK startup blocker was fixed by advertising a 64-byte `DCZID_EL0` block and implementing `dc zva`; the later default `javac`/C2 crash was fixed by implementing ARM64 `LDPSW` pair-load sign extension. Use `JAVA_SMOKE_MODE=interpreter` to rerun the same probe as conservative `-Xint -Xshare:off` fallback coverage.
