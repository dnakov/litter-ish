# Benchmarks Game Ruby smoke report

- Timestamp: 2026-05-13T14:51:18+00:00
- ish binary: /workspace/projects/ish-arm64/build-arm64-linux/ish
- rootfs: /workspace/projects/ish-arm64/alpine-arm64-fakefs
- timeout: 900s
- guest workdir: /tmp/benchmarksgame-ruby-smoke
- Result: 10 / 10 passing
- Safety-valve diagnostics: PASS

## Selected Ruby source variants

| Benchmark | Program page | Skipped alternatives |
|---|---|---|
| binarytrees | binarytrees-ruby-5.html | — |
| fannkuchredux | fannkuchredux-ruby-2.html | — |
| fasta | fasta-ruby-6.html | — |
| knucleotide | knucleotide-ruby-1.html | — |
| mandelbrot | mandelbrot-ruby-5.html | — |
| nbody | nbody-ruby-3.html | — |
| pidigits | pidigits-ruby-1.html | — |
| regexredux | regexredux-ruby-3.html | — |
| revcomp | revcomp-ruby-4.html | — |
| spectralnorm | spectralnorm-ruby-5.html | — |

## Results

| Benchmark | Status | Bytes | Lines | CRC:Size | Time (s) |
|---|---:|---:|---:|---|---:|
| binarytrees | PASS | 144 | 4 | 3398443640:144 | 2.67 |
| fannkuchredux | PASS | 24 | 2 | 3876461884:24 | 2.72 |
| fasta | PASS | 10245 | 171 | 1573388369:10245 | 2.34 |
| knucleotide | PASS | 136 | 15 | 2155388821:136 | 3.25 |
| mandelbrot | PASS | 1311 | 2 | 2518315031:1311 | 3.55 |
| nbody | PASS | 26 | 2 | 980964627:26 | 2.52 |
| pidigits | PASS | 151 | 10 | 3273113594:151 | 2.51 |
| regexredux | PASS | 263 | 13 | 3404323976:263 | 2.56 |
| revcomp | PASS | 10174 | 168 | 2332509513:10174 | 2.40 |
| spectralnorm | PASS | 12 | 1 | 2938823901:12 | 11.48 |

## Raw guest log tail

```text
__BG_BEGIN:binarytrees
__BG_TIME:binarytrees:2.67
__BG_RESULT:binarytrees:PASS:144:4:3398443640:144
__BG_BEGIN:fannkuchredux
__BG_TIME:fannkuchredux:2.72
__BG_RESULT:fannkuchredux:PASS:24:2:3876461884:24
__BG_BEGIN:fasta
__BG_TIME:fasta:2.34
__BG_RESULT:fasta:PASS:10245:171:1573388369:10245
__BG_BEGIN:knucleotide
__BG_TIME:knucleotide:3.25
__BG_RESULT:knucleotide:PASS:136:15:2155388821:136
__BG_BEGIN:mandelbrot
__BG_TIME:mandelbrot:3.55
__BG_RESULT:mandelbrot:PASS:1311:2:2518315031:1311
__BG_BEGIN:nbody
__BG_TIME:nbody:2.52
__BG_RESULT:nbody:PASS:26:2:980964627:26
__BG_BEGIN:pidigits
__BG_TIME:pidigits:2.51
__BG_RESULT:pidigits:PASS:151:10:3273113594:151
__BG_BEGIN:regexredux
__BG_TIME:regexredux:2.56
__BG_RESULT:regexredux:PASS:263:13:3404323976:263
__BG_BEGIN:revcomp
__BG_TIME:revcomp:2.40
__BG_RESULT:revcomp:PASS:10174:168:2332509513:10174
__BG_BEGIN:spectralnorm
__BG_TIME:spectralnorm:11.48
__BG_RESULT:spectralnorm:PASS:12:1:2938823901:12
__BG_ALL_DONE

```
