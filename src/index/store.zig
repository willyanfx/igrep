const std = @import("std");
const builder = @import("builder.zig");

/// On-disk index format for the trigram index.
///
/// Binary layout:
///   Header:   MAGIC(4) + VERSION(4) + file_count(4) + trigram_count(4)
///   Files:    [path_len(u16) + path_bytes] × file_count
///   Lookup:   [trigram_hash(u32) + offset(u32) + count(u32)] × trigram_count (sorted by hash)
///   Postings: [file_id(u32) + loc_mask(u8) + next_mask(u8)] × total_entries
///
/// The lookup table is sorted by trigram_hash for binary search.
/// Offsets are byte offsets into the postings section.

pub const MAGIC: [4]u8 = .{ 'I', 'G', 'R', 'X' };
pub const VERSION: u32 = 1;
pub const INDEX_DIR = ".igrep";
pub const INDEX_FILE = ".igrep/index";

const POSTING_ENTRY_SIZE: u32 = 6; // 4 (file_id) + 1 (loc) + 1 (next)
const LOOKUP_ENTRY_SIZE: u32 = 12; // 4 (hash) + 4 (offset) + 4 (count)

/// A lookup table entry (in-memory representation).
const LookupEntry = struct {
    trigram_hash: u32,
    offset: u32, // byte offset into postings section
    count: u32, // number of PostingEntries
};

/// Write a TrigramIndex to disk in binary format.
pub fn writeIndex(index: *const builder.TrigramIndex, dir_path: []const u8, allocator: std.mem.Allocator) !void {
    // Ensure .igrep directory exists
    const igrep_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, INDEX_DIR });
    defer allocator.free(igrep_dir);
    std.fs.cwd().makePath(igrep_dir) catch {};

    const index_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, INDEX_FILE });
    defer allocator.free(index_path);

    const file = try std.fs.cwd().createFile(index_path, .{});
    defer file.close();

    var buf_writer_mem: [16384]u8 = undefined;
    var bw = file.writer(&buf_writer_mem);
    const writer = &bw.interface;

    // ── Header ──
    try writer.writeAll(&MAGIC);
    try writer.writeAll(&std.mem.toBytes(VERSION));
    try writer.writeAll(&std.mem.toBytes(index.file_count));
    const trigram_count: u32 = @intCast(index.postings.count());
    try writer.writeAll(&std.mem.toBytes(trigram_count));

    // ── File paths ──
    for (index.file_paths) |path| {
        const path_len: u16 = @intCast(path.len);
        try writer.writeAll(&std.mem.toBytes(path_len));
        try writer.writeAll(path);
    }

    // ── Build sorted lookup table ──
    var lookup_entries: std.ArrayList(LookupEntry) = .{};
    defer if (lookup_entries.capacity > 0) lookup_entries.deinit(allocator);

    var post_it = index.postings.iterator();
    while (post_it.next()) |entry| {
        const count: u32 = @intCast(entry.value_ptr.len);
        try lookup_entries.append(allocator, .{
            .trigram_hash = entry.key_ptr.*,
            .offset = 0, // recomputed after sort
            .count = count,
        });
    }

    // Sort by trigram_hash for binary search
    std.mem.sort(LookupEntry, lookup_entries.items, {}, struct {
        fn lessThan(_: void, a: LookupEntry, b: LookupEntry) bool {
            return a.trigram_hash < b.trigram_hash;
        }
    }.lessThan);

    // Recompute offsets in sorted order (must match write order)
    var offset: u32 = 0;
    for (lookup_entries.items) |*entry| {
        entry.offset = offset;
        offset += entry.count * POSTING_ENTRY_SIZE;
    }

    // ── Write lookup table ──
    for (lookup_entries.items) |entry| {
        try writer.writeAll(&std.mem.toBytes(entry.trigram_hash));
        try writer.writeAll(&std.mem.toBytes(entry.offset));
        try writer.writeAll(&std.mem.toBytes(entry.count));
    }

    // ── Write postings (in same order as lookup) ──
    for (lookup_entries.items) |entry| {
        const postings = index.postings.get(entry.trigram_hash) orelse continue;
        for (postings) |pe| {
            try writer.writeAll(&std.mem.toBytes(pe.file_id));
            try writer.writeAll(&.{pe.loc_mask});
            try writer.writeAll(&.{pe.next_mask});
        }
    }

    // Flush
    writer.flush() catch {};
}

