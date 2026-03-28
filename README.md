# igrep

A blazing-fast code search tool built in Zig, designed to outperform ripgrep through SIMD-accelerated literal matching, memory-mapped I/O, and parallel file processing.

## Features

- **SIMD-accelerated search** — vectorized first+last byte pair matching and case-insensitive search
- **Memory-mapped I/O** — zero-copy file reading with `mmap` and sequential access hints
- **Parallel file walking** — thread pool with work-stealing across directory trees
- **`.gitignore` aware** — respects nested `.gitignore` rules, skips hidden/vendor dirs
- **Shopify Liquid support** — file type filtering includes `.liquid` templates
- **Colored output** — ripgrep-style formatting with line numbers and match highlighting

## Build

Requires [Zig 0.15.x](https://ziglang.org/download/).

```sh
zig build -Doptimize=ReleaseFast
```

Binary is output to `zig-out/bin/igrep`.

## Usage

```sh
# Basic search
igrep "pattern" .

# Case-insensitive
igrep -i "todo" src/

# Filter by file type
igrep -t zig "allocator" .

# With context lines
igrep -C 2 "error" .

# Count matches only
igrep -c "FIXME" .
```

## Benchmarks

See [bench_results.md](bench_results.md) for detailed comparison against ripgrep.

## Roadmap

- [x] M1: Foundation — CLI, walker, literal search, SIMD, mmap, parallel search
- [ ] M2: Regex support
- [ ] M3: Trigram index (Cursor-style codebase indexing)
- [ ] M4: Advanced performance (AVX2, lock-free output)
- [ ] M5: Developer experience
- [ ] M6: Ecosystem integration

## License

MIT
