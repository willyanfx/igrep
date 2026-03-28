const std = @import("std");
const trigram = @import("../engine/trigram.zig");
const bloom = @import("../engine/bloom.zig");
const builder = @import("builder.zig");

/// Query result: list of candidate file IDs that might contain the pattern.
pub const QueryResult = struct {
    /// File IDs that are candidates (sorted).
    file_ids: []u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueryResult) void {
        if (self.file_ids.len > 0) self.allocator.free(self.file_ids);
    }
};

/// Query the trigram index for candidate files matching a pattern.
///
/// Algorithm:
///   1. Extract all trigrams from the literal part of the pattern.
///   2. Select the K rarest trigrams (best for filtering).
///   3. For each selected trigram, get the posting list from the index.
///   4. Intersect selected posting lists (a file must appear in ALL lists).
///   5. Optionally apply bloom filter masks for extra filtering.
///
/// This is more efficient than intersecting all trigrams when patterns are long,
/// since rare trigrams produce smaller posting lists.
///
/// Returns file IDs that are candidates — these must still be verified
/// by actually searching the file contents.
pub fn queryCandidates(
    index: *const builder.TrigramIndex,
    pattern: []const u8,
    allocator: std.mem.Allocator,
) !QueryResult {
    // Extract trigrams from the pattern
    if (pattern.len < trigram.TRIGRAM_SIZE) {
        // Pattern too short for trigrams — all files are candidates
        return allFiles(index, allocator);
    }

    const pattern_trigrams = try trigram.extractTrigrams(allocator, pattern);
    defer if (pattern_trigrams.len > 0) allocator.free(pattern_trigrams);

    if (pattern_trigrams.len == 0) {
        return allFiles(index, allocator);
    }

    // Select the K rarest (most selective) trigrams
    // K=3 is usually sufficient for high selectivity while reducing intersection work
    const k_best = @min(@as(usize, 4), pattern_trigrams.len);
    const best_trigrams = try trigram.selectBestTrigrams(pattern_trigrams, k_best, allocator);
    defer if (best_trigrams.len > 0) allocator.free(best_trigrams);

    // Find the posting list for the first best trigram
    const first_postings = index.postings.get(best_trigrams[0]) orelse {
        // Trigram not in index — no files can match
        return .{ .file_ids = &.{}, .allocator = allocator };
    };

    // Start with file IDs from the first posting list
    var candidates = std.AutoHashMap(u32, void).init(allocator);
    defer candidates.deinit();

    for (first_postings) |entry| {
        try candidates.put(entry.file_id, {});
    }

    // Intersect with remaining best trigram posting lists
    for (best_trigrams[1..]) |tri_hash| {
        const postings = index.postings.get(tri_hash) orelse {
            // This trigram doesn't exist in any file — no matches possible
            return .{ .file_ids = &.{}, .allocator = allocator };
        };

        // Build set of file IDs in this posting list
        var posting_set = std.AutoHashMap(u32, void).init(allocator);
        defer posting_set.deinit();
        for (postings) |entry| {
            try posting_set.put(entry.file_id, {});
        }

        // Remove candidates not in this posting list
        var remove_list: std.ArrayList(u32) = .{};
        defer if (remove_list.capacity > 0) remove_list.deinit(allocator);

        var cand_it = candidates.keyIterator();
        while (cand_it.next()) |key| {
            if (!posting_set.contains(key.*)) {
                try remove_list.append(allocator, key.*);
            }
        }

        for (remove_list.items) |id| {
            _ = candidates.remove(id);
        }

        if (candidates.count() == 0) {
            return .{ .file_ids = &.{}, .allocator = allocator };
        }
    }

    // Apply bloom filter for additional selectivity (3.5-gram)
    if (pattern.len > trigram.TRIGRAM_SIZE) {
        try applyBloomFilter(index, pattern, &candidates, allocator);
    }

    // Convert to sorted slice
    var result = try allocator.alloc(u32, candidates.count());
    var idx: usize = 0;
    var it = candidates.keyIterator();
    while (it.next()) |key| {
        result[idx] = key.*;
        idx += 1;
    }

    std.mem.sort(u32, result, {}, std.sort.asc(u32));

    return .{ .file_ids = result, .allocator = allocator };
}

