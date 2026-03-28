const std = @import("std");
const cli = @import("cli.zig");
const literal = @import("engine/literal.zig");
const mmap = @import("io/mmap.zig");
const walker = @import("io/walker.zig");
const output_printer = @import("output/printer.zig");

/// A single match result collected from worker threads.
const MatchResult = struct {
    file_path: []const u8,
    line_num: u64,
    line: []const u8,
    context_before: []const []const u8,
    context_after: []const []const u8,
};

/// Results for an entire file, collected by a worker thread.
const FileResult = struct {
    file_path: []const u8,
    matches: []MatchResult,
    match_count: u64,
    allocator: std.mem.Allocator,

    fn deinit(self: *FileResult) void {
        for (self.matches) |m| {
            for (m.context_before) |_| {}
            for (m.context_after) |_| {}
            self.allocator.free(m.context_before);
            self.allocator.free(m.context_after);
        }
        self.allocator.free(self.matches);
        self.allocator.free(self.file_path);
    }
};

/// High-level search orchestrator.
/// Coordinates file discovery, pattern matching, and result output.
/// Supports both single-threaded and parallel execution.
pub const Searcher = struct {
    allocator: std.mem.Allocator,
    config: cli.Config,
    result_printer: output_printer.Printer,
    total_matches: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Mutex for serializing output from multiple threads.
    output_mutex: std.Thread.Mutex = .{},

    /// Create a Searcher. The caller must provide a pointer to a std.Io.Writer
    /// (typically backed by a buffered File.Writer) that outlives the Searcher.
    pub fn init(allocator: std.mem.Allocator, config: cli.Config, writer: *std.Io.Writer) Searcher {
        const use_color = switch (config.color) {
            .always => true,
            .never => false,
            .auto => std.fs.File.stdout().supportsAnsiEscapeCodes(),
        };

        return Searcher{
            .allocator = allocator,
            .config = config,
            .result_printer = output_printer.Printer.init(
                writer,
                use_color,
                config.line_number,
            ),
        };
    }

    pub fn deinit(self: *Searcher) void {
        self.result_printer.flush();
    }

    /// Execute the search across all configured paths.
    /// Returns total number of matching lines.
    pub fn run(self: *Searcher) !u64 {
        // Collect all files to search
        var file_list: std.ArrayList([]const u8) = .{};
        defer {
            for (file_list.items) |p| self.allocator.free(p);
            if (file_list.capacity > 0) file_list.deinit(self.allocator);
        }

        for (self.config.paths) |path| {
            try self.collectFiles(path, &file_list);
        }

        const file_count = file_list.items.len;

        if (file_count == 0) {
            return 0;
        }

        // Decide: parallel or single-threaded
        const use_parallel = file_count > 4 and (self.config.threads == null or self.config.threads.? > 1);

        if (use_parallel) {
            try self.runParallel(file_list.items);
        } else {
            for (file_list.items) |file_path| {
                self.searchAndPrintFile(file_path);
            }
        }

        return self.total_matches.load(.monotonic);
    }

    /// Collect files from a path (file or directory) into the list.
    fn collectFiles(self: *Searcher, path: []const u8, list: *std.ArrayList([]const u8)) !void {
        const stat = std.fs.cwd().statFile(path) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("igrep: {s}: {}\n", .{ path, err }) catch {};
            return;
        };

        if (stat.kind == .directory) {
            var dir_walker = walker.DirWalker.init(self.allocator, path, self.config.max_depth);
            defer dir_walker.deinit();

            while (try dir_walker.next()) |file_path| {
                // Apply file type filter
                if (self.config.type_filter) |ext| {
                    if (!matchesTypeFilter(file_path, ext)) {
                        self.allocator.free(file_path);
                        continue;
                    }
                }
                try list.append(self.allocator, file_path);
            }
        } else {
            const owned = try self.allocator.dupe(u8, path);
            try list.append(self.allocator, owned);
        }
    }

    /// Run search across files using a thread pool.
    fn runParallel(self: *Searcher, files: []const []const u8) !void {
        const thread_count: u32 = self.config.threads orelse @intCast(@min(
            files.len,
            std.Thread.getCpuCount() catch 4,
        ));

        var pool: std.Thread.Pool = undefined;
        try pool.init(.{
            .allocator = self.allocator,
            .n_jobs = thread_count,
        });
        defer pool.deinit();

        var wg = std.Thread.WaitGroup{};

        for (files) |file_path| {
            wg.start();
            pool.spawn(workerSearchFile, .{ self, file_path, &wg }) catch {
                wg.finish();
                continue;
            };
        }

        wg.wait();
    }

    /// Worker function executed on thread pool threads.
    fn workerSearchFile(self: *Searcher, file_path: []const u8, wg: *std.Thread.WaitGroup) void {
        defer wg.finish();
        self.searchAndPrintFile(file_path);
    }

    /// Search a single file and print results (thread-safe via output_mutex).
    fn searchAndPrintFile(self: *Searcher, file_path: []const u8) void {
        var mapped = mmap.MappedFile.open(file_path) catch |err| {
            switch (err) {
                error.IsDir => return,
                else => {
                    const stderr = std.fs.File.stderr().deprecatedWriter();
                    stderr.print("igrep: {s}: {}\n", .{ file_path, err }) catch {};
                    return;
                },
            }
        };
        defer mapped.close();

        const contents = mapped.data();
        if (contents.len == 0) return;

        // Quick binary file detection: check first 512 bytes for null bytes
        if (isBinary(contents)) return;

        // Split contents into lines
        const pattern = self.config.pattern;
        const has_context = self.config.context_before > 0 or self.config.context_after > 0;

        // Build line index for context support
        var lines_buf: std.ArrayList(LineSpan) = .{};
        defer if (lines_buf.capacity > 0) lines_buf.deinit(self.allocator);

        if (has_context) {
            buildLineIndex(self.allocator, contents, &lines_buf) catch return;
        }

        var line_start: usize = 0;
        var line_num: u64 = 1;
        var file_matches: u64 = 0;
        var last_printed_line: u64 = 0;

        // Lock output for the duration of this file to keep results grouped
        self.output_mutex.lock();
        defer self.output_mutex.unlock();

        for (contents, 0..) |byte, i| {
            if (byte == '\n' or i == contents.len - 1) {
                const line_end = if (byte == '\n') i else i + 1;
                const line = contents[line_start..line_end];

                const matched = if (self.config.case_sensitive)
                    literal.contains(line, pattern)
                else
                    literal.containsCaseInsensitive(line, pattern);

                const should_report = if (self.config.invert_match) !matched else matched;

                if (should_report) {
                    file_matches += 1;
                    _ = self.total_matches.fetchAdd(1, .monotonic);

                    if (!self.config.count_only and !self.config.files_only) {
                        // Print context before
                        if (has_context and lines_buf.items.len > 0) {
                            const ctx_b = self.config.context_before;
                            const current_idx = line_num - 1;
                            const start_idx = if (current_idx >= ctx_b) current_idx - ctx_b else 0;

                            // Separator between non-contiguous context groups
                            if (last_printed_line > 0 and start_idx + 1 > last_printed_line + 1) {
                                self.result_printer.printSeparator() catch {};
                            }

                            var ctx_i = start_idx;
                            while (ctx_i < current_idx) : (ctx_i += 1) {
                                if (ctx_i + 1 > last_printed_line) {
                                    const ctx_line = lines_buf.items[ctx_i];
                                    self.result_printer.printContext(
                                        file_path,
                                        ctx_i + 1,
                                        contents[ctx_line.start..ctx_line.end],
                                    ) catch {};
                                    last_printed_line = ctx_i + 1;
                                }
                            }
                        }

                        self.result_printer.printMatch(
                            file_path,
                            line_num,
                            line,
                            pattern,
                            self.config.case_sensitive,
                        ) catch {};
                        last_printed_line = line_num;

                        // Print context after
                        if (has_context and lines_buf.items.len > 0) {
                            const ctx_a = self.config.context_after;
                            const current_idx = line_num - 1;
                            const end_idx = @min(current_idx + ctx_a + 1, lines_buf.items.len);

                            var ctx_i = current_idx + 1;
                            while (ctx_i < end_idx) : (ctx_i += 1) {
                                if (ctx_i + 1 > last_printed_line) {
                                    const ctx_line = lines_buf.items[ctx_i];
                                    self.result_printer.printContext(
                                        file_path,
                                        ctx_i + 1,
                                        contents[ctx_line.start..ctx_line.end],
                                    ) catch {};
                                    last_printed_line = ctx_i + 1;
                                }
                            }
                        }
                    }

                    if (self.config.max_count) |max| {
                        if (file_matches >= max) break;
                    }
                }

                line_start = i + 1;
                line_num += 1;
            }
        }

        if (self.config.files_only and file_matches > 0) {
            self.result_printer.printFilePath(file_path) catch {};
        }

        if (self.config.count_only and file_matches > 0) {
            self.result_printer.printCount(file_path, file_matches) catch {};
        }
    }

    const LineSpan = struct {
        start: usize,
        end: usize,
    };

    fn buildLineIndex(allocator: std.mem.Allocator, contents: []const u8, lines: *std.ArrayList(LineSpan)) !void {
        var line_start: usize = 0;
        for (contents, 0..) |byte, i| {
            if (byte == '\n') {
                try lines.append(allocator, .{ .start = line_start, .end = i });
                line_start = i + 1;
            }
        }
        // Last line (no trailing newline)
        if (line_start < contents.len) {
            try lines.append(allocator, .{ .start = line_start, .end = contents.len });
        }
    }

    fn isBinary(contents: []const u8) bool {
        const check_len = @min(contents.len, 512);
        for (contents[0..check_len]) |byte| {
            if (byte == 0) return true;
        }
        return false;
    }

    fn matchesTypeFilter(file_path: []const u8, ext_filter: []const u8) bool {
        const ext = std.fs.path.extension(file_path);
        if (ext.len == 0) return false;
        // ext includes the dot, ext_filter does not
        return std.mem.eql(u8, ext[1..], ext_filter);
    }
};

test "Searcher isBinary detects null bytes" {
    try std.testing.expect(Searcher.isBinary("hello\x00world"));
    try std.testing.expect(!Searcher.isBinary("hello world"));
}

test "Searcher matchesTypeFilter" {
    try std.testing.expect(Searcher.matchesTypeFilter("src/main.zig", "zig"));
    try std.testing.expect(!Searcher.matchesTypeFilter("src/main.zig", "rs"));
    try std.testing.expect(Searcher.matchesTypeFilter("test.py", "py"));
}
