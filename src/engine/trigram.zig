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

/// Estimate the rarity of a trigram (0.0 = very common, 1.0 = very rare).
/// Higher rarity = better for index filtering (smaller posting lists).
///
/// Heuristic: based on printability. Printable ASCII bytes [32..126] are
/// more common in source code, so trigrams containing mostly printable bytes
/// have lower rarity. Non-printable or high-value bytes are rarer.
pub fn trigramRarity(hash: u32) f32 {
    // Extract the three bytes from the hash
    const b0: u8 = @truncate(hash);
    const b1: u8 = @truncate(hash >> 8);
    const b2: u8 = @truncate(hash >> 16);

    // For simplicity: estimate based on byte values
    // Bytes in [32..126] (printable ASCII) have higher frequency in source code
    // Non-printable or high-value bytes are rarer
    const is_common_b0 = b0 >= 32 and b0 <= 126;
    const is_common_b1 = b1 >= 32 and b1 <= 126;
    const is_common_b2 = b2 >= 32 and b2 <= 126;

    const count_common = @as(u32, if (is_common_b0) 1 else 0) +
        @as(u32, if (is_common_b1) 1 else 0) +
        @as(u32, if (is_common_b2) 1 else 0);

    // Rarity inversely proportional to how many common bytes it contains
    // 3 common bytes = very common (rarity 0.25)
    // 0 common bytes = very rare (rarity 1.0)
    const diff = @as(i32, 4) - @as(i32, @intCast(count_common));
    return @as(f32, @floatFromInt(diff)) / 4.0;
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

test "trigramRarity differentiates common and rare trigrams" {
    // Trigram with all printable ASCII: high frequency, low rarity
    const common = trigramHash("the");
    const common_rarity = trigramRarity(common);

    // Trigram with non-printable bytes: low frequency, high rarity
    const rare = trigramHash(&[_]u8{ 0x01, 0x02, 0x03 });
    const rare_rarity = trigramRarity(rare);

    // Rare should have higher rarity score
    try std.testing.expect(rare_rarity > common_rarity);
}

test "selectBestTrigrams returns K rarest trigrams" {
    var trigrams: std.ArrayList(u32) = .{};
    defer trigrams.deinit(std.testing.allocator);

    // Add some trigrams
    try trigrams.append(std.testing.allocator, trigramHash("the"));
    try trigrams.append(std.testing.allocator, trigramHash("and"));
    try trigrams.append(std.testing.allocator, trigramHash(&[_]u8{ 0xFF, 0xFE, 0xFD }));

    const selected = try selectBestTrigrams(trigrams.items, 2, std.testing.allocator);
    defer std.testing.allocator.free(selected);

    // Should have selected 2 trigrams
    try std.testing.expectEqual(@as(usize, 2), selected.len);
}

test "selectBestTrigrams handles k larger than list size" {
    var trigrams: std.ArrayList(u32) = .{};
    defer trigrams.deinit(std.testing.allocator);

    try trigrams.append(std.testing.allocator, trigramHash("abc"));

    const selected = try selectBestTrigrams(trigrams.items, 10, std.testing.allocator);
    defer std.testing.allocator.free(selected);

    // Should only return available trigrams
    try std.testing.expectEqual(@as(usize, 1), selected.len);
}

test "selectBestTrigrams with empty list" {
    const selected = try selectBestTrigrams(&.{}, 5, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), selected.len);
}

/// Candidate entry for rarity-based selection
const RarityCandidate = struct {
    rarity: f32,
    hash: u32,
};

/// Comparator for sorting trigrams by rarity (descending)
fn compareRarity(_: void, a: RarityCandidate, b: RarityCandidate) bool {
    return a.rarity > b.rarity;
}

/// Select the K rarest (most selective) trigrams from a list.
/// Rarer trigrams produce smaller posting lists, making intersection faster.
///
/// Implementation: creates (rarity, hash) pairs, sorts by rarity descending,
/// and returns the K rarest hashes.
pub fn selectBestTrigrams(
    all_trigrams: []const u32,
    k: usize,
    allocator: std.mem.Allocator,
) ![]u32 {
    if (all_trigrams.len == 0) return &.{};
    if (k == 0) return &.{};

    const actual_k = @min(k, all_trigrams.len);

    // Create a list of (rarity, hash) pairs
    var candidates: std.ArrayList(RarityCandidate) = .{};
    errdefer if (candidates.capacity > 0) candidates.deinit(allocator);

    for (all_trigrams) |hash| {
        const rarity = trigramRarity(hash);
        try candidates.append(allocator, .{ .rarity = rarity, .hash = hash });
    }

    // Sort by rarity in descending order (highest rarity first)
    std.mem.sort(RarityCandidate, candidates.items, {}, compareRarity);

    // Extract the K rarest hashes
    var result = try allocator.alloc(u32, actual_k);
    for (0..actual_k) |i| {
        result[i] = candidates.items[i].hash;
    }

    candidates.deinit(allocator);
    return result;
}