/// Apply bloom filter masks to further narrow candidates.
/// For each trigram position in the pattern, check if the bloom masks
/// in the posting entries are compatible with the actual next character.
fn applyBloomFilter(
    index: *const builder.TrigramIndex,
    pattern: []const u8,
    candidates: *std.AutoHashMap(u32, void),
    allocator: std.mem.Allocator,
) !void {
    if (pattern.len <= trigram.TRIGRAM_SIZE) return;

    // Check each trigram position's next-char bloom
    for (0..pattern.len - trigram.TRIGRAM_SIZE) |i| {
        const hash = trigram.trigramHash(pattern[i..][0..3]);
        const next_char = if (i + trigram.TRIGRAM_SIZE < pattern.len)
            pattern[i + trigram.TRIGRAM_SIZE]
        else
            continue;

        const postings = index.postings.get(hash) orelse continue;
        const expected_next_bit = bloom.nextCharMask(next_char);

        // For each candidate, check if the bloom mask is compatible
        var remove_list: std.ArrayList(u32) = .{};
        defer if (remove_list.capacity > 0) remove_list.deinit(allocator);

        var cand_it = candidates.keyIterator();
        while (cand_it.next()) |file_id| {
            // Find this file's entry in the posting list
            var found = false;
            for (postings) |entry| {
                if (entry.file_id == file_id.*) {
                    // Check if the next_mask could have this next char
                    if ((entry.next_mask & expected_next_bit) != 0) {
                        found = true;
                    }
                    break;
                }
            }
            if (!found) {
                try remove_list.append(allocator, file_id.*);
            }
        }

        for (remove_list.items) |id| {
            _ = candidates.remove(id);
        }
    }
}

/// Return all file IDs (when pattern is too short for trigram filtering).
fn allFiles(index: *const builder.TrigramIndex, allocator: std.mem.Allocator) !QueryResult {
    var result = try allocator.alloc(u32, index.file_count);
    for (0..index.file_count) |i| {
        result[i] = @intCast(i);
    }
    return .{ .file_ids = result, .allocator = allocator };
}

// ── Tests ────────────────────────────────────────────────────────────

test "queryCandidates short pattern returns all files" {
    // Pattern shorter than 3 bytes → all files are candidates
    var postings = std.AutoHashMap(u32, []builder.PostingEntry).init(std.testing.allocator);
    defer postings.deinit();

    var paths = try std.testing.allocator.alloc([]const u8, 3);
    defer std.testing.allocator.free(paths);
    paths[0] = "a";
    paths[1] = "b";
    paths[2] = "c";

    const index = builder.TrigramIndex{
        .file_paths = paths,
        .postings = postings,
        .file_count = 3,
        .allocator = std.testing.allocator,
    };

    var result = try queryCandidates(&index, "ab", std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.file_ids.len);
}

test "queryCandidates filters non-matching files" {
    // Create an index where only file 0 has trigram "hel"
    var postings = std.AutoHashMap(u32, []builder.PostingEntry).init(std.testing.allocator);
    defer {
        var it = postings.iterator();
        while (it.next()) |entry| std.testing.allocator.free(entry.value_ptr.*);
        postings.deinit();
    }

    const hash_hel = trigram.trigramHash("hel");
    const hash_ell = trigram.trigramHash("ell");
    const hash_llo = trigram.trigramHash("llo");

    // File 0 has all three, file 1 has only "hel"
    var entries_hel = try std.testing.allocator.alloc(builder.PostingEntry, 2);
    entries_hel[0] = .{ .file_id = 0, .loc_mask = 0xFF, .next_mask = 0xFF };
    entries_hel[1] = .{ .file_id = 1, .loc_mask = 0xFF, .next_mask = 0xFF };
    try postings.put(hash_hel, entries_hel);

    var entries_ell = try std.testing.allocator.alloc(builder.PostingEntry, 1);
    entries_ell[0] = .{ .file_id = 0, .loc_mask = 0xFF, .next_mask = 0xFF };
    try postings.put(hash_ell, entries_ell);

    var entries_llo = try std.testing.allocator.alloc(builder.PostingEntry, 1);
    entries_llo[0] = .{ .file_id = 0, .loc_mask = 0xFF, .next_mask = 0xFF };
    try postings.put(hash_llo, entries_llo);

    var paths = try std.testing.allocator.alloc([]const u8, 2);
    defer std.testing.allocator.free(paths);
    paths[0] = "file0.txt";
    paths[1] = "file1.txt";

    const index = builder.TrigramIndex{
        .file_paths = paths,
        .postings = postings,
        .file_count = 2,
        .allocator = std.testing.allocator,
    };

    // "hello" has trigrams hel, ell, llo — only file 0 has all three
    var result = try queryCandidates(&index, "hello", std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.file_ids.len);
    try std.testing.expectEqual(@as(u32, 0), result.file_ids[0]);
}
