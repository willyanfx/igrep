# Architecture Overview

## System Design

The search system is composed of three main layers:

1. **Indexing Layer** — Builds and maintains a trigram index over the codebase.
2. **Query Layer** — Translates search queries into trigram lookups and candidate filtering.
3. **Presentation Layer** — Formats and displays search results with context.

## Trigram Indexing

A trigram is a contiguous 3-byte substring. For example, the string "hello" contains
the trigrams: "hel", "ell", "llo".

The index maps each trigram to a posting list — an ordered list of (file_id, offset)
pairs indicating where that trigram appears in the corpus.

### 3.5-Gram Enhancement

Pure trigram indexing has limited selectivity: common trigrams like "the" or "int"
appear in nearly every file. To improve filtering, we augment each posting list
entry with a Bloom filter that encodes partial information about the byte following
the trigram. This effectively creates "3.5-grams" without doubling index size.

### Query Planning

For a search query of length N:
1. Extract all (N-2) trigrams from the query.
2. Look up each trigram's posting list.
3. Intersect the posting lists to find candidate files.
4. For each candidate, verify the full match using SIMD-accelerated literal search.

This reduces search time from O(corpus_size) to O(candidates * avg_file_size),
where candidates << total_files for sufficiently selective queries.

## Performance Targets

| Metric | Target | Current |
|--------|--------|---------|
| Cold index build (100K files) | < 30s | TODO |
| Warm search (selective query) | < 50ms | TODO |
| Warm search (common pattern) | < 200ms | TODO |
| Memory usage (indexer) | < 2GB | TODO |
| Index size on disk | < 20% of corpus | TODO |

## Security Considerations

The index is stored locally and never transmitted. For hosted deployments:
- Trigram posting lists reveal which 3-byte patterns exist in the codebase.
- FIXME: we should encrypt posting lists at rest for enterprise customers.
- TODO: implement access control so users only see files they have permission to read.

## File Traversal

The walker performs a depth-first traversal respecting:
- `.gitignore` rules (loaded per-directory)
- Built-in skip list: `.git`, `node_modules`, `__pycache__`, etc.
- Max depth limits
- File type filters
