const std = @import("std");
const cli = @import("cli.zig");
const literal = @import("engine/literal.zig");
const regex_engine = @import("engine/regex.zig");
const lazy_dfa_mod = @import("engine/lazy_dfa.zig");
const simd_utils = @import("util/simd.zig");
const mmap = @import("io/mmap.zig");
const walker = @import("io/walker.zig");
const output_printer = @import("output/printer.zig");
const output_buffer = @import("output/buffer.zig");
const index_builder = @import("index/builder.zig");
const index_store = @import("index/store.zig");
const index_query = @import("index/query.zig");
const index_cache = @import("index/cache.zig");

/// High-level search orchestrator.
/// Coordinates file discovery, pattern matching, and result output.
/// Uses lock-free per-file buffering: each worker formats output into a
/// private buffer, then a single short lock flushes it to stdout.
pub const Searcher = struct {
    allocator: std.mem.Allocator,
    config: cli.Config,
    use_color: bool,

    /// Direct stdout writer — used for single-threaded path and final flush target.
    stdout_writer: *std.Io.Writer,

    /// Compiled regex (null if using literal search mode).
    compiled_regex: ?regex_engine.Regex = null,

    /// True if we should use SIMD literal path (pure literal or -F mode).
    use_literal_path: bool = true,

    total_matches: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Mutex only held during the brief stdout write of a completed file buffer.
    output_mutex: std.Thread.Mutex = .{},

    /// Create a Searcher. The caller must provide a pointer to a std.Io.Writer
    /// (typically backed by a buffered File.Writer) that outlives the Searcher.
    pub fn init(allocator: std.mem.Allocator, config: cli.Config, writer: *std.Io.Writer) !Searcher {
        const use_color = switch (config.color) {
            .always => true,
            .never => false,
            .auto => std.fs.File.stdout().supportsAnsiEscapeCodes(),
        };

        var compiled: ?regex_engine.Regex = null;
        var use_literal = true;

        if (config.regex_mode and !config.fixed_strings) {
            // Try to compile as regex
            var re = try regex_engine.Regex.compile(allocator, config.pattern);
            if (re.isPureLiteral()) {
                // Pattern has no metacharacters — use fast SIMD literal path
                re.deinit(allocator);
                use_literal = true;
            } else {
                compiled = re;
                use_literal = false;
            }
        }

        return Searcher{
            .allocator = allocator,
            .config = config,
            .use_color = use_color,
            .stdout_writer = writer,
            .compiled_regex = compiled,
            .use_literal_path = use_literal,
        };
    }

    pub fn deinit(self: *Searcher) void {
        if (self.compiled_regex != null) {
            self.compiled_regex.?.deinit(self.allocator);
        }
        self.stdout_writer.flush() catch {};
    }

    /// Build the trigram index for the given paths (--index-build mode).
    pub fn buildIndex(self: *Searcher) !void {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        const root = if (self.config.paths.len > 0) self.config.paths[0] else ".";

        stderr.print("igrep: building trigram index for {s}...\n", .{root}) catch {};

        var idx = try index_builder.buildIndex(self.allocator, self.config.paths, self.config.max_depth);
        defer idx.deinit();

        try index_store.writeIndex(&idx, root, self.allocator);

        const size = index_cache.indexSize(root, self.allocator) orelse 0;
        stderr.print("igrep: indexed {d} files, {d} trigrams, {d} KB on disk\n", .{
            idx.file_count,
            @as(u32, @intCast(idx.postings.count())),
            size / 1024,
        }) catch {};
    }

    /// Execute the search across all configured paths.
    /// Returns total number of matching lines.
    pub fn run(self: *Searcher) !u64 {
        // Indexed search path: use trigram index to find candidates first
        if (self.config.use_index) {
            return try self.runIndexed();
        }

        // Standard path: collect all files and search
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
            // Single-threaded: write directly to stdout, no buffers needed
            // Prefetch lookahead for next files
            var direct_printer = output_printer.Printer.init(
                self.stdout_writer,
                self.use_color,
                self.config.line_number,
            );
            var lookahead: [2]?mmap.MappedFile = .{ null, null };
            defer {
                if (lookahead[0]) |*f| f.close();
                if (lookahead[1]) |*f| f.close();
            }

            // Create one DFA for all files in single-threaded mode
            var shared_dfa: ?lazy_dfa_mod.LazyDfa = null;
            if (!self.use_literal_path) {
                if (self.compiled_regex) |*re| {
                    if (re.createDfa(self.allocator)) |dfa| {
                        shared_dfa = dfa;
                    } else |_| {}
                }
            }
            defer if (shared_dfa) |*dfa| dfa.deinit();

            for (file_list.items, 0..) |file_path, idx| {
                // Refill lookahead: open next files
                if (lookahead[0]) |*f| f.close();
                lookahead[0] = lookahead[1];
                lookahead[1] = null;

                if (idx + 1 < file_list.items.len) {
                    lookahead[0] = mmap.MappedFile.prefetchPath(file_list.items[idx + 1]) catch null;
                }
                if (idx + 2 < file_list.items.len) {
                    lookahead[1] = mmap.MappedFile.prefetchPath(file_list.items[idx + 2]) catch null;
                }

                if (shared_dfa) |*dfa| {
                    self.searchFile(file_path, &direct_printer, dfa);
                } else {
                    self.searchFile(file_path, &direct_printer, null);
                }
            }
            direct_printer.flush();
        }

        return self.total_matches.load(.monotonic);
    }

    /// Indexed search: load index, query candidates, search only those files.
    fn runIndexed(self: *Searcher) !u64 {
        const root = if (self.config.paths.len > 0) self.config.paths[0] else ".";
        const stderr = std.fs.File.stderr().deprecatedWriter();

        // Auto-build if index doesn't exist or is stale
        if (!index_store.indexExists(root, self.allocator) or
            index_cache.isStale(root, self.allocator))
        {
            stderr.print("igrep: index missing or stale, building...\n", .{}) catch {};
            try self.buildIndex();
        }

        // Load the index
        var idx = index_store.readIndex(root, self.allocator) catch |err| {
            stderr.print("igrep: failed to load index: {}, falling back to full scan\n", .{err}) catch {};
            return error.InvalidIndex;
        };
        defer idx.deinit();

        // Query for candidate files
        var result = try index_query.queryCandidates(&idx, self.config.pattern, self.allocator);
        defer result.deinit();

        stderr.print("igrep: index query: {d}/{d} candidate files\n", .{
            result.file_ids.len,
            idx.file_count,
        }) catch {};

        if (result.file_ids.len == 0) {
            return 0;
        }

        // Search only candidate files
        const use_parallel = result.file_ids.len > 4 and
            (self.config.threads == null or self.config.threads.? > 1);

        // Build file path list from candidate IDs
        var candidates: std.ArrayList([]const u8) = .{};
        defer if (candidates.capacity > 0) candidates.deinit(self.allocator);

        for (result.file_ids) |file_id| {
            if (file_id < idx.file_count) {
                try candidates.append(self.allocator, idx.file_paths[file_id]);
            }
        }

        if (use_parallel) {
            try self.runParallel(candidates.items);
        } else {
            var direct_printer = output_printer.Printer.init(
                self.stdout_writer,
                self.use_color,
                self.config.line_number,
            );

            // Create one DFA for all files in single-threaded mode
            var shared_dfa: ?lazy_dfa_mod.LazyDfa = null;
            if (!self.use_literal_path) {
                if (self.compiled_regex) |*re| {
                    if (re.createDfa(self.allocator)) |dfa| {
                        shared_dfa = dfa;
                    } else |_| {}
                }
            }
            defer if (shared_dfa) |*dfa| dfa.deinit();

            for (candidates.items) |file_path| {
                if (shared_dfa) |*dfa| {
                    self.searchFile(file_path, &direct_printer, dfa);
                } else {
                    self.searchFile(file_path, &direct_printer, null);
                }
            }
            direct_printer.flush();
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
    /// Each worker gets its own OutputBuffer — no lock during search/format.
    /// Note: Due to thread pool architecture (per-file spawning), each file still
    /// gets its own DFA. For true per-worker DFA reuse, the thread pool would need
    /// restructuring. The LUT optimization (#1) provides the main perf gains here.
    fn workerSearchFile(self: *Searcher, file_path: []const u8, wg: *std.Thread.WaitGroup) void {
        defer wg.finish();

        // Thread-local output buffer with 4KB initial capacity — avoids early reallocs
        var out_buf = output_buffer.OutputBuffer.initWithCapacity(self.allocator, 4096) catch output_buffer.OutputBuffer.init();
        defer out_buf.deinit(self.allocator);

        var buf_writer = output_buffer.BufferWriter.init(&out_buf, self.allocator);
        var printer = output_printer.Printer.initBuffered(
            &buf_writer,
            self.use_color,
            self.config.line_number,
        );

        // Pass null for optional_dfa; each worker gets per-file DFAs
        self.searchFile(file_path, &printer, null);

        // Only take the lock to flush the completed buffer to stdout
        if (!out_buf.isEmpty()) {
            self.output_mutex.lock();
            defer self.output_mutex.unlock();
            self.stdout_writer.writeAll(out_buf.slice()) catch {};
        }
    }

    /// Search a single file and write results to the provided printer.
    /// This function is lock-free — the printer writes to whatever backend
    /// it was initialized with (buffer for parallel, stdout for single-threaded).
    /// If dfa is provided, it will be reused across files (caller manages lifetime).
    /// If dfa is null, a per-file DFA is created and destroyed.
    fn searchFile(self: *Searcher, file_path: []const u8, printer: *output_printer.Printer, optional_dfa: ?*lazy_dfa_mod.LazyDfa) void {
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

        // Initialize per-file lazy DFA for cached regex matching.
        // The DFA persists across all lines in this file, so repeated state
        // configurations (very common in text) hit the cache instead of
        // re-simulating the NFA. This is the main regex performance win.
        var file_dfa: ?lazy_dfa_mod.LazyDfa = null;
        var owns_dfa = false; // Track if we allocated the DFA
        defer {
            if (owns_dfa and file_dfa != null) {
                file_dfa.?.deinit();
            }
        }

        if (optional_dfa != null) {
            // Reuse the provided DFA (caller manages lifetime)
            file_dfa = optional_dfa.?.*;
        } else if (!self.use_literal_path) {
            if (self.compiled_regex) |*re| {
                if (re.createDfa(self.allocator)) |dfa| {
                    file_dfa = dfa;
                    owns_dfa = true;
                } else |_| {
                    file_dfa = null;
                }
            }
        }

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

        // SIMD-accelerated line iteration: scan 16 bytes at a time for '\n'
        while (line_start < contents.len) {
            const nl_pos = simd_utils.findNextByte(contents, '\n', line_start);
            const line_end = nl_pos orelse contents.len;
            const line = contents[line_start..line_end];

                const matched = if (self.use_literal_path)
                    // Fast SIMD literal path
                    (if (self.config.case_sensitive)
                        literal.contains(line, pattern)
                    else
                        literal.containsCaseInsensitive(line, pattern))
                else
                    // Regex path: use lazy DFA if available, fall back to NFA
                    (if (self.compiled_regex) |*re|
                        (if (file_dfa) |*dfa|
                            (re.isMatchDfa(line, dfa) catch re.isMatch(line) catch false)
                        else
                            (re.isMatch(line) catch false))
                    else
                        false);

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
                                printer.printSeparator() catch {};
                            }

                            var ctx_i = start_idx;
                            while (ctx_i < current_idx) : (ctx_i += 1) {
                                if (ctx_i + 1 > last_printed_line) {
                                    const ctx_line = lines_buf.items[ctx_i];
                                    printer.printContext(
                                        file_path,
                                        ctx_i + 1,
                                        contents[ctx_line.start..ctx_line.end],
                                    ) catch {};
                                    last_printed_line = ctx_i + 1;
                                }
                            }
                        }

                        printer.printMatch(
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
                                    printer.printContext(
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

                line_start = line_end + 1;
                line_num += 1;
            } // end while

        if (self.config.files_only and file_matches > 0) {
            printer.printFilePath(file_path) catch {};
        }

        if (self.config.count_only and file_matches > 0) {
            printer.printCount(file_path, file_matches) catch {};
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
