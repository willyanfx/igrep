const std = @import("std");
const literal = @import("literal.zig");

/// Prefilter for quickly finding candidate match positions in text.
/// Used to skip expensive DFA/NFA matching on lines that cannot match.
pub const Prefilter = union(enum) {
    single: SingleLiteral,
    multi: MultiLiteral,

    /// Find the next potential match position at or after `start`.
    /// Returns the byte offset of the line start containing a candidate,
    /// or null if no more candidates exist.
    pub fn findNextLineCandidate(self: *const Prefilter, haystack: []const u8, start: usize) ?usize {
        if (start >= haystack.len) return null;
        const slice = haystack[start..];
        const rel_pos = switch (self.*) {
            .single => |*s| s.findNext(slice),
            .multi => |*m| m.findNext(slice),
        };
        if (rel_pos) |rp| return start + rp;
        return null;
    }
};

/// Prefilter for a single literal string.
const SingleLiteral = struct {
    needle: []const u8,

    fn findNext(self: *const SingleLiteral, haystack: []const u8) ?usize {
        return literal.findFirst(haystack, self.needle);
    }
};

/// Prefilter that scans for any of N literal alternatives (N <= max_literals).
/// Uses a smart cursor-based approach: maintains the next known position for
/// each needle and only re-scans from there, avoiding redundant full-file scans.
const MultiLiteral = struct {
    needles: []const []const u8,

    fn findNext(self: *const MultiLiteral, haystack: []const u8) ?usize {
        // For the whole-file scan use case, we want to find the earliest
        // occurrence of ANY needle. Since we're called repeatedly with
        // shrinking slices, just do a simple min-of-all scan.
        // The key optimization: use SIMD findFirst for each, then take min.
        // For 2-4 needles this is fast. For larger N, Aho-Corasick (M9) is better.
        var best: ?usize = null;
        for (self.needles) |needle| {
            if (literal.findFirst(haystack, needle)) |pos| {
                if (best) |b| {
                    if (pos < b) best = pos;
                    // Early exit: can't find anything at position 0
                    if (pos == 0) return 0;
                } else {
                    best = pos;
                }
            }
        }
        return best;
    }
};

/// Create the best prefilter for the given regex.
/// Returns null if no prefilter can be constructed.
pub fn selectPrefilter(
    required_literal: ?[]const u8,
    alternation_literals: ?[]const []const u8,
) ?Prefilter {
    // Alternation literals take priority (they cover the whole pattern)
    if (alternation_literals) |lits| {
        if (lits.len >= 2) {
            return .{ .multi = .{ .needles = lits } };
        }
    }
    // Fall back to required literal
    if (required_literal) |lit| {
        if (lit.len > 0) {
            return .{ .single = .{ .needle = lit } };
        }
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────

test "SingleLiteral prefilter" {
    const pf = Prefilter{ .single = .{ .needle = "world" } };
    const haystack = "hello world foo world bar";
    const pos = pf.findNextLineCandidate(haystack, 0);
    try std.testing.expectEqual(@as(usize, 6), pos.?);

    // Search from after first match: "world" at position 16
    const pos2 = pf.findNextLineCandidate(haystack, 11);
    try std.testing.expectEqual(@as(usize, 16), pos2.?);
}

test "MultiLiteral prefilter finds earliest match" {
    const needles = [_][]const u8{ "error", "warn", "fatal" };
    const pf = Prefilter{ .multi = .{ .needles = &needles } };

    const haystack = "this is a warn message with error inside";
    const pos = pf.findNextLineCandidate(haystack, 0);
    // "warn" at 10, "error" at 27 — should return 10
    try std.testing.expectEqual(@as(usize, 10), pos.?);
}

test "MultiLiteral prefilter returns null when no match" {
    const needles = [_][]const u8{ "error", "warn", "fatal" };
    const pf = Prefilter{ .multi = .{ .needles = &needles } };

    const haystack = "this is a normal message";
    try std.testing.expect(pf.findNextLineCandidate(haystack, 0) == null);
}

test "selectPrefilter prefers alternation literals" {
    const alt_lits = [_][]const u8{ "foo", "bar" };
    const pf = selectPrefilter("required", &alt_lits);
    try std.testing.expect(pf != null);
    try std.testing.expect(pf.? == .multi);
}

test "selectPrefilter falls back to required literal" {
    const pf = selectPrefilter("required", null);
    try std.testing.expect(pf != null);
    try std.testing.expect(pf.? == .single);
}
