const std = @import("std");

/// Trigram indexing utilities for fast substring search.
///
/// A trigram is a 3-byte substring of a document. By building an inverted
/// index mapping trigrams -> file positions, we can find candidate files
/// that *might* contain a query string without scanning every byte.
///
/// The key insight from Cursor's "Instant Grep" approach:
/// - For a query of length N, extract all (N-2) trigrams
/// - Intersect their posting lists to get candidate files
/// - Only scan those candidates with the full search engine
///
/// This reduces a 16.8s ripgrep scan to ~13ms on large monorepos.

pub const TRIGRAM_COUNT = 1 << 24; // 16M possible trigrams

/// Extract all trigrams from a byte slice.
/// Returns a list of (trigram_hash, offset) pairs.
pub fn extractTrigrams(
    allocator: std.mem.Allocator,
    data: []const u8,
) ![]TrigramEntry {
    if (data.len < 3) return &.{};

    var entries: std.ArrayList(TrigramEntry) = .{};
    for (0..data.len - 2) |i| {
        const hash = trigramHash(data[i..][0..3]);
        try entries.append(allocator, .{ .hash = hash, .offset = @intCast(i) });
    }
    return entries.toOwnedSlice(allocator);
}

/// Hash a 3-byte trigram into a 24-bit value.
/// This is a perfect hash — every unique trigram gets a unique bucket.
pub fn trigramHash(tri: *const [3]u8) u24 {
    return @as(u24, tri[0]) << 16 | @as(u24, tri[1]) << 8 | @as(u24, tri[2]);
}

/// A single trigram occurrence in a document.
pub const TrigramEntry = struct {
    hash: u24,
    offset: u32,
};

/// Bloom filter for approximate trigram set membership.
/// Used to augment trigrams into "3.5-grams" by encoding partial
/// information about the 4th byte, improving selectivity without
/// increasing index size proportionally.
pub const BloomFilter = struct {
    bits: []u64,
    num_hashes: u8,

    pub fn init(allocator: std.mem.Allocator, size_bits: usize) !BloomFilter {
        const num_words = (size_bits + 63) / 64;
        const bits = try allocator.alloc(u64, num_words);
        @memset(bits, 0);
        return .{ .bits = bits, .num_hashes = 3 };
    }

    pub fn deinit(self: *BloomFilter, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
    }

    pub fn insert(self: *BloomFilter, key: u32) void {
        for (0..self.num_hashes) |i| {
            const h = mixHash(key, @intCast(i));
            const bit_idx = h % (self.bits.len * 64);
            self.bits[bit_idx / 64] |= @as(u64, 1) << @intCast(bit_idx % 64);
        }
    }

    pub fn contains(self: *const BloomFilter, key: u32) bool {
        for (0..self.num_hashes) |i| {
            const h = mixHash(key, @intCast(i));
            const bit_idx = h % (self.bits.len * 64);
            if (self.bits[bit_idx / 64] & (@as(u64, 1) << @intCast(bit_idx % 64)) == 0) {
                return false;
            }
        }
        return true;
    }

    fn mixHash(key: u32, seed: u32) u32 {
        var h = key +% seed *% 0x9e3779b9;
        h ^= h >> 16;
        h *%= 0x85ebca6b;
        h ^= h >> 13;
        h *%= 0xc2b2ae35;
        h ^= h >> 16;
        return h;
    }
};

// TODO: implement posting list compression (variable-byte encoding)
// TODO: implement index serialization to disk
// TODO: implement incremental index updates for uncommitted changes
// FIXME: BloomFilter false positive rate needs tuning for typical codebases

test "trigram hash is unique for distinct inputs" {
    const h1 = trigramHash("abc");
    const h2 = trigramHash("abd");
    const h3 = trigramHash("abc");
    try std.testing.expect(h1 != h2);
    try std.testing.expectEqual(h1, h3);
}

test "bloom filter basic operations" {
    var bf = try BloomFilter.init(std.testing.allocator, 1024);
    defer bf.deinit(std.testing.allocator);

    bf.insert(42);
    bf.insert(123);

    try std.testing.expect(bf.contains(42));
    try std.testing.expect(bf.contains(123));
    // Probabilistic — might false positive, but 999 is very unlikely to collide
    // with just 2 insertions in a 1024-bit filter
}
