const std = @import("std");

/// A growable in-memory output buffer that implements the std.Io.Writer interface.
/// Workers use this to format per-file output without holding any locks,
/// then flush the completed buffer to stdout under a brief lock.
pub const OutputBuffer = struct {
    data: std.ArrayList(u8),

    pub fn init() OutputBuffer {
        return .{ .data = .{} };
    }

    /// Initialize with an optional initial capacity hint to avoid early reallocations.
    pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) !OutputBuffer {
        var list = std.ArrayList(u8){};
        try list.ensureTotalCapacity(allocator, capacity);
        return .{ .data = list };
    }

    pub fn deinit(self: *OutputBuffer, allocator: std.mem.Allocator) void {
        if (self.data.capacity > 0) self.data.deinit(allocator);
    }

    /// Get the accumulated output bytes.
    pub fn slice(self: *const OutputBuffer) []const u8 {
        return self.data.items;
    }

    /// Returns true if no output has been written.
    pub fn isEmpty(self: *const OutputBuffer) bool {
        return self.data.items.len == 0;
    }

    /// Reset the buffer for reuse without freeing memory.
    pub fn reset(self: *OutputBuffer) void {
        self.data.items.len = 0;
    }

    /// Write interface — used by Printer via std.Io.Writer.
    pub const WriteError = error{OutOfMemory};

    pub fn write(self: *OutputBuffer, allocator: std.mem.Allocator, bytes: []const u8) WriteError!void {
        self.data.appendSlice(allocator, bytes) catch return error.OutOfMemory;
    }

    pub fn writeByte(self: *OutputBuffer, allocator: std.mem.Allocator, byte: u8) WriteError!void {
        self.data.append(allocator, byte) catch return error.OutOfMemory;
    }
};

/// A Printer-compatible writer that wraps an OutputBuffer.
/// This implements enough of the std.Io.Writer interface to be used
/// by the Printer without requiring the full std.Io.Writer.
pub const BufferWriter = struct {
    buf: *OutputBuffer,
    allocator: std.mem.Allocator,

    pub fn init(buf: *OutputBuffer, allocator: std.mem.Allocator) BufferWriter {
        return .{ .buf = buf, .allocator = allocator };
    }

    pub fn writeAll(self: *BufferWriter, bytes: []const u8) !void {
        try self.buf.write(self.allocator, bytes);
    }

    pub fn writeByte(self: *BufferWriter, byte: u8) !void {
        try self.buf.writeByte(self.allocator, byte);
    }

    pub fn print(self: *BufferWriter, comptime fmt: []const u8, args: anytype) !void {
        // Format into a small stack buffer, then append
        var tmp: [128]u8 = undefined;
        const formatted = std.fmt.bufPrint(&tmp, fmt, args) catch {
            // Fallback: format directly via ArrayList writer
            const writer = self.buf.data.writer(self.allocator);
            try writer.print(fmt, args);
            return;
        };
        try self.buf.write(self.allocator, formatted);
    }

    pub fn flush(_: *BufferWriter) !void {
        // No-op for in-memory buffer
    }
};

test "OutputBuffer basic write and read" {
    var buf = OutputBuffer.init();
    defer buf.deinit(std.testing.allocator);

    try buf.write(std.testing.allocator, "hello ");
    try buf.write(std.testing.allocator, "world");

    try std.testing.expectEqualStrings("hello world", buf.slice());
}

test "OutputBuffer reset" {
    var buf = OutputBuffer.init();
    defer buf.deinit(std.testing.allocator);

    try buf.write(std.testing.allocator, "first");
    try std.testing.expect(!buf.isEmpty());

    buf.reset();
    try std.testing.expect(buf.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), buf.slice().len);

    try buf.write(std.testing.allocator, "second");
    try std.testing.expectEqualStrings("second", buf.slice());
}

test "BufferWriter print formatting" {
    var buf = OutputBuffer.init();
    defer buf.deinit(std.testing.allocator);

    var writer = BufferWriter.init(&buf, std.testing.allocator);
    try writer.print("{d}", .{42});
    try writer.writeAll(":hello");

    try std.testing.expectEqualStrings("42:hello", buf.slice());
}
