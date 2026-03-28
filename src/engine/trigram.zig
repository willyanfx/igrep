const std = @import("std");

/// Trigram index engine — placeholder for Milestone 3.
///
/// A trigram is a 3-byte substring. By indexing all trigrams in a file,
/// we can quickly determine which files *might* contain a query string
/// without reading every file.

pub const TRIGRAM_SIZE: usize = 3;

/// Hash a trigram (3-byte sequence) to a u32 for use as a posting list key.
pub fn trigramHash(bytes: *const [3]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16);
}

/// Extract all unique trigrams from a byte slice.
/// Returns a list of trigram hashes.
pub fn extractTrigrams(allocator: std.mem.Allocator, data: []const u8) ![]u32 {
    if (data.len < TRIGRAM_SIZE) return &.{};

    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    var trigrams: std.ArrayList(u32) = .{};
    errdefer if (trigrams.capacity > 0) trigrams.deinit(allocator);

    for (0..data.len - TRIGRAM_SIZE + 1) |i| {
        const hash = trigramHash(data[i..][0..3]);
        const result = try seen.getOrPut(hash);
        if (!result.found_existing) {
            try trigrams.append(allocator, hash);
        }
    }

    return trigrams.toOwnedSlice(allocator);
}

/// Extract trigrams from a search pattern.
pub fn patternTrigrams(allocator: std.mem.Allocator, pattern: []const u8) ![]u32 {
    return extractTrigrams(allocator, pattern);
}

// ── Tests ────────────────────────────────────────────────────────────

test "trigramHash produces unique hashes" {
    const h1 = trigramHash("abc");
    const h2 = trigramHash("abd");
    try std.testing.expect(h1 != h2);
}

test "extractTrigrams basic" {
    const data = "hello";
    const trigrams = try extractTrigrams(std.testing.allocator, data);
    defer std.testing.allocator.free(trigrams);
    // "hello" has trigrams: "hel", "ell", "llo" = 3 unique trigrams
    try std.testing.expectEqual(@as(usize, 3), trigrams.len);
}

test "extractTrigrams deduplicates" {
    const data = "aaaa";
    const trigrams = try extractTrigrams(std.testing.allocator, data);
    defer std.testing.allocator.free(trigrams);
    // "aaaa" has only one unique trigram: "aaa"
    try std.testing.expectEqual(@as(usize, 1), trigrams.len);
}
