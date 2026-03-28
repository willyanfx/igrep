const std = @import("std");

/// Result printer with optional ANSI color support.
/// Uses the new std.Io.Writer buffered interface for high-throughput output.
pub const Printer = struct {
    writer: *std.Io.Writer,
    use_color: bool,
    show_line_numbers: bool,

    // ANSI color codes
    const color_reset = "\x1b[0m";
    const color_path = "\x1b[35m"; // magenta
    const color_line_num = "\x1b[32m"; // green
    const color_match = "\x1b[1;31m"; // bold red
    const color_separator = "\x1b[36m"; // cyan

    pub fn init(writer: *std.Io.Writer, use_color: bool, show_line_numbers: bool) Printer {
        return .{
            .writer = writer,
            .use_color = use_color,
            .show_line_numbers = show_line_numbers,
        };
    }

    /// Flush the underlying buffered writer.
    pub fn flush(self: *Printer) void {
        self.writer.flush() catch {};
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
            try self.writer.writeAll(color_path);
        }
        try self.writer.writeAll(file_path);
        if (self.use_color) {
            try self.writer.writeAll(color_reset);
        }
        try self.writer.writeAll(":");

        // Line number
        if (self.show_line_numbers) {
            if (self.use_color) {
                try self.writer.writeAll(color_line_num);
            }
            try self.writer.print("{d}", .{line_num});
            if (self.use_color) {
                try self.writer.writeAll(color_reset);
            }
            try self.writer.writeAll(":");
        }

        // Line content with highlighted matches
        if (self.use_color and pattern.len > 0) {
            try self.printHighlighted(line, pattern);
        } else {
            try self.writer.writeAll(line);
        }

        try self.writer.writeAll("\n");
    }

    /// Print a context separator (--) between non-contiguous context groups.
    pub fn printSeparator(self: *Printer) !void {
        if (self.use_color) {
            try self.writer.writeAll(color_separator);
        }
        try self.writer.writeAll("--\n");
        if (self.use_color) {
            try self.writer.writeAll(color_reset);
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
            try self.writer.writeAll(color_path);
        }
        try self.writer.writeAll(file_path);
        if (self.use_color) {
            try self.writer.writeAll(color_reset);
        }
        try self.writer.writeAll("-");

        // Line number
        if (self.show_line_numbers) {
            if (self.use_color) {
                try self.writer.writeAll(color_line_num);
            }
            try self.writer.print("{d}", .{line_num});
            if (self.use_color) {
                try self.writer.writeAll(color_reset);
            }
            try self.writer.writeAll("-");
        }

        try self.writer.writeAll(line);
        try self.writer.writeAll("\n");
    }

    /// Print a file path (for --files-with-matches / -l mode).
    pub fn printFilePath(self: *Printer, path: []const u8) !void {
        if (self.use_color) {
            try self.writer.writeAll(color_path);
        }
        try self.writer.writeAll(path);
        if (self.use_color) {
            try self.writer.writeAll(color_reset);
        }
        try self.writer.writeAll("\n");
    }

    /// Print match count for a file (for --count / -c mode).
    pub fn printCount(self: *Printer, path: []const u8, count: u64) !void {
        if (self.use_color) {
            try self.writer.writeAll(color_path);
        }
        try self.writer.writeAll(path);
        if (self.use_color) {
            try self.writer.writeAll(color_reset);
        }
        try self.writer.print(":{d}\n", .{count});
    }

    /// Print a line with pattern matches highlighted in bold red.
    fn printHighlighted(self: *Printer, line: []const u8, pattern: []const u8) !void {
        var pos: usize = 0;
        while (pos < line.len) {
            if (pos + pattern.len <= line.len and
                std.mem.eql(u8, line[pos..][0..pattern.len], pattern))
            {
                try self.writer.writeAll(color_match);
                try self.writer.writeAll(pattern);
                try self.writer.writeAll(color_reset);
                pos += pattern.len;
            } else {
                try self.writer.writeByte(line[pos]);
                pos += 1;
            }
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "Printer output" {
    // Smoke test — actual output testing would need a mock writer
}
