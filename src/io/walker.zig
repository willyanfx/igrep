const std = @import("std");
const gitignore = @import("gitignore.zig");

/// Recursive directory walker that yields file paths.
/// Respects .gitignore patterns and skips hidden/binary directories.
pub const DirWalker = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    max_depth: ?u32,
    stack: std.ArrayList(StackEntry) = .{},
    ignore_rules: gitignore.GitIgnore,

    const StackEntry = struct {
        iter: std.fs.Dir.Iterator,
        dir: std.fs.Dir,
        depth: u32,
        prefix: []const u8,
    };

    /// Well-known directories that should always be skipped.
    const skip_dirs = [_][]const u8{
        ".git",
        ".hg",
        ".svn",
        "node_modules",
        ".zig-cache",
        "zig-out",
        "target",
        "__pycache__",
        ".mypy_cache",
        ".tox",
        ".venv",
        "vendor",
        ".DS_Store",
        "build",
        "dist",
    };

    pub fn init(allocator: std.mem.Allocator, root: []const u8, max_depth: ?u32) DirWalker {
        // Strip trailing slashes to avoid double-slash in output paths
        var clean_root = root;
        while (clean_root.len > 1 and clean_root[clean_root.len - 1] == '/') {
            clean_root = clean_root[0 .. clean_root.len - 1];
        }
        return DirWalker{
            .allocator = allocator,
            .root_path = clean_root,
            .max_depth = max_depth,
            .ignore_rules = gitignore.GitIgnore.init(allocator),
        };
    }

    pub fn deinit(self: *DirWalker) void {
        for (self.stack.items) |*entry| {
            entry.dir.close();
            self.allocator.free(entry.prefix);
        }
        if (self.stack.capacity > 0) self.stack.deinit(self.allocator);
        self.ignore_rules.deinit();
    }

    /// Get the next file path, or null when traversal is complete.
    /// Caller owns the returned string and must free it.
    pub fn next(self: *DirWalker) !?[]const u8 {
        // Lazy initialization: push root directory on first call
        if (self.stack.items.len == 0 and self.stack.capacity == 0) {
            try self.pushDir(self.root_path, 0, "");
            self.ignore_rules.loadFromDir(self.root_path) catch {};
        }

        while (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];

            if (top.iter.next() catch null) |entry| {
                const name = entry.name;

                const full_path = if (top.prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ top.prefix, name })
                else
                    try self.allocator.dupe(u8, name);

                if (entry.kind == .directory) {
                    if (shouldSkipDir(name)) {
                        self.allocator.free(full_path);
                        continue;
                    }

                    if (self.max_depth) |max| {
                        if (top.depth + 1 > max) {
                            self.allocator.free(full_path);
                            continue;
                        }
                    }

                    const dir_path_with_slash = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}/",
                        .{full_path},
                    );
                    defer self.allocator.free(dir_path_with_slash);

                    if (self.ignore_rules.isIgnored(dir_path_with_slash)) {
                        self.allocator.free(full_path);
                        continue;
                    }

                    const depth = top.depth + 1;
                    const abs_path = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}/{s}",
                        .{ self.root_path, full_path },
                    );
                    defer self.allocator.free(abs_path);
                    self.pushDir(abs_path, depth, full_path) catch {
                        self.allocator.free(full_path);
                        continue;
                    };
                    // Load nested .gitignore rules from the new directory
                    self.ignore_rules.loadFromDir(abs_path) catch {};
                    // full_path content was duped inside pushDir, free our copy
                    self.allocator.free(full_path);
                    continue;
                }

                if (entry.kind == .file) {
                    if (self.ignore_rules.isIgnored(full_path)) {
                        self.allocator.free(full_path);
                        continue;
                    }

                    const result = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}/{s}",
                        .{ self.root_path, full_path },
                    );
                    self.allocator.free(full_path);
                    return result;
                }

                self.allocator.free(full_path);
                continue;
            } else {
                if (self.stack.pop()) |entry| {
                    var dir_copy = entry.dir;
                    dir_copy.close();
                    self.allocator.free(entry.prefix);
                }
            }
        }

        return null;
    }

    fn pushDir(self: *DirWalker, path: []const u8, depth: u32, prefix: []const u8) !void {
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        errdefer dir.close();

        const owned_prefix = try self.allocator.dupe(u8, prefix);
        errdefer self.allocator.free(owned_prefix);

        try self.stack.append(self.allocator, .{
            .iter = dir.iterate(),
            .dir = dir,
            .depth = depth,
            .prefix = owned_prefix,
        });
    }

    fn shouldSkipDir(name: []const u8) bool {
        if (name.len > 0 and name[0] == '.') return true;

        for (skip_dirs) |skip| {
            if (std.mem.eql(u8, name, skip)) return true;
        }
        return false;
    }
};

test "DirWalker basic smoke test" {
    var w = DirWalker.init(std.testing.allocator, "/tmp", null);
    defer w.deinit();
}
