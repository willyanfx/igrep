const std = @import("std");
const cli = @import("cli.zig");
const literal = @import("engine/literal.zig");
const regex_engine = @import("engine/regex.zig");
const lazy_dfa_mod = @import("engine/lazy_dfa.zig");
const prefilter_mod = @import("engine/prefilter.zig");
const aho_corasick = @import("engine/aho_corasick.zig");
const simd_utils = @import("util/simd.zig");
const mmap = @import("io/mmap.zig");
const reader = @import("io/reader.zig");
const walker = @import("io/walker.zig");
const output_printer = @import("output/printer.zig");
const output_buffer = @import("output/buffer.zig");
const index_builder = @import("index/builder.zig");
const index_store = @import("index/store.zig");
const index_query = @import("index/query.zig");
const index_cache = @import("index/cache.zig");
const query_decompose = @import("index/query_decompose.zig");

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

    /// Owned lowercased pattern for case-insensitive regex compilation.
    /// The compiled regex references this slice, so it must outlive the regex.
    ci_pattern_buf: ?[]u8 = null,

    /// Aho-Corasick automaton for alternation-literal patterns (e.g. "error|warn|fatal").
    /// Built once during init, used for O(n) multi-pattern matching in searchFile.
    ac_automaton: ?aho_corasick.AhoCorasick = null,

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
        var ci_pat: ?[]u8 = null;

        if (config.regex_mode and !config.fixed_strings) {
            // For case-insensitive regex, compile from a lowercased pattern.
            // At match time we also lowercase the input text, so the NFA
            // transitions (built from lowercase chars) match correctly.
            const compile_pat = if (!config.case_sensitive) blk: {
                ci_pat = try allocator.alloc(u8, config.pattern.len);
                for (config.pattern, 0..) |c, i| {
                    ci_pat.?[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                }
                break :blk @as([]const u8, ci_pat.?);
            } else config.pattern;

            // Try to compile as regex
            var re = try regex_engine.Regex.compile(allocator, compile_pat);
            if (re.isPureLiteral()) {
                // Pattern has no metacharacters — use fast SIMD literal path
                // (literal path handles case-insensitivity directly)
                re.deinit(allocator);
                if (ci_pat) |p| {
                    allocator.free(p);
                    ci_pat = null;
                }
                use_literal = true;
            } else {
                compiled = re;
                use_literal = false;
            }
        }

        // Build Aho-Corasick automaton for alternation-literal patterns
        var ac: ?aho_corasick.AhoCorasick = null;
        if (compiled != null) {
            if (compiled.?.alternation_literals) |lits| {
                ac = aho_corasick.AhoCorasick.build(allocator, lits) catch null;
            }
        }

        return Searcher{
            .allocator = allocator,
            .config = config,
            .use_color = use_color,
            .stdout_writer = writer,
            .compiled_regex = compiled,
            .use_literal_path = use_literal,
            .ci_pattern_buf = ci_pat,
            .ac_automaton = ac,
        };
    }

    pub fn deinit(self: *Searcher) void {
        if (self.ac_automaton) |*ac| {
            ac.deinit();
        }
        if (self.compiled_regex != null) {
            self.compiled_regex.?.deinit(self.allocator);
        }
        if (self.ci_pattern_buf) |buf| {
            self.allocator.free(buf);
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

    /// Query the index for candidate files. For regex patterns, decomposes
    /// the regex AST to extract literal fragments for trigram-based filtering.
    /// Falls back to raw pattern trigrams for literal/fixed-string searches.
    fn queryIndexCandidates(self: *Searcher, idx: *const index_builder.TrigramIndex) !index_query.QueryResult {
        // Case-insensitive search: the trigram index is case-sensitive, so we
        // must return all files as candidates to avoid missing matches.
        if (!self.config.case_sensitive) {
            return index_query.queryCandidates(idx, "", self.allocator);
        }

        if (!self.use_literal_path and self.config.regex_mode) {
            // Parse pattern into AST and decompose for index query
            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var parser = regex_engine.Parser.init(arena, self.config.pattern);
            const ast = parser.parse() catch {
                return index_query.queryCandidates(idx, self.config.pattern, self.allocator);
            };

            var plan = query_decompose.decompose(ast, self.allocator) catch {
                return index_query.queryCandidates(idx, self.config.pattern, self.allocator);
            };
            defer plan.deinit(self.allocator);

            return index_query.queryCandidatesFromPlan(idx, &plan, self.allocator);
        }
        // Literal mode or fixed-string — use raw pattern trigrams
        return index_query.queryCandidates(idx, self.config.pattern, self.allocator);
    }

    /// Execute the search across all configured paths.
    /// Returns total number of matching lines.
    pub fn run(self: *Searcher) !u64 {
        // Indexed search path: use trigram index to find candidates first.
        // Index requires a directory root; fall through to standard search
        // when the root path is a single file.
        if (self.config.use_index) {
            const root = if (self.config.paths.len > 0) self.config.paths[0] else ".";
            const is_dir = blk: {
                const stat = std.fs.cwd().statFile(root) catch break :blk false;
                break :blk stat.kind == .directory;
            };
            if (is_dir) {
                return try self.runIndexed();
            }
            // Non-directory root: fall through to standard search
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

            // Reusable read buffer for small files (avoids per-file allocation)
            var read_buf: [256 * 1024]u8 = undefined;

            for (file_list.items) |file_path| {
                if (shared_dfa) |*dfa| {
                    self.searchFile(file_path, &direct_printer, dfa, &read_buf);
                } else {
                    self.searchFile(file_path, &direct_printer, null, &read_buf);
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

        // Query for candidate files.
        // For regex mode, decompose the regex AST to extract literal fragments
        // and query their trigrams. Falls back to raw pattern trigrams for literals.
        var result = try self.queryIndexCandidates(&idx);
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

            // Reusable read buffer for small files
            var read_buf: [256 * 1024]u8 = undefined;

            for (candidates.items) |file_path| {
                if (shared_dfa) |*dfa| {
                    self.searchFile(file_path, &direct_printer, dfa, &read_buf);
                } else {
                    self.searchFile(file_path, &direct_printer, null, &read_buf);
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

    /// Run search across files using a thread pool with chunk-based spawning.
    /// Each worker thread processes a chunk of files and reuses a single DFA
    /// across all files in its chunk, eliminating per-file DFA alloc/dealloc.
    fn runParallel(self: *Searcher, files: []const []const u8) !void {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const thread_count: u32 = self.config.threads orelse @intCast(@min(
            files.len,
            cpu_count,
        ));

        var pool: std.Thread.Pool = undefined;
        try pool.init(.{
            .allocator = self.allocator,
            .n_jobs = thread_count,
        });
        defer pool.deinit();

        var wg = std.Thread.WaitGroup{};

        // Divide files into chunks — one chunk per worker thread.
        // Each chunk task creates one DFA and reuses it across all its files.
        const chunk_size = files.len / thread_count;
        const remainder = files.len % thread_count;

        var offset: usize = 0;
        for (0..thread_count) |i| {
            // Distribute remainder across first `remainder` chunks
            const this_chunk = chunk_size + @as(usize, if (i < remainder) 1 else 0);
            if (this_chunk == 0) break;
            const chunk = files[offset..][0..this_chunk];
            offset += this_chunk;

            wg.start();
            pool.spawn(workerSearchChunk, .{ self, chunk, &wg }) catch {
                wg.finish();
                continue;
            };
        }

        wg.wait();
    }

    /// Worker function that processes a chunk of files on a single thread.
    /// Creates one DFA and reuses it across all files in the chunk,
    /// and uses one output buffer for the entire chunk.
    fn workerSearchChunk(self: *Searcher, chunk: []const []const u8, wg: *std.Thread.WaitGroup) void {
        defer wg.finish();

        // One DFA for the entire chunk — reused across all files
        var shared_dfa: ?lazy_dfa_mod.LazyDfa = null;
        if (!self.use_literal_path) {
            if (self.compiled_regex) |*re| {
                if (re.createDfa(self.allocator)) |dfa| {
                    shared_dfa = dfa;
                } else |_| {}
            }
        }
        defer if (shared_dfa) |*dfa| dfa.deinit();

        // Thread-local output buffer with 4KB initial capacity
        var out_buf = output_buffer.OutputBuffer.initWithCapacity(self.allocator, 4096) catch output_buffer.OutputBuffer.init();
        defer out_buf.deinit(self.allocator);

        var buf_writer = output_buffer.BufferWriter.init(&out_buf, self.allocator);
        var printer = output_printer.Printer.initBuffered(
            &buf_writer,
            self.use_color,
            self.config.line_number,
        );

        // Per-worker reusable read buffer for small files (avoids per-file allocation)
        var read_buf: [256 * 1024]u8 = undefined;

        for (chunk) |file_path| {
            if (shared_dfa) |*dfa| {
                self.searchFile(file_path, &printer, dfa, &read_buf);
            } else {
                self.searchFile(file_path, &printer, null, &read_buf);
            }

            // Flush per-file to keep memory bounded and preserve per-file output grouping
            if (!out_buf.isEmpty()) {
                self.output_mutex.lock();
                defer self.output_mutex.unlock();
                self.stdout_writer.writeAll(out_buf.slice()) catch {};
            }
            out_buf.reset();
        }
    }

    /// Search a single file and write results to the provided printer.
    /// This function is lock-free — the printer writes to whatever backend
    /// it was initialized with (buffer for parallel, stdout for single-threaded).
    /// If dfa is provided, it will be reused across files (caller manages lifetime).
    /// If dfa is null, a per-file DFA is created and destroyed.
    /// If read_buf is provided, small files reuse it to avoid allocation.
    fn searchFile(self: *Searcher, file_path: []const u8, printer: *output_printer.Printer, optional_dfa: ?*lazy_dfa_mod.LazyDfa, read_buf: ?[]u8) void {
        var fc = reader.FileContents.open(file_path, self.allocator, read_buf) catch |err| {
            switch (err) {
                error.IsDir => return,
                else => {
                    const stderr = std.fs.File.stderr().deprecatedWriter();
                    stderr.print("igrep: {s}: {}\n", .{ file_path, err }) catch {};
                    return;
                },
            }
        };
        defer fc.close(self.allocator);

        const contents = fc.data();
        if (contents.len == 0) return;

        // Quick binary file detection: check first 512 bytes for null bytes
        if (isBinary(contents)) return;

        // Case-insensitive regex: lowercase entire file contents once.
        // Positions map 1:1 (same length), so line boundaries transfer directly.
        // We match against lowered text but display the original.
        const ci_regex = !self.config.case_sensitive and !self.use_literal_path;
        var lower_contents: ?[]u8 = null;
        defer if (lower_contents) |lc| self.allocator.free(lc);

        const match_contents: []const u8 = if (ci_regex) blk: {
            lower_contents = self.allocator.alloc(u8, contents.len) catch null;
            if (lower_contents) |lc| {
                simd_utils.toLowerBuf(contents, lc);
                break :blk lc;
            }
            break :blk contents; // allocation failed, fall back to original
        } else contents;

        // Initialize per-file lazy DFA for cached regex matching.
        // The DFA persists across all lines in this file, so repeated state
        // configurations (very common in text) hit the cache instead of
        // re-simulating the NFA. This is the main regex performance win.
        //
        // Use a pointer to avoid value-copying the DFA struct (which would
        // break cross-file caching and leak internal allocations).
        var owned_dfa: lazy_dfa_mod.LazyDfa = undefined;
        var file_dfa: ?*lazy_dfa_mod.LazyDfa = null;
        var owns_dfa = false;
        defer if (owns_dfa) owned_dfa.deinit();

        if (optional_dfa) |dfa_ptr| {
            // Reuse the provided DFA directly (caller manages lifetime)
            file_dfa = dfa_ptr;
        } else if (!self.use_literal_path) {
            if (self.compiled_regex) |*re| {
                if (re.createDfa(self.allocator)) |dfa| {
                    owned_dfa = dfa;
                    owns_dfa = true;
                    file_dfa = &owned_dfa;
                } else |_| {}
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

        // Cache alternation literals for the fast multi-literal path.
        const alt_literals = if (!self.use_literal_path and !self.config.invert_match and self.compiled_regex != null)
            self.compiled_regex.?.alternation_literals
        else
            null;

        // Cache the required literal for the single-literal prefilter path.
        const req_literal = if (!self.use_literal_path and !self.config.invert_match and
            self.compiled_regex != null and alt_literals == null)
            self.compiled_regex.?.required_literal
        else
            null;

        // Fast path for pure alternation-of-literals patterns (e.g. "error|warn|fatal").
        // Uses whole-file SIMD literal scan: find earliest occurrence of any literal,
        // extract line, report match without DFA confirmation.
        if (alt_literals) |lits| {
            var scan_pos: usize = 0;
            var last_checked_line_start: usize = std.math.maxInt(usize);
            var running_line_count_pos: usize = 0;
            var running_line_num: u64 = 1;

            while (scan_pos < match_contents.len) {
                // Find earliest occurrence of any alternation literal via SIMD
                var best_pos: ?usize = null;
                for (lits) |lit| {
                    if (literal.findFirst(match_contents[scan_pos..], lit)) |rel| {
                        const abs = scan_pos + rel;
                        if (best_pos == null or abs < best_pos.?) {
                            best_pos = abs;
                            // Can't do better than current position
                            if (abs == scan_pos) break;
                        }
                    }
                }
                if (best_pos == null) break;
                const pos = best_pos.?;

                // Find the line containing this occurrence
                var ls: usize = pos;
                while (ls > 0 and contents[ls - 1] != '\n') : (ls -= 1) {}
                const cand_line_start = ls;

                // Deduplicate: skip if we already checked this line
                if (cand_line_start == last_checked_line_start) {
                    scan_pos = pos + 1;
                    continue;
                }
                last_checked_line_start = cand_line_start;

                const cand_line_end = simd_utils.findNextByte(contents, '\n', pos) orelse contents.len;
                const cand_line = contents[cand_line_start..cand_line_end];

                // Count line number incrementally
                if (!self.config.count_only or self.config.line_number) {
                    var cp: usize = running_line_count_pos;
                    while (cp < cand_line_start) : (cp += 1) {
                        if (contents[cp] == '\n') running_line_num += 1;
                    }
                    running_line_count_pos = cand_line_start;
                }

                file_matches += 1;
                _ = self.total_matches.fetchAdd(1, .monotonic);

                if (!self.config.count_only and !self.config.files_only) {
                    printer.printMatch(
                        file_path,
                        running_line_num,
                        cand_line,
                        pattern,
                        self.config.case_sensitive,
                    ) catch {};
                }

                if (self.config.files_only) break;
                if (self.config.max_count) |max| {
                    if (file_matches >= max) break;
                }

                scan_pos = cand_line_end + 1;
            }
        } else if (req_literal) |req_lit| {
            // Whole-file prefilter for regex patterns with a required literal.
            // Instead of checking every line, scan the whole file buffer for the
            // required literal, then only extract + DFA-check lines containing it.
            const re = &self.compiled_regex.?;
            var scan_pos: usize = 0;
            var last_checked_line_start: usize = std.math.maxInt(usize);
            var running_line_count_pos: usize = 0;
            var running_line_num: u64 = 1;

            while (literal.findFirst(match_contents[scan_pos..], req_lit)) |rel_pos| {
                const lit_pos = scan_pos + rel_pos;

                var ls: usize = lit_pos;
                while (ls > 0 and contents[ls - 1] != '\n') : (ls -= 1) {}
                const cand_line_start = ls;

                if (cand_line_start == last_checked_line_start) {
                    scan_pos = lit_pos + 1;
                    continue;
                }
                last_checked_line_start = cand_line_start;

                const cand_line_end = simd_utils.findNextByte(contents, '\n', lit_pos) orelse contents.len;
                const cand_line = contents[cand_line_start..cand_line_end];
                const cand_match_line = match_contents[cand_line_start..cand_line_end];

                if (!self.config.count_only or self.config.line_number) {
                    var cp: usize = running_line_count_pos;
                    while (cp < cand_line_start) : (cp += 1) {
                        if (contents[cp] == '\n') running_line_num += 1;
                    }
                    running_line_count_pos = cand_line_start;
                }

                const matched = if (file_dfa) |dfa|
                    (dfa.isMatch(cand_match_line) catch re.isMatch(cand_match_line) catch false)
                else
                    (re.isMatch(cand_match_line) catch false);

                if (matched) {
                    file_matches += 1;
                    _ = self.total_matches.fetchAdd(1, .monotonic);

                    if (!self.config.count_only and !self.config.files_only) {
                        printer.printMatch(
                            file_path,
                            running_line_num,
                            cand_line,
                            pattern,
                            self.config.case_sensitive,
                        ) catch {};
                    }

                    if (self.config.max_count) |max| {
                        if (file_matches >= max) break;
                    }
                }

                scan_pos = cand_line_end + 1;
            }
        } else if (self.use_literal_path and !self.config.invert_match and !has_context) {

        // Whole-file literal prefilter: scan the full buffer for the pattern with SIMD,
        // then derive line boundaries only for hits. For sparse patterns this skips
        // non-matching regions entirely. For dense patterns the overhead is minimal
        // since most lines hit anyway and we advance past each matched line.
        var scan_pos: usize = 0;
        var last_checked_line_start: usize = std.math.maxInt(usize);
        var running_line_count_pos: usize = 0;
        var running_line_num: u64 = 1;
        const case_sensitive = self.config.case_sensitive;

        while (true) {
            const rel_pos = if (case_sensitive)
                literal.findFirst(contents[scan_pos..], pattern)
            else
                literal.findFirstCaseInsensitive(contents[scan_pos..], pattern);

            const pos = (rel_pos orelse break) + scan_pos;

            // Find line boundaries
            const cand_line_end = simd_utils.findNextByte(contents, '\n', pos) orelse contents.len;

            // For dense matches, the pattern appears on consecutive lines, so
            // scan_pos advances past each line end. For sparse matches, we jump
            // directly to the next occurrence, skipping thousands of lines.
            var ls: usize = pos;
            while (ls > 0 and contents[ls - 1] != '\n') : (ls -= 1) {}
            const cand_line_start = ls;

            // Deduplicate: skip if we already checked this line
            if (cand_line_start == last_checked_line_start) {
                scan_pos = pos + 1;
                continue;
            }
            last_checked_line_start = cand_line_start;

            const cand_line = contents[cand_line_start..cand_line_end];

            // Count line number incrementally
            if (!self.config.count_only or self.config.line_number) {
                var cp: usize = running_line_count_pos;
                while (cp < cand_line_start) : (cp += 1) {
                    if (contents[cp] == '\n') running_line_num += 1;
                }
                running_line_count_pos = cand_line_start;
            }

            file_matches += 1;
            _ = self.total_matches.fetchAdd(1, .monotonic);

            if (!self.config.count_only and !self.config.files_only) {
                printer.printMatch(
                    file_path,
                    running_line_num,
                    cand_line,
                    pattern,
                    case_sensitive,
                ) catch {};
            }

            if (self.config.files_only) break;

            if (self.config.max_count) |max| {
                if (file_matches >= max) break;
            }

            scan_pos = cand_line_end + 1;
        }

        } else {

        // SIMD-accelerated line iteration: scan 16 bytes at a time for '\n'
        // Used for: regex without required-literal prefilter, invert match, context mode
        while (line_start < contents.len) {
            const nl_pos = simd_utils.findNextByte(contents, '\n', line_start);
            const line_end = nl_pos orelse contents.len;
            const line = contents[line_start..line_end];

                const matched = if (self.use_literal_path)
                    // Fast SIMD literal path (handles CI natively)
                    (if (self.config.case_sensitive)
                        literal.contains(line, pattern)
                    else
                        literal.containsCaseInsensitive(line, pattern))
                else blk: {
                    // Regex path: match against lowered content for CI
                    const match_line = match_contents[line_start..line_end];
                    break :blk if (self.compiled_regex) |*re|
                        (if (file_dfa) |dfa|
                            (re.isMatchDfa(match_line, dfa) catch re.isMatch(match_line) catch false)
                        else
                            (re.isMatch(match_line) catch false))
                    else
                        false;
                };

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

        } // end else (line-by-line fallback path)

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
