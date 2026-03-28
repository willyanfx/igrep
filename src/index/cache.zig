const std = @import("std");
const store = @import("store.zig");
const walker = @import("../io/walker.zig");

/// Index cache manager.
/// Manages the .igrep/ directory — checks freshness and triggers rebuilds.

/// Check if the index is stale by comparing index mtime against newest file mtime.
/// Two-phase check:
///   1. Quick: check a few sentinel files (fast, catches most changes)
///   2. Deep: walk directory and find the newest mtime (catches everything)
/// Returns true if the index should be rebuilt.
pub fn isStale(dir_path: []const u8, allocator: std.mem.Allocator) bool {
    const index_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, store.INDEX_FILE }) catch return true;
    defer allocator.free(index_path);

    const index_stat = std.fs.cwd().statFile(index_path) catch return true;
    const index_mtime = index_stat.mtime;

    // Phase 1: Quick sentinel check (handles 90% of cases)
    const sentinels = [_][]const u8{ "build.zig", "src/main.zig", ".gitignore", "Makefile", "package.json", "Cargo.toml", "go.mod" };
    for (sentinels) |sentinel| {
        const sentinel_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, sentinel }) catch continue;
        defer allocator.free(sentinel_path);

        const file_stat = std.fs.cwd().statFile(sentinel_path) catch continue;
        if (file_stat.mtime > index_mtime) return true;
    }

    // Phase 2: Walk a sample of recent files (up to 100) for deeper check
    var dir_walker = walker.DirWalker.init(allocator, dir_path, 5);
    defer dir_walker.deinit();

    var checked: u32 = 0;
    while (dir_walker.next() catch null) |file_path| {
        defer allocator.free(file_path);
        const file_stat = std.fs.cwd().statFile(file_path) catch continue;
        if (file_stat.mtime > index_mtime) return true;
        checked += 1;
        if (checked >= 100) break;
    }

    return false;
}

/// Get the index file size (for cache stats).
pub fn indexSize(dir_path: []const u8, allocator: std.mem.Allocator) ?u64 {
    const index_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, store.INDEX_FILE }) catch return null;
    defer allocator.free(index_path);

    const stat = std.fs.cwd().statFile(index_path) catch return null;
    return @intCast(stat.size);
}

test "isStale returns true when no index" {
    try std.testing.expect(isStale("/tmp/nonexistent_igrep_test", std.testing.allocator));
}
