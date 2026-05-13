# Benchmarks Game Node.js smoke report

- Timestamp: 2026-05-13T14:49:56+00:00
- ish binary: /workspace/projects/ish-arm64/build-arm64-linux/ish
- rootfs: /workspace/projects/ish-arm64/alpine-arm64-fakefs
- timeout: 900s
- guest workdir: /tmp/benchmarksgame-node-smoke
- Result: 10 / 10 passing
- Safety-valve diagnostics: PASS

## Selected Node.js source variants

| Benchmark | Program page | Skipped alternatives |
|---|---|---|
| binarytrees | binarytrees-node-7.html | binarytrees-node-6.html:worker_threads,binarytrees-node-1.html:worker_threads |
| fannkuchredux | fannkuchredux-node-8.html | fannkuchredux-node-5.html:worker_threads |
| fasta | fasta-node-8.html | fasta-node-5.html:worker_threads |
| knucleotide | knucleotide-node-2.html | knucleotide-node-3.html:worker_threads |
| mandelbrot | mandelbrot-node-2.html | mandelbrot-node-3.html:worker_threads |
| nbody | nbody-node-6.html | — |
| pidigits | pidigits-node-2.html | pidigits-node-4.html:require('mpzjs') |
| regexredux | regexredux-node-4.html | regexredux-node-3.html:worker_threads |
| revcomp | revcomp-node-2.html | — |
| spectralnorm | spectralnorm-node-7.html | spectralnorm-node-6.html:worker_threads |

## Results

| Benchmark | Status | Bytes | Lines | CRC:Size | Time (s) |
|---|---:|---:|---:|---|---:|
| binarytrees | PASS | 144 | 4 | 3398443640:144 | 1.50 |
| fannkuchredux | PASS | 24 | 2 | 3876461884:24 | 1.70 |
| fasta | PASS | 10245 | 171 | 1573388369:10245 | 1.59 |
| knucleotide | PASS | 136 | 15 | 2155388821:136 | 6.34 |
| mandelbrot | PASS | 1211 | 2 | 4110621501:1211 | 2.66 |
| nbody | PASS | 26 | 2 | 980964627:26 | 1.75 |
| pidigits | PASS | 151 | 10 | 3273113594:151 | 1.47 |
| regexredux | PASS | 263 | 13 | 3404323976:263 | 1.54 |
| revcomp | PASS | 10174 | 168 | 2332509513:10174 | 2.13 |
| spectralnorm | PASS | 12 | 1 | 2938823901:12 | 3.05 |

## Raw guest log tail

```text
__BG_BEGIN:binarytrees
__BG_TIME:binarytrees:1.50
__BG_RESULT:binarytrees:PASS:144:4:3398443640:144
__BG_BEGIN:fannkuchredux
__BG_TIME:fannkuchredux:1.70
__BG_RESULT:fannkuchredux:PASS:24:2:3876461884:24
__BG_BEGIN:fasta
__BG_TIME:fasta:1.59
__BG_RESULT:fasta:PASS:10245:171:1573388369:10245
__BG_BEGIN:knucleotide
__BG_TIME:knucleotide:6.34
__BG_RESULT:knucleotide:PASS:136:15:2155388821:136
__BG_BEGIN:mandelbrot
__BG_TIME:mandelbrot:2.66
__BG_RESULT:mandelbrot:PASS:1211:2:4110621501:1211
__BG_BEGIN:nbody
__BG_TIME:nbody:1.75
__BG_RESULT:nbody:PASS:26:2:980964627:26
__BG_BEGIN:pidigits
__BG_TIME:pidigits:1.47
__BG_RESULT:pidigits:PASS:151:10:3273113594:151
__BG_BEGIN:regexredux
__BG_TIME:regexredux:1.54
__BG_RESULT:regexredux:PASS:263:13:3404323976:263
__BG_BEGIN:revcomp
__BG_TIME:revcomp:2.13
__BG_RESULT:revcomp:PASS:10174:168:2332509513:10174
__BG_BEGIN:spectralnorm
__BG_TIME:spectralnorm:3.05
__BG_RESULT:spectralnorm:PASS:12:1:2938823901:12
__BG_ALL_DONE

```
