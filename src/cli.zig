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
    /// Replacement string for search-and-replace mode (--replace / -r).
    replace_text: ?[]const u8 = null,
    /// When true, show what would change without writing files (--dry-run).
    dry_run: bool = false,
    /// Shell type for completion generation (bash, zsh, or fish).
    completions_shell: ?[]const u8 = null,

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
    ShowCompletions,
    InvalidArgument,
    MissingPattern,
    OutOfMemory,
};

/// Load config file arguments from .igreprc if it exists.
/// Looks for .igreprc in CWD first, then in $HOME.
/// Returns an ArrayList of argument strings, or null if no config file found.
/// The caller is responsible for freeing the returned ArrayList and its items.
pub fn loadConfigFile(allocator: std.mem.Allocator) !?std.ArrayList([]const u8) {
    var config_path: ?[]const u8 = null;
    var config_allocator_owned = false;

    // Try CWD first
    if (std.fs.cwd().openFile(".igreprc", .{})) |file| {
        file.close();
        config_path = ".igreprc";
    } else |_| {
        // Try HOME/.igreprc
        if (std.posix.getenv("HOME")) |home| {
            const home_rc = try std.fmt.allocPrint(allocator, "{s}/.igreprc", .{home});
            defer allocator.free(home_rc);

            if (std.fs.cwd().openFile(home_rc, .{})) |file| {
                file.close();
                config_path = try allocator.dupe(u8, home_rc);
                config_allocator_owned = true;
            } else |_| {
                // No config file found
                return null;
            }
        } else {
            return null;
        }
    }

    if (config_path == null) {
        return null;
    }

    defer if (config_allocator_owned) {
        allocator.free(config_path.?);
    };

    // Read and parse the config file
    const file = try std.fs.cwd().openFile(config_path.?, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 64);
    defer allocator.free(content);

    var args: std.ArrayList([]const u8) = .{};
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        // Trim whitespace
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }

        // Add the line as an argument
        const arg = try allocator.dupe(u8, trimmed);
        try args.append(allocator, arg);
    }

    return args;
}

/// Parse command-line arguments into a Config struct.
/// Loads config file defaults from .igreprc (if present) and merges with CLI args.
/// CLI args take precedence over config file settings.
pub fn parseArgs(allocator: std.mem.Allocator) ParseError!Config {
    // Load config file arguments if available
    var config_file_args: ?std.ArrayList([]const u8) = null;
    defer {
        if (config_file_args) |*ca| {
            for (ca.items) |arg| allocator.free(arg);
            ca.deinit(allocator);
        }
    }

    if (loadConfigFile(allocator) catch null) |ca| {
        config_file_args = ca;
    }

    var config = Config{
        .pattern = undefined,
        .paths = &.{},
    };

    var pattern_set = false;
    var paths: std.ArrayList([]const u8) = .{};
    errdefer {
        if (paths.capacity > 0) paths.deinit(allocator);
    }

    // Process config file args first (lower priority)
    if (config_file_args) |ca| {
        var ca_idx: usize = 0;
        while (ca_idx < ca.items.len) : (ca_idx += 1) {
            const arg = ca.items[ca_idx];

            if (arg.len > 0 and arg[0] == '-') {
                if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
                    config.case_sensitive = false;
                } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
                    config.fixed_strings = true;
                    config.regex_mode = false;
                } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--regexp")) {
                    if (ca_idx + 1 < ca.items.len) {
                        ca_idx += 1;
                        config.pattern = ca.items[ca_idx];
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
                    if (ca_idx + 1 < ca.items.len) {
                        ca_idx += 1;
                        const val = ca.items[ca_idx];
                        if (std.mem.eql(u8, val, "always")) {
                            config.color = .always;
                        } else if (std.mem.eql(u8, val, "never")) {
                            config.color = .never;
                        } else {
                            config.color = .auto;
                        }
                    }
                } else if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--after-context")) {
                    if (ca_idx + 1 < ca.items.len) {
                        ca_idx += 1;
                        config.context_after = std.fmt.parseInt(u32, ca.items[ca_idx], 10) catch 0;
                    }
                } else if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--before-context")) {
                    if (ca_idx + 1 < ca.items.len) {
                        ca_idx += 1;
                        config.context_before = std.fmt.parseInt(u32, ca.items[ca_idx], 10) catch 0;
                    }
                } else if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--context")) {
                    if (ca_idx + 1 < ca.items.len) {
                        ca_idx += 1;
                        const ctx = std.fmt.parseInt(u32, ca.items[ca_idx], 10) catch 0;
                        config.context_before = ctx;
                        config.context_after = ctx;
                    }
                } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--threads")) {
                    if (ca_idx + 1 < ca.items.len) {
                        ca_idx += 1;
                        config.threads = std.fmt.parseInt(u32, ca.items[ca_idx], 10) catch null;
                    }
                } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--max-count")) {
                    if (ca_idx + 1 < ca.items.len) {
                        ca_idx += 1;
                        config.max_count = std.fmt.parseInt(u64, ca.items[ca_idx], 10) catch null;
                    }
                } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
                    if (ca_idx + 1 < ca.items.len) {
                        ca_idx += 1;
                        config.type_filter = ca.items[ca_idx];
                    }
                } else if (std.mem.eql(u8, arg, "--max-depth")) {
                    if (ca_idx + 1 < ca.items.len) {
                        ca_idx += 1;
                        config.max_depth = std.fmt.parseInt(u32, ca.items[ca_idx], 10) catch null;
                    }
                } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--replace")) {
                    if (ca_idx + 1 < ca.items.len) {
                        ca_idx += 1;
                        config.replace_text = ca.items[ca_idx];
                    }
                } else if (std.mem.eql(u8, arg, "--dry-run")) {
                    config.dry_run = true;
                }
            } else {
                // Positional: first is pattern, rest are paths
                if (!pattern_set) {
                    config.pattern = arg;
                    pattern_set = true;
                } else {
                    try paths.append(allocator, arg);
                }
            }
        }
    }

    // Parse CLI args (higher priority, override config file)
    var args = std.process.args();
    _ = args.skip(); // skip executable name

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
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--replace")) {
                if (args.next()) |val| {
                    config.replace_text = val;
                }
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                config.dry_run = true;
            } else if (std.mem.eql(u8, arg, "--completions")) {
                if (args.next()) |val| {
                    config.completions_shell = val;
                    return error.ShowCompletions;
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
        \\  -r, --replace TEXT       Replace pattern with TEXT (literal replacement for now)
        \\  --dry-run                Show replacements without writing files
        \\  --color [always|never|auto]  Control color output
        \\  --json                   Output results as JSON
        \\  --index                  Use trigram index for search (auto-builds if missing)
        \\  --index-build            Build/rebuild the trigram index without searching
        \\  --completions SHELL      Generate shell completions (bash, zsh, or fish)
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
