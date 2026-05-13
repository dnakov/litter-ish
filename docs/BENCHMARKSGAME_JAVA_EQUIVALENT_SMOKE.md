# Benchmarks Game Java-equivalent smoke report

- Timestamp: 2026-05-13T14:57:16+00:00
- ish binary: /workspace/projects/ish-arm64/build-arm64-linux/ish
- rootfs: /workspace/projects/ish-arm64/alpine-arm64-fakefs
- timeout: 900s
- Java mode: mixed
- guest workdir: /tmp/benchmarksgame-java-equivalent-smoke
- Source status: current Benchmarks Game pages do not advertise a Java language row; this runner uses local Java equivalents.
- Java startup: PASS
- Build result: PASS
- Result: 10 / 10 passing
- Safety-valve diagnostics: PASS

## Results

| Benchmark | Status | Bytes | Lines | CRC:Size | Time (s) |
|---|---:|---:|---:|---|---:|
| binarytrees | PASS | 144 | 4 | 3398443640:144 | 3.56 |
| fannkuchredux | PASS | 24 | 2 | 3876461884:24 | 2.72 |
| fasta | PASS | 1024 | 18 | 1840911314:1024 | 1.38 |
| knucleotide | PASS | 100 | 13 | 463387513:100 | 11.80 |
| mandelbrot | PASS | 1311 | 2 | 640347331:1311 | 3.59 |
| nbody | PASS | 26 | 2 | 980964627:26 | 4.04 |
| pidigits | PASS | 151 | 10 | 3273113594:151 | 3.81 |
| regexredux | PASS | 263 | 13 | 3404323976:263 | 6.87 |
| revcomp | PASS | 10174 | 168 | 2332509513:10174 | 4.09 |
| spectralnorm | PASS | 12 | 1 | 2938823901:12 | 4.85 |

## Raw guest log tail

```text
__JAVA_MODE:mixed
__JAVA_VERSION_BEGIN
openjdk version "21.0.10" 2026-01-20
OpenJDK Runtime Environment (build 21.0.10+7-alpine-r0)
OpenJDK 64-Bit Server VM (build 21.0.10+7-alpine-r0, mixed mode, sharing)
__JAVA_VERSION_END
__JAVA_VERSION_OK
__JAVA_BUILD:PASS
__BG_BEGIN:binarytrees
__BG_TIME:binarytrees:3.56
__BG_RESULT:binarytrees:PASS:144:4:3398443640:144
__BG_BEGIN:fannkuchredux
__BG_TIME:fannkuchredux:2.72
__BG_RESULT:fannkuchredux:PASS:24:2:3876461884:24
__BG_BEGIN:fasta
__BG_TIME:fasta:1.38
__BG_RESULT:fasta:PASS:1024:18:1840911314:1024
__BG_BEGIN:knucleotide
__BG_TIME:knucleotide:11.80
__BG_RESULT:knucleotide:PASS:100:13:463387513:100
__BG_BEGIN:mandelbrot
__BG_TIME:mandelbrot:3.59
__BG_RESULT:mandelbrot:PASS:1311:2:640347331:1311
__BG_BEGIN:nbody
__BG_TIME:nbody:4.04
__BG_RESULT:nbody:PASS:26:2:980964627:26
__BG_BEGIN:pidigits
__BG_TIME:pidigits:3.81
__BG_RESULT:pidigits:PASS:151:10:3273113594:151
__BG_BEGIN:regexredux
__BG_TIME:regexredux:6.87
__BG_RESULT:regexredux:PASS:263:13:3404323976:263
__BG_BEGIN:revcomp
__BG_TIME:revcomp:4.09
__BG_RESULT:revcomp:PASS:10174:168:2332509513:10174
__BG_BEGIN:spectralnorm
__BG_TIME:spectralnorm:4.85
__BG_RESULT:spectralnorm:PASS:12:1:2938823901:12
__BG_ALL_DONE

```
