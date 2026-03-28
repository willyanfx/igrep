# instantGrep — Project Plan

## Vision

A blazing-fast code search tool written in Zig that outperforms ripgrep through a combination of trigram indexing, SIMD-accelerated matching, memory-mapped I/O, and parallel file traversal. Inspired by Cursor's Instant Grep, lgrep, and seek.

---

## Research Summary

### Key References

**Cursor's Instant Grep (cursor.com/blog/fast-regex-search)**
- Core insight: build a *candidate-finding system*, not a faster regex matcher. Avoid opening most files entirely.
- Uses sparse n-gram indexing (trigrams with bloom filter augmentation for "3.5-gram" selectivity).
- Two-tier storage: postings file on disk + mmap'd lookup table for binary search.
- Index keyed off git commit with a mutable live-change layer for uncommitted edits.
- Results: 13ms local queries vs ripgrep's 16.8s on large monorepos (~1,300x speedup).

**seek (github.com/dualeai/seek)**
- Go wrapper around zoekt (Sourcegraph's engine). Trigram-based indexing with O(matches) query time.
- BM25 relevance ranking. Dual-indexes committed + uncommitted files.
- flock-based concurrency safety. Cold index: 7.5s, warm search: 132ms.

**lgrep (github.com/dennisonbertram/lgrep)**
- TypeScript/Node.js semantic search tool using AI embeddings — different approach but useful for the code-intelligence features.

### Why Zig?

1. Zero-cost abstractions with manual memory control — no GC pauses during search.
2. First-class SIMD via `@Vector` — portable SIMD without platform-specific intrinsics.
3. Comptime metaprogramming — generate optimized search kernels at compile time.
4. C ABI compatibility — can bind to PCRE2 or RE2 if needed.
5. Excellent cross-compilation — single binary for every platform.
6. No hidden allocations — total control over memory layout for cache efficiency.

---

## Architecture

```
instantGrep/
├── build.zig              # Build configuration
├── build.zig.zon          # Package manifest & dependencies
├── PLAN.md                # This file
├── README.md              # Usage documentation
├── src/
│   ├── main.zig           # CLI entry point & argument parsing
│   ├── searcher.zig       # High-level search orchestrator
│   ├── engine/
│   │   ├── literal.zig    # SIMD-accelerated literal string search
│   │   ├── regex.zig      # Regex compilation & matching
│   │   ├── trigram.zig    # Trigram index builder & query engine
│   │   └── bloom.zig      # Bloom filter for posting list augmentation
│   ├── io/
│   │   ├── mmap.zig       # Memory-mapped file I/O wrapper
│   │   ├── walker.zig     # Parallel directory traversal
│   │   └── gitignore.zig  # .gitignore parser and matcher
│   ├── index/
│   │   ├── builder.zig    # Index construction (trigram extraction)
│   │   ├── store.zig      # On-disk index format (postings + lookup)
│   │   ├── query.zig      # Index query engine (candidate filtering)
│   │   └── cache.zig      # Index cache management & invalidation
│   ├── output/
│   │   ├── printer.zig    # Result formatting (colors, line numbers)
│   │   └── json.zig       # JSON output mode
│   └── util/
│       ├── pool.zig       # Thread pool implementation
│       ├── arena.zig      # Arena allocator helpers
│       └── simd.zig       # SIMD utility functions
└── tests/
    ├── test_literal.zig   # Literal search tests
    ├── test_trigram.zig   # Trigram index tests
    ├── test_walker.zig    # File traversal tests
    ├── test_regex.zig     # Regex tests
    └── fixtures/          # Test data files
```

---

## Milestones

### Milestone 1: Foundation (MVP — grep-like literal search)
**Goal:** Search files for literal strings, matching ripgrep's basic behavior.

| Step | Description | Key Techniques |
|------|-------------|----------------|
| 1.1  | Project scaffold: build.zig, CLI arg parsing, basic main loop | Zig 0.15.2, std.process.ArgIterator |
| 1.2  | Memory-mapped file reader | std.posix.mmap, page-aligned reads |
| 1.3  | Single-file literal search with SIMD | @Vector(32, u8), memchr-style scanning |
| 1.4  | Parallel directory walker (respects .gitignore) | std.Thread.Pool, recursive walk |
| 1.5  | Result printer with colors and line numbers | ANSI escape codes, buffered stdout |
| 1.6  | Benchmarks vs ripgrep on basic literal search | hyperfine, Linux kernel source |

**Exit Criteria:** `igrep "TODO" ./linux` returns correct results within 2x of ripgrep speed.

---

### Milestone 2: Regex Support
**Goal:** Support full regex patterns with smart fast-path detection.

| Step | Description | Key Techniques |
|------|-------------|----------------|
| 2.1  | Regex parser: convert pattern to AST | Comptime NFA construction |
| 2.2  | Literal extraction from regex patterns | Identify required literal fragments |
| 2.3  | NFA/DFA execution engine | Thompson NFA with lazy DFA caching |
| 2.4  | Smart dispatch: literal patterns → SIMD path, complex → regex engine | Pattern analysis at startup |
| 2.5  | Capture group support | Submatch extraction |

**Exit Criteria:** `igrep -e "fn\s+\w+\(" ./src` works correctly.

---

### Milestone 3: Trigram Index Engine
**Goal:** Build and query a trigram index for instant candidate filtering.

| Step | Description | Key Techniques |
|------|-------------|----------------|
| 3.1  | Trigram extraction from files | 3-byte sliding window, hash to u32 |
| 3.2  | Posting list construction (file_id → trigram set) | Sorted arrays, delta encoding |
| 3.3  | On-disk index format (postings + lookup table) | Binary format, mmap'd lookup |
| 3.4  | Bloom filter augmentation ("3.5-grams") | 8-bit masks for next-char + position |
| 3.5  | Index query: decompose pattern → trigram cover → intersect postings | Minimal covering set algorithm |
| 3.6  | Incremental index updates (git-aware) | Merkle tree of file hashes |
| 3.7  | Cache management (.igrep/ directory) | LRU eviction, stale detection |

**Exit Criteria:** Indexed search on monorepo returns results in <50ms.

---

### Milestone 4: Advanced Performance
**Goal:** Squeeze out every last drop of performance.

| Step | Description | Key Techniques |
|------|-------------|----------------|
| 4.1  | Work-stealing thread pool | Lock-free deque per thread |
| 4.2  | Adaptive SIMD width selection | Runtime CPU feature detection |
| 4.3  | Large-file chunked parallel search | Split mmap'd files at line boundaries |
| 4.4  | Frequency-weighted n-gram selection | Inverse frequency from code corpus |
| 4.5  | Searcher pipelining (read → search → print overlap) | Async I/O + ring buffers |

**Exit Criteria:** Consistently faster than ripgrep on all benchmark suites.

---

### Milestone 5: Developer Experience
**Goal:** Make it a joy to use day-to-day.

| Step | Description |
|------|-------------|
| 5.1  | File type filtering (--type zig, --type py) |
| 5.2  | Context lines (-A, -B, -C flags) |
| 5.3  | Count mode, files-only mode, quiet mode |
| 5.4  | JSON output for tool integration |
| 5.5  | Replace mode (search and replace) |
| 5.6  | Config file (.igreprc) support |
| 5.7  | Shell completions (bash, zsh, fish) |

---

### Milestone 6: Ecosystem Integration
**Goal:** Integrate with editors and CI pipelines.

| Step | Description |
|------|-------------|
| 6.1  | LSP-compatible output format |
| 6.2  | Watch mode (re-search on file changes) |
| 6.3  | Editor plugins (VS Code, Neovim) |
| 6.4  | Pre-commit hook integration |

---

## Key Design Decisions

### 1. Two-Mode Search Strategy
- **Unindexed mode** (default for small repos): Parallel file walk + SIMD literal/regex matching. Competes directly with ripgrep.
- **Indexed mode** (for large repos): Trigram index narrows candidates, then verify with regex. Competes with Cursor's Instant Grep.

### 2. SIMD Strategy
- Use Zig's `@Vector` for portable SIMD across ARM NEON and x86 AVX2/SSE.
- Primary kernel: vectorized `memchr` for single-byte scanning.
- Secondary kernel: vectorized two-byte pair scanning (like ripgrep's Teddy algorithm).
- Compile-time specialization for different vector widths.

### 3. Memory Management
- Arena allocator for per-search allocations (one arena per search job, freed in bulk).
- mmap for all file reads (let the OS page cache handle caching).
- Fixed-size buffers for output formatting (no allocation in the hot path).

### 4. Parallelism Model
- Thread pool with work-stealing for file processing.
- Channel-based result collection for ordered output.
- Lock-free concurrent data structures where possible.

### 5. Index Format
- Binary format with magic number and version for forward compatibility.
- Postings stored as delta-encoded, varint-compressed sorted arrays.
- Lookup table: sorted (hash, offset) pairs, binary-searchable via mmap.
- Separate live-change layer for uncommitted files (merged at query time).

---

## Benchmarking Plan

| Benchmark | Dataset | Metric |
|-----------|---------|--------|
| Literal search (common) | Linux kernel source | Wall time, throughput (GB/s) |
| Literal search (rare) | Linux kernel source | Wall time, files visited |
| Regex search | Linux kernel source | Wall time |
| Indexed vs unindexed | Chromium source | Cold + warm query time |
| Many small files | node_modules (100k+ files) | Wall time, file open overhead |
| Large single file | 1GB log file | Wall time, memory usage |

**Tools:** hyperfine for wall time, perf for CPU profiling, valgrind/massif for memory.

---

## Dependencies

| Dependency | Purpose | Type |
|------------|---------|------|
| Zig 0.15.2 std | Core language + stdlib | Built-in |
| (none initially) | Start with zero deps, add as needed | — |

The philosophy is to keep dependencies minimal. Zig's stdlib provides mmap, threads, SIMD, and file I/O. We only add external deps if we need a battle-tested regex engine (e.g., binding to RE2 via C ABI).

---

## Non-Goals (for now)

- Semantic/AI-powered search (lgrep's approach) — may revisit later.
- GUI or TUI interface — focus on CLI speed first.
- Windows support in Milestone 1 — Zig makes cross-platform easy, but we optimize for Linux/macOS first.
- Full PCRE2 compatibility — we aim for a practical regex subset.
