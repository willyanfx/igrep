const std = @import("std");
const mmap = @import("mmap.zig");

/// Adaptive file reader that selects between buffered read() and mmap
/// based on file size. Small files (< 256KB) use read() to avoid
/// mmap/munmap syscall overhead; large files use mmap for zero-copy access.
pub const FileContents = union(enum) {
    mapped: mmap.MappedFile,
    buffered: BufferedRead,

    const MMAP_THRESHOLD: usize = 256 * 1024; // 256 KB

    /// Open a file, automatically selecting the best I/O strategy.
    /// If `read_buf` is provided, it will be used for small files (avoids allocation).
    /// Otherwise, allocates a buffer from `allocator`.
    pub fn open(path: []const u8, allocator: std.mem.Allocator, read_buf: ?[]u8) !FileContents {
        const file = try std.fs.cwd().openFile(path, .{});
        const fd = file.handle;

        const stat = try std.posix.fstat(fd);
        const size: usize = @intCast(stat.size);

        if (size == 0) {
            std.posix.close(fd);
            return .{ .buffered = .{ .buf = &.{}, .len = 0, .allocated = null } };
        }

        // Small files: buffered read() is faster (avoids mmap/munmap overhead)
        if (size <= MMAP_THRESHOLD) {
            return openBuffered(fd, size, allocator, read_buf);
        }

        // Large files: mmap for zero-copy
        return openMapped(fd, size);
    }

    fn openBuffered(fd: std.posix.fd_t, size: usize, allocator: std.mem.Allocator, read_buf: ?[]u8) !FileContents {
        // Try reusable buffer first, allocate only if it doesn't fit
        var buf: []u8 = undefined;
        var allocated: ?[]u8 = null;

        if (read_buf) |rb| {
            if (rb.len >= size) {
                buf = rb[0..size];
            } else {
                allocated = try allocator.alloc(u8, size);
                buf = allocated.?;
            }
        } else {
            allocated = try allocator.alloc(u8, size);
            buf = allocated.?;
        }

        errdefer if (allocated) |a| allocator.free(a);

        var total_read: usize = 0;
        while (total_read < size) {
            const n = std.posix.read(fd, buf[total_read..]) catch |err| {
                std.posix.close(fd);
                return err;
            };
            if (n == 0) break;
            total_read += n;
        }
        std.posix.close(fd);

        return .{ .buffered = .{
            .buf = buf.ptr,
            .len = total_read,
            .allocated = allocated,
        } };
    }

    fn openMapped(fd: std.posix.fd_t, size: usize) !FileContents {
        const mapped = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        );

        std.posix.madvise(mapped.ptr, mapped.len, std.posix.MADV.SEQUENTIAL) catch {};

        return .{ .mapped = .{
            .ptr = mapped.ptr,
            .len = mapped.len,
            .fd = fd,
        } };
    }

    /// Get the file contents as a byte slice.
    pub fn data(self: *const FileContents) []const u8 {
        return switch (self.*) {
            .mapped => |*m| m.data(),
            .buffered => |*b| b.data(),
        };
    }

    /// Release resources. For buffered reads with an allocated buffer,
    /// pass the same allocator used to open. For reusable-buffer reads, this is a no-op.
    pub fn close(self: *FileContents, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .mapped => |*m| m.close(),
            .buffered => |*b| b.deinit(allocator),
        }
    }
};

const BufferedRead = struct {
    buf: [*]const u8,
    len: usize,
    /// Non-null only if we allocated the buffer (as opposed to reusing a caller-owned one)
    allocated: ?[]u8,

    pub fn data(self: *const BufferedRead) []const u8 {
        if (self.len == 0) return &.{};
        return self.buf[0..self.len];
    }

    pub fn deinit(self: *BufferedRead, allocator: std.mem.Allocator) void {
        if (self.allocated) |a| {
            allocator.free(a);
            self.allocated = null;
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "FileContents reads small file via buffered path" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Hello, instantGrep!\n";
    const file = try tmp_dir.dir.createFile("small.txt", .{});
    try file.writeAll(content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "small.txt");
    defer std.testing.allocator.free(path);

    var fc = try FileContents.open(path, std.testing.allocator, null);
    defer fc.close(std.testing.allocator);

    try std.testing.expectEqualStrings(content, fc.data());
    // Small file should use buffered path
    try std.testing.expect(fc == .buffered);
}

test "FileContents reads small file with reusable buffer" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Reusable buffer test\n";
    const file = try tmp_dir.dir.createFile("reuse.txt", .{});
    try file.writeAll(content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "reuse.txt");
    defer std.testing.allocator.free(path);

    var reuse_buf: [4096]u8 = undefined;
    var fc = try FileContents.open(path, std.testing.allocator, &reuse_buf);
    defer fc.close(std.testing.allocator);

    try std.testing.expectEqualStrings(content, fc.data());
    try std.testing.expect(fc == .buffered);
    // Should NOT have allocated (reused the provided buffer)
    try std.testing.expect(fc.buffered.allocated == null);
}

test "FileContents handles empty file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("empty.txt", .{});
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "empty.txt");
    defer std.testing.allocator.free(path);

    var fc = try FileContents.open(path, std.testing.allocator, null);
    defer fc.close(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), fc.data().len);
}
