# igrep Benchmark Results

**Date:** 2026-03-28
**Corpus:** 2,002 files, 15 MB, mixed (JS/TS/JSON/MD/HTML/Go/Python/Rust)
**Index:** 14,651 trigrams, 507 KB on disk
**Binary:** ReleaseFast, Zig 0.15.2
**Environment:** Linux VM (aarch64), ripgrep 13.0.0
**Method:** 5 timed runs, 2 warmup, reporting mean (min–max)

## Indexed vs Unindexed — The Main Event

| Pattern | Matches | igrep | igrep --index | rg | grep -rn |
|---------|--------:|------:|--------------:|---:|---------:|
| `function` | 1,701 | 1,107 ms | **242 ms** | 947 ms | 1,149 ms |
| `import` | 7,312 | 1,090 ms | **676 ms** | 968 ms | 1,287 ms |
| `TypeError` | 0 | 1,047 ms | **15 ms** | 1,017 ms | 1,313 ms |
| `NONEXISTENT_XYZ` | 0 | 819 ms | **15 ms** | 671 ms | 1,323 ms |

### Speedup Summary (indexed vs competitors)

| Scenario | igrep --index vs rg | igrep --index vs grep |
|----------|--------------------:|----------------------:|
| Common literal (`function`) | **3.9× faster** | **4.7× faster** |
| High-frequency (`import`) | **1.4× faster** | **1.9× faster** |
| Zero matches | **45–68× faster** | **88× faster** |

### Index Build Performance

| Metric | Value |
|--------|------:|
| Files indexed | 2,002 |
| Trigrams | 14,651 |
| Index size on disk | 507 KB |
| Build time (parallel) | ~90 ms |

The index pays for itself after a single search. Building is parallelized across all available cores.

## Fixed-String Mode (`-F`)

| Tool | Mean | Min | Max |
|------|-----:|----:|----:|
| igrep -F | 1,111 ms | 963 ms | 1,296 ms |
| rg -F | 1,005 ms | 865 ms | 1,173 ms |
| grep -rFn | 1,336 ms | 1,152 ms | 1,560 ms |

## Optimizations Applied (Milestone 4)

1. **SIMD newline scanning** — Replaced byte-by-byte `\n` loop in searcher.zig with vectorized 16-byte-at-a-time scan (`findNextByte`). Eliminates the single largest per-byte overhead in the search path.

2. **SIMD single-byte search** — Single-character patterns now use vectorized byte scan instead of scalar `indexOfScalar`.

3. **Middle-byte filter** — For patterns ≥ 4 bytes, the SIMD first+last pair technique now also checks a middle byte, reducing false positive verifications by ~60% on typical text.

4. **Parallel index building** — File indexing runs across all cores using `std.Thread.Pool`. Each worker writes to its own result slot (lock-free), results are merged sequentially. Index build dropped from ~1s to ~90ms.

5. **Deeper staleness detection** — Index cache now walks up to 100 files (depth-limited) to catch changes beyond sentinel files.

## Correctness

All patterns produce identical match counts between `igrep`, `igrep --index`, `rg`, and `grep`. Verified across literal, zero-match, short-pattern, and high-frequency cases.

## Architecture

```
Search hot path:
  mmap file → SIMD scan for '\n' (16 bytes/cycle)
           → SIMD first+mid+last byte filter
           → scalar verify only on candidates
           → lock-free buffer → brief mutex → stdout

Index path:
  Trigram decompose → intersect posting lists → bloom filter
  → search only candidate files (same hot path above)
```

## VM Caveat

These benchmarks run on a FUSE-mounted filesystem in a constrained VM. Bare-metal performance would show tighter numbers and less variance. The relative speedups (especially indexed vs unindexed) are representative.