/// Read a trigram index from disk.
/// Returns an in-memory TrigramIndex.
pub fn readIndex(dir_path: []const u8, allocator: std.mem.Allocator) !builder.TrigramIndex {
    const index_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, INDEX_FILE });
    defer allocator.free(index_path);

    const file_data = try std.fs.cwd().readFileAlloc(allocator, index_path, 256 * 1024 * 1024); // 256MB max
    defer allocator.free(file_data);

    if (file_data.len < 16) return error.InvalidIndex;

    // ── Header ──
    if (!std.mem.eql(u8, file_data[0..4], &MAGIC)) return error.InvalidIndex;
    const version = std.mem.bytesToValue(u32, file_data[4..8]);
    if (version != VERSION) return error.UnsupportedVersion;
    const file_count = std.mem.bytesToValue(u32, file_data[8..12]);
    const trigram_count = std.mem.bytesToValue(u32, file_data[12..16]);

    var pos: usize = 16;

    // ── File paths ──
    var file_paths = try allocator.alloc([]const u8, file_count);
    errdefer {
        for (file_paths[0..file_count]) |p| allocator.free(p);
        allocator.free(file_paths);
    }

    for (0..file_count) |i| {
        if (pos + 2 > file_data.len) return error.InvalidIndex;
        const path_len = std.mem.bytesToValue(u16, file_data[pos..][0..2]);
        pos += 2;
        if (pos + path_len > file_data.len) return error.InvalidIndex;
        file_paths[i] = try allocator.dupe(u8, file_data[pos..][0..path_len]);
        pos += path_len;
    }

    // ── Lookup table ──
    const lookup_size = trigram_count * LOOKUP_ENTRY_SIZE;
    if (pos + lookup_size > file_data.len) return error.InvalidIndex;

    const postings_start = pos + lookup_size;

    var postings = std.AutoHashMap(u32, []builder.PostingEntry).init(allocator);
    errdefer {
        var it = postings.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        postings.deinit();
    }

    for (0..trigram_count) |_| {
        const hash = std.mem.bytesToValue(u32, file_data[pos..][0..4]);
        const offset = std.mem.bytesToValue(u32, file_data[pos + 4 ..][0..4]);
        const count = std.mem.bytesToValue(u32, file_data[pos + 8 ..][0..4]);
        pos += LOOKUP_ENTRY_SIZE;

        var entries = try allocator.alloc(builder.PostingEntry, count);
        const data_pos = postings_start + offset;

        for (0..count) |j| {
            const ep = data_pos + j * POSTING_ENTRY_SIZE;
            if (ep + POSTING_ENTRY_SIZE > file_data.len) return error.InvalidIndex;
            entries[j] = .{
                .file_id = std.mem.bytesToValue(u32, file_data[ep..][0..4]),
                .loc_mask = file_data[ep + 4],
                .next_mask = file_data[ep + 5],
            };
        }

        try postings.put(hash, entries);
    }

    return .{
        .file_paths = file_paths,
        .postings = postings,
        .file_count = file_count,
        .allocator = allocator,
    };
}

/// Check if an index exists at the given directory.
pub fn indexExists(dir_path: []const u8, allocator: std.mem.Allocator) bool {
    const index_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, INDEX_FILE }) catch return false;
    defer allocator.free(index_path);
    std.fs.cwd().access(index_path, .{}) catch return false;
    return true;
}

// ── Tests ────────────────────────────────────────────────────────────

test "round-trip write and read index" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    // Build a small test index manually
    var postings = std.AutoHashMap(u32, []builder.PostingEntry).init(std.testing.allocator);

    const entries1 = try std.testing.allocator.alloc(builder.PostingEntry, 2);
    entries1[0] = .{ .file_id = 0, .loc_mask = 0x03, .next_mask = 0x0F };
    entries1[1] = .{ .file_id = 1, .loc_mask = 0x01, .next_mask = 0xFF };
    try postings.put(0x616263, entries1); // "abc"

    const entries2 = try std.testing.allocator.alloc(builder.PostingEntry, 1);
    entries2[0] = .{ .file_id = 0, .loc_mask = 0x02, .next_mask = 0x04 };
    try postings.put(0x646566, entries2); // "def"

    const path1 = try std.testing.allocator.dupe(u8, "src/main.zig");
    const path2 = try std.testing.allocator.dupe(u8, "src/lib.zig");
    var file_paths = try std.testing.allocator.alloc([]const u8, 2);
    file_paths[0] = path1;
    file_paths[1] = path2;

    var index = builder.TrigramIndex{
        .file_paths = file_paths,
        .postings = postings,
        .file_count = 2,
        .allocator = std.testing.allocator,
    };
    defer index.deinit();

    // Write to disk
    try writeIndex(&index, dir_path, std.testing.allocator);

    // Read back
    var loaded = try readIndex(dir_path, std.testing.allocator);
    defer loaded.deinit();

    // Verify file metadata
    try std.testing.expectEqual(@as(u32, 2), loaded.file_count);
    try std.testing.expectEqualStrings("src/main.zig", loaded.file_paths[0]);
    try std.testing.expectEqualStrings("src/lib.zig", loaded.file_paths[1]);
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @intCast(loaded.postings.count())));

    // Verify posting lists exist with correct sizes
    const abc_entries = loaded.postings.get(0x616263).?;
    try std.testing.expectEqual(@as(usize, 2), abc_entries.len);

    const def_entries = loaded.postings.get(0x646566).?;
    try std.testing.expectEqual(@as(usize, 1), def_entries.len);
    try std.testing.expectEqual(@as(u32, 0), def_entries[0].file_id);
    try std.testing.expectEqual(@as(u8, 0x02), def_entries[0].loc_mask);
}
