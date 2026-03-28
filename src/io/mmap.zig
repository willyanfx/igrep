const std = @import("std");

/// Memory-mapped file for zero-copy reads.
/// Uses the OS page cache — no userspace buffering needed.
pub const MappedFile = struct {
    ptr: ?[*]align(std.heap.page_size_min) u8 = null,
    len: usize = 0,
    fd: ?std.posix.fd_t = null,

    /// Open and memory-map a file for reading.
    pub fn open(path: []const u8) !MappedFile {
        const file = try std.fs.cwd().openFile(path, .{});
        const fd = file.handle;

        const stat = try std.posix.fstat(fd);
        const size: usize = @intCast(stat.size);

        if (size == 0) {
            std.posix.close(fd);
            return MappedFile{};
        }

        const mapped = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        );

        // Advise the kernel we'll read sequentially
        std.posix.madvise(mapped.ptr, mapped.len, std.posix.MADV.SEQUENTIAL) catch {};

        return MappedFile{
            .ptr = mapped.ptr,
            .len = mapped.len,
            .fd = fd,
        };
    }

    /// Get the file contents as a byte slice.
    pub fn data(self: *const MappedFile) []const u8 {
        if (self.ptr) |p| {
            return p[0..self.len];
        }
        return &.{};
    }

    /// Unmap the file and close the file descriptor.
    pub fn close(self: *MappedFile) void {
        if (self.ptr) |p| {
            std.posix.munmap(@alignCast(p[0..self.len]));
            self.ptr = null;
        }
        if (self.fd) |fd| {
            std.posix.close(fd);
            self.fd = null;
        }
        self.len = 0;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "MappedFile empty file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("empty.txt", .{});
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "empty.txt");
    defer std.testing.allocator.free(path);

    var mapped = try MappedFile.open(path);
    defer mapped.close();

    try std.testing.expectEqual(@as(usize, 0), mapped.data().len);
}

test "MappedFile reads contents" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content = "Hello, instantGrep!\n";
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll(content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "test.txt");
    defer std.testing.allocator.free(path);

    var mapped = try MappedFile.open(path);
    defer mapped.close();

    try std.testing.expectEqualStrings(content, mapped.data());
}
