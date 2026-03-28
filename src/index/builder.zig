const std = @import("std");
const trigram = @import("../engine/trigram.zig");
const bloom = @import("../engine/bloom.zig");
const walker = @import("../io/walker.zig");
const mmap = @import("../io/mmap.zig");

/// In-memory trigram index built from a set of files.
///
/// Structure:
///   - file_paths: list of indexed file paths (file_id = index into this list)
///   - postings: trigram_hash -> list of PostingEntry
///
/// Each PostingEntry includes bloom filter masks for "3.5-gram" selectivity.
pub const TrigramIndex = struct {
    /// Indexed file paths. file_id is the index into this slice.
    file_paths: [][]const u8,
    /// Map from trigram hash to posting list (sorted by file_id).
    postings: std.AutoHashMap(u32, []PostingEntry),
    /// Total number of files indexed.
    file_count: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TrigramIndex) void {
        for (self.file_paths) |p| self.allocator.free(p);
        self.allocator.free(self.file_paths);

        var it = self.postings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.postings.deinit();
    }
};

/// A single entry in a posting list.
pub const PostingEntry = struct {
    file_id: u32,
    loc_mask: u8, // bloom: position bits
    next_mask: u8, // bloom: next-char bits
};

/// Per-file indexing result: the trigrams extracted from one file.
const FileTrigramResult = struct {
    file_id: u32,
    /// Each entry: (trigram_hash, loc_mask, next_mask)
    entries: []TrigramEntry,

    const TrigramEntry = struct {
        hash: u32,
        loc_mask: u8,
        next_mask: u8,
    };
};

/// Build a trigram index from all files under the given paths.
/// Uses parallel workers for file indexing when the file count justifies it.
pub fn buildIndex(allocator: std.mem.Allocator, paths: []const []const u8, max_depth: ?u32) !TrigramIndex {
    // Phase 1: Collect all file paths
    var file_list: std.ArrayList([]const u8) = .{};
    defer if (file_list.capacity > 0) file_list.deinit(allocator);

    for (paths) |path| {
        const stat = std.fs.cwd().statFile(path) catch continue;
        if (stat.kind == .directory) {
            var dir_walker = walker.DirWalker.init(allocator, path, max_depth);
            defer dir_walker.deinit();
            while (try dir_walker.next()) |file_path| {
                try file_list.append(allocator, file_path);
            }
        } else {
            const owned = try allocator.dupe(u8, path);
            try file_list.append(allocator, owned);
        }
    }

    const file_count = file_list.items.len;

    // Phase 2: Index files in parallel
    // Each worker produces a FileTrigramResult per file, then we merge sequentially.
    const results = try allocator.alloc(?FileTrigramResult, file_count);
    defer {
        for (results) |r| {
            if (r) |res| allocator.free(res.entries);
        }
        allocator.free(results);
    }
    @memset(results, null);

    const thread_count: u32 = @intCast(@min(
        file_count,
        std.Thread.getCpuCount() catch 4,
    ));

    if (thread_count > 1 and file_count > 8) {
        // Parallel path
        var pool: std.Thread.Pool = undefined;
        try pool.init(.{
            .allocator = allocator,
            .n_jobs = thread_count,
        });
        defer pool.deinit();

        var wg = std.Thread.WaitGroup{};

        for (file_list.items, 0..) |file_path, file_idx| {
            wg.start();
            pool.spawn(indexFileWorker, .{ allocator, file_path, @as(u32, @intCast(file_idx)), results, &wg }) catch {
                wg.finish();
                continue;
            };
        }

        wg.wait();
    } else {
        // Sequential path for small file sets
        for (file_list.items, 0..) |file_path, file_idx| {
            indexFileWorker(allocator, file_path, @intCast(file_idx), results, null);
        }
    }

    // Phase 3: Merge results into posting lists
    var temp_postings = std.AutoHashMap(u32, std.ArrayList(PostingEntry)).init(allocator);
    defer {
        var it = temp_postings.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.capacity > 0) entry.value_ptr.deinit(allocator);
        }
        temp_postings.deinit();
    }

    for (results) |maybe_result| {
        const result = maybe_result orelse continue;
        for (result.entries) |te| {
            const gop = try temp_postings.getOrPut(te.hash);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            try gop.value_ptr.append(allocator, .{
                .file_id = result.file_id,
                .loc_mask = te.loc_mask,
                .next_mask = te.next_mask,
            });
        }
    }

    // Phase 4: Convert temp ArrayLists to owned slices
    var postings = std.AutoHashMap(u32, []PostingEntry).init(allocator);
    errdefer {
        var it = postings.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        postings.deinit();
    }

    var temp_it = temp_postings.iterator();
    while (temp_it.next()) |entry| {
        const slice = try entry.value_ptr.toOwnedSlice(allocator);
        try postings.put(entry.key_ptr.*, slice);
    }

    // Transfer file paths ownership
    const file_paths = try file_list.toOwnedSlice(allocator);

    return .{
        .file_paths = file_paths,
        .postings = postings,
        .file_count = @intCast(file_paths.len),
        .allocator = allocator,
    };
}

