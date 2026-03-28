const std = @import("std");

/// Regex engine — placeholder for Milestone 2.
///
/// Strategy:
/// 1. Parse pattern into AST.
/// 2. Extract required literal fragments for pre-filtering.
/// 3. Compile to NFA (Thompson construction).
/// 4. Lazy DFA construction for hot paths.
///
/// For Milestone 1, we only support literal (fixed-string) search.
/// The regex engine will be implemented in Milestone 2.

pub const Regex = struct {
    pattern: []const u8,
    // TODO: NFA states, DFA cache, literal prefixes

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        _ = allocator;
        return .{ .pattern = pattern };
    }

    pub fn isMatch(self: *const Regex, text: []const u8) bool {
        // Milestone 1: fall back to literal search
        return std.mem.indexOf(u8, text, self.pattern) != null;
    }

    /// Extract required literal strings from the regex pattern.
    /// Used for pre-filtering files before running the full regex.
    pub fn extractLiterals(self: *const Regex) []const []const u8 {
        _ = self;
        // TODO: implement literal extraction from regex AST
        return &.{};
    }
};

test "regex placeholder compiles and matches" {
    var re = try Regex.compile(std.testing.allocator, "hello");
    try std.testing.expect(re.isMatch("say hello world"));
    try std.testing.expect(!re.isMatch("goodbye"));
}
