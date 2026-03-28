const std = @import("std");
const buffer = @import("buffer.zig");

/// JSON Lines output printer (one JSON object per line)
/// Outputs match results in JSON format compatible with the Printer interface.
pub const JsonPrinter = struct {
    /// Tagged union for the underlying writer.
    writer_kind: WriterKind,

    const WriterKind = union(enum) {
        buffered: *buffer.BufferWriter,
        direct: *std.Io.Writer,
    };

    pub fn init(writer: *std.Io.Writer) JsonPrinter {
        return .{
            .writer_kind = .{ .direct = writer },
        };
    }

    pub fn initBuffered(writer: *buffer.BufferWriter) JsonPrinter {
        return .{
            .writer_kind = .{ .buffered = writer },
        };
    }

    // ── Unified write helpers ──────────────────────────────────────────

    inline fn writeAll(self: *JsonPrinter, bytes: []const u8) !void {
        switch (self.writer_kind) {
            .buffered => |w| try w.writeAll(bytes),
            .direct => |w| try w.writeAll(bytes),
        }
    }

    inline fn writeByte(self: *JsonPrinter, byte: u8) !void {
        switch (self.writer_kind) {
            .buffered => |w| try w.writeByte(byte),
            .direct => |w| try w.writeByte(byte),
        }
    }

    inline fn printFmt(self: *JsonPrinter, comptime fmt: []const u8, args: anytype) !void {
        switch (self.writer_kind) {
            .buffered => |w| try w.print(fmt, args),
            .direct => |w| try w.print(fmt, args),
        }
    }

    /// Flush the underlying writer (no-op for buffered).
    pub fn flush(self: *JsonPrinter) void {
        switch (self.writer_kind) {
            .buffered => |w| w.flush() catch {},
            .direct => |w| w.flush() catch {},
        }
    }

    /// Escape a string for JSON output.
    /// Returns true if escaping was needed, false if already clean.
    fn needsEscaping(s: []const u8) bool {
        for (s) |c| {
            switch (c) {
                '"', '\\', '\n', '\r', '\t', 0...31 => return true,
                else => {},
            }
        }
        return false;
    }

    /// Write a JSON string value (with quotes and escaping).
    fn writeJsonString(self: *JsonPrinter, s: []const u8) !void {
        try self.writeByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try self.writeAll("\\\""),
                '\\' => try self.writeAll("\\\\"),
                '\n' => try self.writeAll("\\n"),
                '\r' => try self.writeAll("\\r"),
                '\t' => try self.writeAll("\\t"),
                0...8, 11, 12, 14...31 => {
                    // Control characters: output as \uXXXX (excluding \n, \r, \t)
                    try self.printFmt("\\u{x:0>4}", .{c});
                },
                else => try self.writeByte(c),
            }
        }
        try self.writeByte('"');
    }

    const MatchSpan = struct {
        start: usize,
        end: usize,
    };

    /// Find all occurrences of pattern in line and return (start, end) pairs.
    /// This allocates a temporary list; caller must free it.
    fn findMatchPositions(
        line: []const u8,
        pattern: []const u8,
    ) !std.ArrayList(MatchSpan) {
        var positions: std.ArrayList(MatchSpan) = .{};

        if (pattern.len == 0) return positions;

        var pos: usize = 0;
        while (pos <= line.len) {
            if (pos + pattern.len <= line.len) {
                if (std.mem.eql(u8, line[pos..][0..pattern.len], pattern)) {
                    try positions.append(std.heap.c_allocator, .{
                        .start = pos,
                        .end = pos + pattern.len,
                    });
                    pos += pattern.len;
                } else {
                    pos += 1;
                }
            } else {
                break;
            }
        }

        return positions;
    }

    /// Print a matching line as a JSON object.
    /// Format: {"path":"...", "line_number":N, "line_text":"...", "match_positions":[{start,end},...]}
    pub fn printMatch(
        self: *JsonPrinter,
        file_path: []const u8,
        line_num: u64,
        line: []const u8,
        pattern: []const u8,
        case_sensitive: bool,
    ) !void {
        _ = case_sensitive; // TODO: support case-insensitive match position finding

        var positions = try findMatchPositions(line, pattern);
        defer if (positions.capacity > 0) positions.deinit(std.heap.c_allocator);

        try self.writeAll("{");

        // path
        try self.writeAll("\"path\":");
        try self.writeJsonString(file_path);
        try self.writeAll(",");

        // line_number
        try self.printFmt("\"line_number\":{d}", .{line_num});
        try self.writeAll(",");

        // line_text
        try self.writeAll("\"line_text\":");
        try self.writeJsonString(line);
        try self.writeAll(",");

        // match_positions array
        try self.writeAll("\"match_positions\":[");
        for (positions.items, 0..) |span, i| {
            try self.printFmt("{{\"start\":{d},\"end\":{d}}}", .{ span.start, span.end });
            if (i < positions.items.len - 1) {
                try self.writeAll(",");
            }
        }
        try self.writeAll("]");

        try self.writeAll("}\n");
    }

    /// Print a context (non-matching) line as a JSON object.
    /// Format: {"path":"...", "line_number":N, "line_text":"...", "context":true}
    pub fn printContext(
        self: *JsonPrinter,
        file_path: []const u8,
        line_num: u64,
        line: []const u8,
    ) !void {
        try self.writeAll("{");

        try self.writeAll("\"path\":");
        try self.writeJsonString(file_path);
        try self.writeAll(",");

        try self.printFmt("\"line_number\":{d}", .{line_num});
        try self.writeAll(",");

        try self.writeAll("\"line_text\":");
        try self.writeJsonString(line);
        try self.writeAll(",");

        try self.writeAll("\"context\":true");

        try self.writeAll("}\n");
    }

    /// Print a separator (not applicable to JSON output, no-op).
    pub fn printSeparator(self: *JsonPrinter) !void {
        _ = self;
        // JSON Lines format doesn't need separators; just write consecutive objects
    }

    /// Print file path (for --files-with-matches / -l mode).
    /// Format: {"path":"..."}
    pub fn printFilePath(self: *JsonPrinter, path: []const u8) !void {
        try self.writeAll("{\"path\":");
        try self.writeJsonString(path);
        try self.writeAll("}\n");
    }

    /// Print match count (for --count / -c mode).
    /// Format: {"path":"...", "count":N}
    pub fn printCount(self: *JsonPrinter, path: []const u8, count: u64) !void {
        try self.writeAll("{");

        try self.writeAll("\"path\":");
        try self.writeJsonString(path);
        try self.writeAll(",");

        try self.printFmt("\"count\":{d}", .{count});

        try self.writeAll("}\n");
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "JsonPrinter escaping double quotes" {
    var output = buffer.OutputBuffer.init();
    defer output.deinit(std.testing.allocator);

    var buf_writer = buffer.BufferWriter.init(&output, std.testing.allocator);
    var printer = JsonPrinter.initBuffered(&buf_writer);

    try printer.printMatch("test.txt", 1, "hello \"world\"", "world", true);

    const result = output.slice();
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "\\\""));
}

