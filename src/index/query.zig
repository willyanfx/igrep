const std = @import("std");
const trigram = @import("../engine/trigram.zig");
const bloom = @import("../engine/bloom.zig");
const builder = @import("builder.zig");
const query_decompose = @import("query_decompose.zig");

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
///   2. For each trigram, get the posting list from the index.
///   3. Intersect all posting lists (a file must appear in ALL lists).
///   4. Optionally apply bloom filter masks for extra filtering.
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

    // Find the posting list for the first trigram
    const first_postings = index.postings.get(pattern_trigrams[0]) orelse {
        // Trigram not in index — no files can match
        return .{ .file_ids = &.{}, .allocator = allocator };
    };

    // Start with file IDs from the first posting list
    var candidates = std.AutoHashMap(u32, void).init(allocator);
    defer candidates.deinit();

    for (first_postings) |entry| {
        try candidates.put(entry.file_id, {});
    }

    // Intersect with remaining trigram posting lists
    for (pattern_trigrams[1..]) |tri_hash| {
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

/// Query the trigram index using a decomposed regex QueryPlan.
///
/// This enables indexed search for regex patterns by extracting literal
/// fragments from the regex AST and querying their trigrams.
/// Falls back to allFiles if the plan is not selective.
pub fn queryCandidatesFromPlan(
    index: *const builder.TrigramIndex,
    plan: *const query_decompose.QueryPlan,
    allocator: std.mem.Allocator,
) !QueryResult {
    if (!plan.isSelective()) {
        return allFiles(index, allocator);
    }

    const file_ids = try executePlan(index, plan, allocator);

    if (file_ids) |ids| {
        return .{ .file_ids = ids, .allocator = allocator };
    }

    return allFiles(index, allocator);
}

/// Execute a QueryPlan recursively, returning a sorted list of candidate file IDs.
/// Returns null for MatchAll (caller should fall back to allFiles).
fn executePlan(
    index: *const builder.TrigramIndex,
    plan: *const query_decompose.QueryPlan,
    allocator: std.mem.Allocator,
) !?[]u32 {
    switch (plan.*) {
        .match_all => return null,

        .trigrams => |hashes| {
            return try intersectTrigramPostings(index, hashes, allocator);
        },

        .and_plan => |plans| {
            // Execute each sub-plan and intersect the results
            var result_set: ?std.AutoHashMap(u32, void) = null;
            defer if (result_set) |*rs| rs.deinit();

            for (plans) |*sub| {
                const sub_ids = try executePlan(index, sub, allocator);
                if (sub_ids == null) continue; // MatchAll sub-plan, skip

                defer if (sub_ids.?.len > 0) allocator.free(sub_ids.?);

                if (result_set == null) {
                    // First selective sub-plan — seed the result
                    result_set = std.AutoHashMap(u32, void).init(allocator);
                    for (sub_ids.?) |id| {
                        try result_set.?.put(id, {});
                    }
                } else {
                    // Intersect with existing results
                    var sub_set = std.AutoHashMap(u32, void).init(allocator);
                    defer sub_set.deinit();
                    for (sub_ids.?) |id| {
                        try sub_set.put(id, {});
                    }

                    var remove_list: std.ArrayList(u32) = .{};
                    defer if (remove_list.capacity > 0) remove_list.deinit(allocator);

                    var it = result_set.?.keyIterator();
                    while (it.next()) |key| {
                        if (!sub_set.contains(key.*)) {
                            try remove_list.append(allocator, key.*);
                        }
                    }
                    for (remove_list.items) |id| {
                        _ = result_set.?.remove(id);
                    }
                }

                if (result_set != null and result_set.?.count() == 0) {
                    // Early exit: no candidates left
                    var rs = result_set.?;
                    rs.deinit();
                    result_set = null;
                    return &.{};
                }
            }

            if (result_set) |*rs| {
                var result = try allocator.alloc(u32, rs.count());
                var idx: usize = 0;
                var it = rs.keyIterator();
                while (it.next()) |key| {
                    result[idx] = key.*;
                    idx += 1;
                }
                std.mem.sort(u32, result, {}, std.sort.asc(u32));
                return result;
            }

            return null; // All sub-plans were MatchAll
        },

        .or_plan => |plans| {
            // Execute each sub-plan and union the results
            var result_set = std.AutoHashMap(u32, void).init(allocator);
            defer result_set.deinit();

            for (plans) |*sub| {
                const sub_ids = try executePlan(index, sub, allocator);
                if (sub_ids == null) {
                    // One branch is MatchAll → entire OR is MatchAll
                    return null;
                }
                defer if (sub_ids.?.len > 0) allocator.free(sub_ids.?);

                for (sub_ids.?) |id| {
                    try result_set.put(id, {});
                }
            }

            if (result_set.count() == 0) {
                return &.{};
            }

            var result = try allocator.alloc(u32, result_set.count());
            var idx: usize = 0;
            var it = result_set.keyIterator();
            while (it.next()) |key| {
                result[idx] = key.*;
                idx += 1;
            }
            std.mem.sort(u32, result, {}, std.sort.asc(u32));
            return result;
        },
    }
}

/// Intersect posting lists for a set of trigram hashes.
/// Returns sorted file IDs that appear in ALL posting lists.
fn intersectTrigramPostings(
    index: *const builder.TrigramIndex,
    hashes: []const u32,
    allocator: std.mem.Allocator,
) ![]u32 {
    if (hashes.len == 0) {
        return &.{};
    }

    // Get first posting list
    const first_postings = index.postings.get(hashes[0]) orelse {
        return &.{};
    };

    var candidates = std.AutoHashMap(u32, void).init(allocator);
    defer candidates.deinit();

    for (first_postings) |entry| {
        try candidates.put(entry.file_id, {});
    }

    // Intersect with remaining posting lists
    for (hashes[1..]) |hash| {
        const postings = index.postings.get(hash) orelse {
            return &.{};
        };

        var posting_set = std.AutoHashMap(u32, void).init(allocator);
        defer posting_set.deinit();
        for (postings) |entry| {
            try posting_set.put(entry.file_id, {});
        }

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
            return &.{};
        }
    }

    var result = try allocator.alloc(u32, candidates.count());
    var idx: usize = 0;
    var it = candidates.keyIterator();
    while (it.next()) |key| {
        result[idx] = key.*;
        idx += 1;
    }
    std.mem.sort(u32, result, {}, std.sort.asc(u32));
    return result;
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

test "queryCandidatesFromPlan returns allFiles for non-selective plan" {
    var postings = std.AutoHashMap(u32, []builder.PostingEntry).init(std.testing.allocator);
    defer postings.deinit();

    var paths = try std.testing.allocator.alloc([]const u8, 3);
    defer std.testing.allocator.free(paths);
    paths[0] = "a.txt";
    paths[1] = "b.txt";
    paths[2] = "c.txt";

    const index = builder.TrigramIndex{
        .file_paths = paths,
        .postings = postings,
        .file_count = 3,
        .allocator = std.testing.allocator,
    };

    // A non-selective plan (MatchAll) should return ALL files
    var plan = query_decompose.QueryPlan{ .match_all = {} };
    var result = try queryCandidatesFromPlan(&index, &plan, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.file_ids.len);
}

test "queryCandidatesFromPlan with selective plan yielding zero results does not leak" {
    var postings = std.AutoHashMap(u32, []builder.PostingEntry).init(std.testing.allocator);
    defer postings.deinit();

    var paths = try std.testing.allocator.alloc([]const u8, 1);
    defer std.testing.allocator.free(paths);
    paths[0] = "a.txt";

    const index = builder.TrigramIndex{
        .file_paths = paths,
        .postings = postings,
        .file_count = 1,
        .allocator = std.testing.allocator,
    };

    // Trigrams that don't exist in the index → empty result, must not leak
    var hashes = [_]u32{0x123456};
    var plan = query_decompose.QueryPlan{ .trigrams = &hashes };
    var result = try queryCandidatesFromPlan(&index, &plan, std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.file_ids.len);
}

test "intersectTrigramPostings empty hashes does not leak" {
    var postings = std.AutoHashMap(u32, []builder.PostingEntry).init(std.testing.allocator);
    defer postings.deinit();

    const index = builder.TrigramIndex{
        .file_paths = &.{},
        .postings = postings,
        .file_count = 0,
        .allocator = std.testing.allocator,
    };

    const result = try intersectTrigramPostings(&index, &.{}, std.testing.allocator);
    // Result is comptime empty slice, no free needed
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
