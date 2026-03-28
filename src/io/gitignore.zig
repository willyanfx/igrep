const std = @import("std");

/// Minimal .gitignore pattern matcher.
/// Supports basic glob patterns used in .gitignore files.
pub const GitIgnore = struct {
    allocator: std.mem.Allocator,
    patterns: std.ArrayList(Pattern) = .{},

    const Pattern = struct {
        raw: []const u8,
        is_negation: bool,
        is_dir_only: bool,
        anchored: bool,
    };

    pub fn init(allocator: std.mem.Allocator) GitIgnore {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitIgnore) void {
        for (self.patterns.items) |pattern| {
            self.allocator.free(pattern.raw);
        }
        if (self.patterns.capacity > 0) self.patterns.deinit(self.allocator);
    }

    /// Load .gitignore rules from a directory.
    pub fn loadFromDir(self: *GitIgnore, dir_path: []const u8) !void {
        const gitignore_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/.gitignore",
            .{dir_path},
        );
        defer self.allocator.free(gitignore_path);

        const file = std.fs.cwd().openFile(gitignore_path, .{}) catch return;
        defer file.close();

        // Read entire file (gitignore files are always small)
        const contents = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return;
        defer self.allocator.free(contents);

        var iter = std.mem.splitScalar(u8, contents, '\n');
        while (iter.next()) |line| {
            self.addPattern(line) catch continue;
        }
    }

    fn addPattern(self: *GitIgnore, raw_line: []const u8) !void {
        var line = std.mem.trim(u8, raw_line, &[_]u8{ ' ', '\t', '\r' });

        if (line.len == 0 or line[0] == '#') return;

        var is_negation = false;
        if (line[0] == '!') {
            is_negation = true;
            line = line[1..];
        }

        var is_dir_only = false;
        if (line.len > 0 and line[line.len - 1] == '/') {
            is_dir_only = true;
            line = line[0 .. line.len - 1];
        }

        const anchored = std.mem.indexOf(u8, line, "/") != null;

        const owned = try self.allocator.dupe(u8, line);
        try self.patterns.append(self.allocator, .{
            .raw = owned,
            .is_negation = is_negation,
            .is_dir_only = is_dir_only,
            .anchored = anchored,
        });
    }

    /// Check if a path should be ignored based on loaded patterns.
    pub fn isIgnored(self: *const GitIgnore, path: []const u8) bool {
        var ignored = false;

        for (self.patterns.items) |pattern| {
            if (matchPattern(pattern.raw, path)) {
                ignored = !pattern.is_negation;
            }
        }

        return ignored;
    }

    fn matchPattern(pattern: []const u8, path: []const u8) bool {
        const basename = std.fs.path.basename(path);
        return globMatch(pattern, path) or globMatch(pattern, basename);
    }

    pub fn globMatch(pattern: []const u8, text: []const u8) bool {
        var pi: usize = 0;
        var ti: usize = 0;
        var star_pi: ?usize = null;
        var star_ti: usize = 0;

        while (ti < text.len) {
            if (pi < pattern.len and (pattern[pi] == text[ti] or pattern[pi] == '?')) {
                pi += 1;
                ti += 1;
            } else if (pi < pattern.len and pattern[pi] == '*') {
                star_pi = pi;
                star_ti = ti;
                pi += 1;
            } else if (star_pi) |sp| {
                pi = sp + 1;
                star_ti += 1;
                ti = star_ti;
            } else {
                return false;
            }
        }

        while (pi < pattern.len and pattern[pi] == '*') {
            pi += 1;
        }

        return pi == pattern.len;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "glob matching basics" {
    try std.testing.expect(GitIgnore.globMatch("*.zig", "main.zig"));
    try std.testing.expect(GitIgnore.globMatch("*.zig", "test.zig"));
    try std.testing.expect(!GitIgnore.globMatch("*.zig", "main.rs"));
    try std.testing.expect(GitIgnore.globMatch("test*", "test_file.txt"));
    try std.testing.expect(GitIgnore.globMatch("*", "anything"));
}

test "gitignore pattern matching" {
    var gi = GitIgnore.init(std.testing.allocator);
    defer gi.deinit();

    try gi.addPattern("*.o");
    try gi.addPattern("node_modules/");
    try gi.addPattern("!important.o");

    try std.testing.expect(gi.isIgnored("foo.o"));
    try std.testing.expect(!gi.isIgnored("foo.c"));
    try std.testing.expect(!gi.isIgnored("important.o"));
}
