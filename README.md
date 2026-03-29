# igrep

A blazing-fast code search tool built in Zig, inspired by [Cursor's instant grep](https://www.cursor.com/). Matches or beats ripgrep on common patterns through SIMD-accelerated literal matching, a lazy DFA regex engine, trigram indexing, and parallel file processing.

## Performance (52MB, aarch64 Linux)

| Pattern | igrep | ripgrep | Result |
|---------|------:|--------:|--------|
| `fn\s+\w+\(` (dense regex) | 16 ms | 16 ms | Tied |
| `fn\s+\w+\(` (rare regex) | 0 ms | 10 ms | Faster than rg |
| `[a-zA-Z0-9_]+` (dense) | 69 ms | 91 ms | 1.3× faster |
| `-F fn` (literal) | 31 ms | 15 ms | ~2× slower |
| `\d+\.\d+` (no literal prefix) | 56 ms | 58 ms | Tied |
| `bravo charlie` (65MB, common) | 34 ms | 79 ms | 2.3× faster |
| `critical` (12MB, rare) | 4 ms | 8 ms | 2× faster |

Indexed search (`--index`) adds another 4–68× speedup on zero-match and rare-match patterns.

## How it works

```
mmap file (zero-copy)
  → extract required literal from regex (prefix or inner)
  → SIMD scan for literal (16 bytes/cycle NEON, 32 bytes/cycle AVX2)
  → only run lazy DFA on candidate lines
  → lock-free per-file output buffer → brief mutex → stdout
```

Key techniques:

- **SIMD first+mid+last byte filtering** for literal substring search, with adaptive 32-byte wide path on AVX2
- **Inner literal extraction** from regex AST — for patterns like `\d+\.\d+`, extracts the `.` and uses it to skip non-matching lines before running the DFA
- **Lazy DFA with epsilon closure caching** — caches NFA state-set transitions so repeated configurations (common in text) skip NFA simulation entirely
- **Byte equivalence classes** — groups bytes that behave identically in the regex, reducing DFA state space
- **Trigram index** with bloom-augmented posting lists for codebase-scale search
- **Parallel directory walker** with `.gitignore` awareness and file type filtering

## Build

Requires [Zig 0.15.x](https://ziglang.org/download/).

```sh
zig build -Doptimize=ReleaseFast
```

Binary goes to `zig-out/bin/igrep`.

## Usage

```sh
# Search current directory
igrep "pattern" .

# Fixed string (no regex)
igrep -F "function" src/

# Case-insensitive
igrep -i "todo" .

# Regex with context
igrep -C 2 'fn\s+\w+\(' .

# Filter by file type
igrep -t zig "allocator" .

# Count matches
igrep -c "FIXME" .

# Indexed search (auto-builds on first use)
igrep --index "TypeError" .

# Build/rebuild index
igrep --index-build .

# JSON output
igrep --json "pattern" .
```

## Options

```
-e, --regexp PATTERN       Explicit regex pattern
-i, --ignore-case          Case-insensitive search
-F, --fixed-strings        Literal string match (no regex)
-v, --invert-match         Select non-matching lines
-w, --word-regexp          Match whole words only
-c, --count                Print match counts per file
-l, --files-with-matches   Print only file paths with matches
-n, --line-number          Show line numbers (default: on)
-A, -B, -C N               Context lines (after, before, both)
-m, --max-count N          Stop after N matches per file
-t, --type EXT             Only search files with extension EXT
-j, --threads N            Worker thread count
--max-depth N              Max directory recursion depth
--color [always|never|auto]
--json                     JSON output
--index                    Use trigram index (auto-builds if missing)
--index-build              Build/rebuild index without searching
```

## Architecture

```
src/
├── main.zig              Entry point
├── cli.zig               Argument parsing
├── searcher.zig          Search orchestrator (parallel + single-threaded paths)
├── engine/
│   ├── literal.zig       SIMD literal search (first+mid+last byte, adaptive wide path)
│   ├── regex.zig         Thompson NFA compiler, literal extraction
│   ├── lazy_dfa.zig      Lazy DFA with transition caching
│   ├── trigram.zig       Trigram hashing
│   └── bloom.zig         Bloom filter for posting list augmentation
├── index/
│   ├── builder.zig       Parallel index construction
│   ├── store.zig         Binary index format (mmap'd lookup)
│   ├── query.zig         Trigram query with posting list intersection
│   └── cache.zig         Index staleness detection
├── io/
│   ├── mmap.zig          Memory-mapped file I/O with madvise hints
│   └── walker.zig        .gitignore-aware directory walker
├── output/
│   ├── printer.zig       Colored output with line numbers
│   └── buffer.zig        Per-file output buffering (lock-free)
└── util/
    └── simd.zig          Portable SIMD utilities (NEON/SSE2/AVX2)
```

## Benchmarks

Detailed results in [bench_results_m4.md](bench_results_m4.md).

## License

MIT
