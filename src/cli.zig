const std = @import("std");

/// Parsed command-line configuration for a search operation.
pub const Config = struct {
    pattern: []const u8,
    paths: []const []const u8,
    case_sensitive: bool = true,
    fixed_strings: bool = false,
    count_only: bool = false,
    files_only: bool = false,
    line_number: bool = true,
    color: ColorMode = .auto,
    context_before: u32 = 0,
    context_after: u32 = 0,
    max_depth: ?u32 = null,
    threads: ?u32 = null,
    use_index: bool = false,
    build_index: bool = false,
    json_output: bool = false,
    include_globs: []const []const u8 = &.{},
    exclude_globs: []const []const u8 = &.{},
    invert_match: bool = false,
    word_regexp: bool = false,
    max_count: ?u64 = null,
    type_filter: ?[]const u8 = null,
    /// When true, pattern is treated as a regex (default behavior).
    /// When false (via -F), pattern is treated as a fixed literal string.
    regex_mode: bool = true,

    pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
        if (self.paths.len > 0) {
            allocator.free(self.paths);
        }
    }
};

pub const ColorMode = enum {
    auto,
    always,
    never,
};

pub const ParseError = error{
    ShowHelp,
    ShowVersion,
    InvalidArgument,
    MissingPattern,
    OutOfMemory,
};

/// Parse command-line arguments into a Config struct.
pub fn parseArgs(allocator: std.mem.Allocator) ParseError!Config {
    var args = std.process.args();
    _ = args.skip(); // skip executable name

    var config = Config{
        .pattern = undefined,
        .paths = &.{},
    };

    var pattern_set = false;
    var paths: std.ArrayList([]const u8) = .{};
    errdefer {
        if (paths.capacity > 0) paths.deinit(allocator);
    }

    while (args.next()) |arg| {
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                return error.ShowHelp;
            } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
                return error.ShowVersion;
            } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
                config.case_sensitive = false;
            } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
                config.fixed_strings = true;
                config.regex_mode = false;
            } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--regexp")) {
                if (args.next()) |val| {
                    config.pattern = val;
                    pattern_set = true;
                    config.regex_mode = true;
                }
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
                config.count_only = true;
            } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches")) {
                config.files_only = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--line-number")) {
                config.line_number = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--invert-match")) {
                config.invert_match = true;
            } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--word-regexp")) {
                config.word_regexp = true;
            } else if (std.mem.eql(u8, arg, "--no-line-number")) {
                config.line_number = false;
            } else if (std.mem.eql(u8, arg, "--json")) {
                config.json_output = true;
            } else if (std.mem.eql(u8, arg, "--index")) {
                config.use_index = true;
            } else if (std.mem.eql(u8, arg, "--index-build")) {
                config.build_index = true;
            } else if (std.mem.eql(u8, arg, "--color") or std.mem.eql(u8, arg, "--colour")) {
                if (args.next()) |val| {
                    if (std.mem.eql(u8, val, "always")) {
                        config.color = .always;
                    } else if (std.mem.eql(u8, val, "never")) {
                        config.color = .never;
                    } else {
                        config.color = .auto;
                    }
                }
            } else if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--after-context")) {
                if (args.next()) |val| {
                    config.context_after = std.fmt.parseInt(u32, val, 10) catch 0;
                }
            } else if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--before-context")) {
                if (args.next()) |val| {
                    config.context_before = std.fmt.parseInt(u32, val, 10) catch 0;
                }
            } else if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--context")) {
                if (args.next()) |val| {
                    const ctx = std.fmt.parseInt(u32, val, 10) catch 0;
                    config.context_before = ctx;
                    config.context_after = ctx;
                }
            } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--threads")) {
                if (args.next()) |val| {
                    config.threads = std.fmt.parseInt(u32, val, 10) catch null;
                }
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--max-count")) {
                if (args.next()) |val| {
                    config.max_count = std.fmt.parseInt(u64, val, 10) catch null;
                }
            } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
                if (args.next()) |val| {
                    config.type_filter = val;
                }
            } else if (std.mem.eql(u8, arg, "--max-depth")) {
                if (args.next()) |val| {
                    config.max_depth = std.fmt.parseInt(u32, val, 10) catch null;
                }
            }
        } else {
            // Positional argument: first is pattern, rest are paths
            if (!pattern_set) {
                config.pattern = arg;
                pattern_set = true;
            } else {
                paths.append(allocator, arg) catch return error.OutOfMemory;
            }
        }
    }

    if (!pattern_set) {
        return error.MissingPattern;
    }

    if (paths.items.len == 0) {
        // Default to current directory
        paths.append(allocator, ".") catch return error.OutOfMemory;
    }

    config.paths = paths.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return config;
}

pub fn printUsage() void {
    const usage =
        \\Usage: igrep [OPTIONS] PATTERN [PATH ...]
        \\
        \\instantGrep — a blazing-fast code search tool
        \\
        \\ARGS:
        \\  PATTERN          The search pattern (regex by default)
        \\  PATH ...         Files or directories to search (default: .)
        \\
        \\OPTIONS:
        \\  -e, --regexp PATTERN     Use PATTERN as a regex (useful for patterns starting with -)
        \\  -i, --ignore-case        Case-insensitive search
        \\  -F, --fixed-strings      Treat pattern as a literal string (no regex)
        \\  -v, --invert-match       Select non-matching lines
        \\  -w, --word-regexp        Match whole words only
        \\  -c, --count              Only print match counts per file
        \\  -l, --files-with-matches Only print file paths with matches
        \\  -n, --line-number        Show line numbers (default: on)
        \\  --no-line-number         Suppress line numbers
        \\  -A, --after-context N    Show N lines after each match
        \\  -B, --before-context N   Show N lines before each match
        \\  -C, --context N          Show N lines before and after each match
        \\  -m, --max-count N        Stop after N matches per file
        \\  -t, --type EXT           Only search files with extension EXT
        \\  -j, --threads N          Number of worker threads
        \\  --max-depth N            Max directory recursion depth
        \\  --color [always|never|auto]  Control color output
        \\  --json                   Output results as JSON
        \\  --index                  Use trigram index for search (auto-builds if missing)
        \\  --index-build            Build/rebuild the trigram index without searching
        \\  -h, --help               Show this help
        \\  -V, --version            Show version
        \\
    ;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.writeAll(usage) catch {};
}

// ── Tests ────────────────────────────────────────────────────────────

test "parseArgs handles missing pattern" {
    // Smoke test — full CLI tests would use a test harness
    // that can inject arguments.
}