/// Worker function: index a single file and store the result.
/// Lock-free — each worker writes to its own slot in the results array.
fn indexFileWorker(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    file_id: u32,
    results: []?FileTrigramResult,
    wg: ?*std.Thread.WaitGroup,
) void {
    defer if (wg) |w| w.finish();

    var mapped = mmap.MappedFile.open(file_path) catch return;
    defer mapped.close();

    const contents = mapped.data();
    if (contents.len < trigram.TRIGRAM_SIZE) return;
    if (isBinary(contents)) return;

    const result = extractFileTrigrams(allocator, contents, file_id) catch return;
    results[file_id] = result;
}

/// Extract all unique trigrams from a file's contents.
/// Returns a flat array of (hash, loc_mask, next_mask) per unique trigram.
fn extractFileTrigrams(
    allocator: std.mem.Allocator,
    contents: []const u8,
    file_id: u32,
) !FileTrigramResult {
    var seen = std.AutoHashMap(u32, struct { loc_mask: u8, next_mask: u8 }).init(allocator);
    defer seen.deinit();

    for (0..contents.len - trigram.TRIGRAM_SIZE + 1) |i| {
        const hash = trigram.trigramHash(contents[i..][0..3]);
        const loc_bit = bloom.locationMask(i);
        const next_ch: ?u8 = if (i + trigram.TRIGRAM_SIZE < contents.len)
            contents[i + trigram.TRIGRAM_SIZE]
        else
            null;
        const next_bit: u8 = if (next_ch) |nc| bloom.nextCharMask(nc) else 0xFF;

        const result = try seen.getOrPut(hash);
        if (result.found_existing) {
            result.value_ptr.loc_mask |= loc_bit;
            result.value_ptr.next_mask |= next_bit;
        } else {
            result.value_ptr.* = .{ .loc_mask = loc_bit, .next_mask = next_bit };
        }
    }

    // Flatten into array
    var entries = try allocator.alloc(FileTrigramResult.TrigramEntry, seen.count());
    var idx: usize = 0;
    var it = seen.iterator();
    while (it.next()) |entry| {
        entries[idx] = .{
            .hash = entry.key_ptr.*,
            .loc_mask = entry.value_ptr.loc_mask,
            .next_mask = entry.value_ptr.next_mask,
        };
        idx += 1;
    }

    return .{
        .file_id = file_id,
        .entries = entries,
    };
}

// (indexFileContents removed — replaced by extractFileTrigrams + merge in buildIndex)

fn isBinary(contents: []const u8) bool {
    const check_len = @min(contents.len, 512);
    for (contents[0..check_len]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────

test "extractFileTrigrams basic" {
    const data = "hello world";
    const result = try extractFileTrigrams(std.testing.allocator, data, 0);
    defer std.testing.allocator.free(result.entries);

    // "hello world" has 9 trigrams: hel, ell, llo, lo_, o_w, _wo, wor, orl, rld
    try std.testing.expectEqual(@as(usize, 9), result.entries.len);
    try std.testing.expectEqual(@as(u32, 0), result.file_id);
}