test "JsonPrinter escaping backslash" {
    var output = buffer.OutputBuffer.init();
    defer output.deinit(std.testing.allocator);

    var buf_writer = buffer.BufferWriter.init(&output, std.testing.allocator);
    var printer = JsonPrinter.initBuffered(&buf_writer);

    try printer.printMatch("test.txt", 1, "path\\to\\file", "to", true);

    const result = output.slice();
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "\\\\"));
}

test "JsonPrinter escaping newline" {
    var output = buffer.OutputBuffer.init();
    defer output.deinit(std.testing.allocator);

    var buf_writer = buffer.BufferWriter.init(&output, std.testing.allocator);
    var printer = JsonPrinter.initBuffered(&buf_writer);

    // In real usage, lines don't have embedded newlines, but test the escaping anyway
    try printer.writeAll("{\"test\":");
    try printer.writeJsonString("line1\nline2");
    try printer.writeAll("}\n");

    const result = output.slice();
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "\\n"));
}

test "JsonPrinter match positions" {
    var output = buffer.OutputBuffer.init();
    defer output.deinit(std.testing.allocator);

    var buf_writer = buffer.BufferWriter.init(&output, std.testing.allocator);
    var printer = JsonPrinter.initBuffered(&buf_writer);

    try printer.printMatch("test.txt", 1, "hello world hello", "hello", true);

    const result = output.slice();
    // Should find two matches at positions 0 and 12
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "\"start\":0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "\"start\":12"));
}

test "JsonPrinter file path mode" {
    var output = buffer.OutputBuffer.init();
    defer output.deinit(std.testing.allocator);

    var buf_writer = buffer.BufferWriter.init(&output, std.testing.allocator);
    var printer = JsonPrinter.initBuffered(&buf_writer);

    try printer.printFilePath("src/main.zig");

    const result = output.slice();
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\"}\n", result);
}

test "JsonPrinter count mode" {
    var output = buffer.OutputBuffer.init();
    defer output.deinit(std.testing.allocator);

    var buf_writer = buffer.BufferWriter.init(&output, std.testing.allocator);
    var printer = JsonPrinter.initBuffered(&buf_writer);

    try printer.printCount("src/main.zig", 42);

    const result = output.slice();
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\",\"count\":42}\n", result);
}

test "JsonPrinter context line" {
    var output = buffer.OutputBuffer.init();
    defer output.deinit(std.testing.allocator);

    var buf_writer = buffer.BufferWriter.init(&output, std.testing.allocator);
    var printer = JsonPrinter.initBuffered(&buf_writer);

    try printer.printContext("test.txt", 5, "context line");

    const result = output.slice();
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "\"context\":true"));
}
