const std = @import("std");
const buffer = @import("buffer.zig");

/// Result printer with optional ANSI color support.
/// Can write to either a BufferWriter (per-file lock-free) or a std.Io.Writer (direct stdout).
pub const Printer = struct {
    /// Tagged union for the underlying writer.
    writer_kind: WriterKind,
    use_color: bool,
    show_line_numbers: bool,

    const WriterKind = union(enum) {
        buffered: *buffer.BufferWriter,
        direct: *std.Io.Writer,
    };

    // ANSI color codes
    const color_reset = "\x1b[0m";
    const color_path = "\x1b[35m"; // magenta
    const color_line_num = "\x1b[32m"; // green
    const color_match = "\x1b[1;31m"; // bold red
    const color_separator = "\x1b[36m"; // cyan

    pub fn init(writer: *std.Io.Writer, use_color: bool, show_line_numbers: bool) Printer {
        return .{
            .writer_kind = .{ .direct = writer },
            .use_color = use_color,
            .show_line_numbers = show_line_numbers,
        };
    }

    pub fn initBuffered(writer: *buffer.BufferWriter, use_color: bool, show_line_numbers: bool) Printer {
        return .{
            .writer_kind = .{ .buffered = writer },
            .use_color = use_color,
            .show_line_numbers = show_line_numbers,
        };
    }

    // ── Unified write helpers ──────────────────────────────────────────

    inline fn writeAll(self: *Printer, bytes: []const u8) !void {
        switch (self.writer_kind) {
            .buffered => |w| try w.writeAll(bytes),
            .direct => |w| try w.writeAll(bytes),
        }
    }

    inline fn writeByte(self: *Printer, byte: u8) !void {
        switch (self.writer_kind) {
            .buffered => |w| try w.writeByte(byte),
            .direct => |w| try w.writeByte(byte),
        }
    }

    inline fn printFmt(self: *Printer, comptime fmt: []const u8, args: anytype) !void {
        switch (self.writer_kind) {
            .buffered => |w| try w.print(fmt, args),
            .direct => |w| try w.print(fmt, args),
        }
    }

    /// Flush the underlying writer (no-op for buffered).
    pub fn flush(self: *Printer) void {
        switch (self.writer_kind) {
            .buffered => |w| w.flush() catch {},
            .direct => |w| w.flush() catch {},
        }
    }

    /// Print a matching line with file path, line number, and highlighted match.
    pub fn printMatch(
        self: *Printer,
        file_path: []const u8,
        line_num: u64,
        line: []const u8,
        pattern: []const u8,
        case_sensitive: bool,
    ) !void {
        _ = case_sensitive; // TODO: case-insensitive highlight positions
        // File path
        if (self.use_color) {
            try self.writeAll(color_path);
        }
        try self.writeAll(file_path);
        if (self.use_color) {
            try self.writeAll(color_reset);
        }
        try self.writeAll(":");

        // Line number
        if (self.show_line_numbers) {
            if (self.use_color) {
                try self.writeAll(color_line_num);
            }
            try self.printFmt("{d}", .{line_num});
            if (self.use_color) {
                try self.writeAll(color_reset);
            }
            try self.writeAll(":");
        }

        // Line content with highlighted matches
        if (self.use_color and pattern.len > 0) {
            try self.printHighlighted(line, pattern);
        } else {
            try self.writeAll(line);
        }

        try self.writeAll("\n");
    }

    /// Print a context separator (--) between non-contiguous context groups.
    pub fn printSeparator(self: *Printer) !void {
        if (self.use_color) {
            try self.writeAll(color_separator);
        }
        try self.writeAll("--\n");
        if (self.use_color) {
            try self.writeAll(color_reset);
        }
    }

    /// Print a context (non-matching) line with file path and line number.
    pub fn printContext(
        self: *Printer,
        file_path: []const u8,
        line_num: u64,
        line: []const u8,
    ) !void {
        // File path
        if (self.use_color) {
            try self.writeAll(color_path);
        }
        try self.writeAll(file_path);
        if (self.use_color) {
            try self.writeAll(color_reset);
        }
        try self.writeAll("-");

        // Line number
        if (self.show_line_numbers) {
            if (self.use_color) {
                try self.writeAll(color_line_num);
            }
            try self.printFmt("{d}", .{line_num});
            if (self.use_color) {
                try self.writeAll(color_reset);
            }
            try self.writeAll("-");
        }

        try self.writeAll(line);
        try self.writeAll("\n");
    }

    /// Print a file path (for --files-with-matches / -l mode).
    pub fn printFilePath(self: *Printer, path: []const u8) !void {
        if (self.use_color) {
            try self.writeAll(color_path);
        }
        try self.writeAll(path);
        if (self.use_color) {
            try self.writeAll(color_reset);
        }
        try self.writeAll("\n");
    }

    /// Print match count for a file (for --count / -c mode).
    pub fn printCount(self: *Printer, path: []const u8, count: u64) !void {
        if (self.use_color) {
            try self.writeAll(color_path);
        }
        try self.writeAll(path);
        if (self.use_color) {
            try self.writeAll(color_reset);
        }
        try self.printFmt(":{d}\n", .{count});
    }

    /// Print a line with pattern matches highlighted in bold red.
    fn printHighlighted(self: *Printer, line: []const u8, pattern: []const u8) !void {
        var pos: usize = 0;
        while (pos < line.len) {
            if (pos + pattern.len <= line.len and
                std.mem.eql(u8, line[pos..][0..pattern.len], pattern))
            {
                try self.writeAll(color_match);
                try self.writeAll(pattern);
                try self.writeAll(color_reset);
                pos += pattern.len;
            } else {
                try self.writeByte(line[pos]);
                pos += 1;
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "Printer output" {
    // Smoke test — actual output testing would need a mock writer
}
