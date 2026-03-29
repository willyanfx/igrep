const std = @import("std");
const trigram = @import("../engine/trigram.zig");
const regex = @import("../engine/regex.zig");

/// A query plan built by decomposing a regex AST into trigram lookups.
///
/// - And: all sub-plans must match (concatenated literal fragments)
/// - Or: at least one sub-plan must match (alternation)
/// - Trigrams: leaf node with a list of trigram hashes (from a single literal run)
/// - MatchAll: no trigrams extractable — must scan all files
pub const QueryPlan = union(enum) {
    match_all: void,
    trigrams: []u32, // trigram hashes from a single literal fragment
    and_plan: []QueryPlan,
    or_plan: []QueryPlan,

    pub fn deinit(self: *QueryPlan, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .trigrams => |hashes| {
                if (hashes.len > 0) allocator.free(hashes);
            },
            .and_plan => |plans| {
                for (plans) |*p| {
                    @constCast(p).deinit(allocator);
                }
                if (plans.len > 0) allocator.free(plans);
            },
            .or_plan => |plans| {
                for (plans) |*p| {
                    @constCast(p).deinit(allocator);
                }
                if (plans.len > 0) allocator.free(plans);
            },
            .match_all => {},
        }
    }

    /// Check if this plan can narrow the search (i.e., is not MatchAll).
    pub fn isSelective(self: *const QueryPlan) bool {
        return switch (self.*) {
            .match_all => false,
            .trigrams => |h| h.len > 0,
            .and_plan => |plans| {
                for (plans) |*p| {
                    if (p.isSelective()) return true;
                }
                return false;
            },
            .or_plan => |plans| {
                // OR is only selective if ALL branches are selective
                for (plans) |*p| {
                    if (!p.isSelective()) return false;
                }
                return plans.len > 0;
            },
        };
    }
};

/// Decompose a regex AST into a QueryPlan of trigram lookups.
///
/// Walks the AST to extract literal byte fragments, converts each fragment
/// into trigram hashes, and combines them with AND (concat) / OR (alternation).
///
/// For patterns with no extractable literals (e.g., `\d+`), returns MatchAll.
pub fn decompose(ast: *const regex.AstNode, allocator: std.mem.Allocator) !QueryPlan {
    return decomposeNode(ast, allocator);
}

fn decomposeNode(node: *const regex.AstNode, allocator: std.mem.Allocator) !QueryPlan {
    switch (node.kind) {
        .literal => {
            // Single literal — too short for trigrams by itself,
            // but will be collected by concat handling
            return .{ .match_all = {} };
        },

        .concat => {
            // Flatten the left-associative concat tree and collect literal runs.
            // Each run of consecutive literals becomes a trigram leaf.
            // Non-literal gaps separate runs.
            var fragments: std.ArrayList(QueryPlan) = .{};
            defer if (fragments.capacity > 0) fragments.deinit(allocator);

            var literal_buf: std.ArrayList(u8) = .{};
            defer if (literal_buf.capacity > 0) literal_buf.deinit(allocator);

            // Flatten concat tree into an ordered list of nodes
            var flat_nodes: std.ArrayList(*const regex.AstNode) = .{};
            defer if (flat_nodes.capacity > 0) flat_nodes.deinit(allocator);
            try flattenConcat(node, &flat_nodes, allocator);

            for (flat_nodes.items) |child| {
                if (child.kind == .literal) {
                    try literal_buf.append(allocator, child.char);
                } else {
                    // Flush accumulated literals
                    if (literal_buf.items.len >= trigram.TRIGRAM_SIZE) {
                        const plan = try literalsToTrigrams(literal_buf.items, allocator);
                        try fragments.append(allocator, plan);
                    }
                    literal_buf.items.len = 0;

                    // Recurse into non-literal child
                    const child_plan = try decomposeNode(child, allocator);
                    if (child_plan.isSelective()) {
                        try fragments.append(allocator, child_plan);
                    } else {
                        // Discard non-selective plans (no need to store MatchAll)
                        var cp = child_plan;
                        cp.deinit(allocator);
                    }
                }
            }

            // Flush remaining literals
            if (literal_buf.items.len >= trigram.TRIGRAM_SIZE) {
                const plan = try literalsToTrigrams(literal_buf.items, allocator);
                try fragments.append(allocator, plan);
            }

            return switch (fragments.items.len) {
                0 => .{ .match_all = {} },
                1 => fragments.items[0],
                else => .{ .and_plan = try fragments.toOwnedSlice(allocator) },
            };
        },

        .alternate => {
            // Both branches must be selective for the OR to help.
            // If either branch is MatchAll, the whole OR is MatchAll.
            var branches: std.ArrayList(QueryPlan) = .{};
            defer if (branches.capacity > 0) branches.deinit(allocator);

            // Flatten alternation tree (also left-associative)
            var flat_alts: std.ArrayList(*const regex.AstNode) = .{};
            defer if (flat_alts.capacity > 0) flat_alts.deinit(allocator);
            try flattenAlternate(node, &flat_alts, allocator);

            for (flat_alts.items) |alt| {
                const plan = try decomposeNode(alt, allocator);
                if (!plan.isSelective()) {
                    // One non-selective branch → entire OR is MatchAll
                    var p = plan;
                    p.deinit(allocator);
                    for (branches.items) |*b| b.deinit(allocator);
                    return .{ .match_all = {} };
                }
                try branches.append(allocator, plan);
            }

            return switch (branches.items.len) {
                0 => .{ .match_all = {} },
                1 => branches.items[0],
                else => .{ .or_plan = try branches.toOwnedSlice(allocator) },
            };
        },

        .quantifier => {
            // If min_rep >= 1, the child MUST appear — recurse into it.
            if (node.min_rep >= 1) {
                if (node.child) |child| {
                    return decomposeNode(child, allocator);
                }
            }
            return .{ .match_all = {} };
        },

        // Grouping (captured by concat/alternate recursion)
        // Anchors, boundaries, char classes, dot — no extractable literals
        .dot, .char_class, .anchor_start, .anchor_end, .word_boundary => {
            return .{ .match_all = {} };
        },
    }
}

/// Flatten a left-associative concat tree into an ordered list of leaf nodes.
fn flattenConcat(
    node: *const regex.AstNode,
    out: *std.ArrayList(*const regex.AstNode),
    allocator: std.mem.Allocator,
) !void {
    if (node.kind == .concat) {
        if (node.left) |left| {
            try flattenConcat(left, out, allocator);
        }
        if (node.right) |right| {
            try flattenConcat(right, out, allocator);
        }
    } else {
        try out.append(allocator, node);
    }
}

/// Flatten a left-associative alternate tree into a list of branches.
fn flattenAlternate(
    node: *const regex.AstNode,
    out: *std.ArrayList(*const regex.AstNode),
    allocator: std.mem.Allocator,
) !void {
    if (node.kind == .alternate) {
        if (node.left) |left| {
            try flattenAlternate(left, out, allocator);
        }
        if (node.right) |right| {
            try flattenAlternate(right, out, allocator);
        }
    } else {
        try out.append(allocator, node);
    }
}

/// Convert a byte sequence into trigram hashes.
fn literalsToTrigrams(bytes: []const u8, allocator: std.mem.Allocator) !QueryPlan {
    if (bytes.len < trigram.TRIGRAM_SIZE) {
        return .{ .match_all = {} };
    }

    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    var hashes: std.ArrayList(u32) = .{};
    errdefer if (hashes.capacity > 0) hashes.deinit(allocator);

    for (0..bytes.len - trigram.TRIGRAM_SIZE + 1) |i| {
        const hash = trigram.trigramHash(bytes[i..][0..3]);
        const result = try seen.getOrPut(hash);
        if (!result.found_existing) {
            try hashes.append(allocator, hash);
        }
    }

    if (hashes.items.len == 0) {
        return .{ .match_all = {} };
    }

    return .{ .trigrams = try hashes.toOwnedSlice(allocator) };
}

// ── Tests ────────────────────────────────────────────────────────────

/// Helper: parse a pattern with an arena (AST freed on arena deinit) and decompose it.
fn testDecompose(pattern: []const u8) !QueryPlan {
    const allocator = std.testing.allocator;
    // Use arena for AST nodes (freed when arena is destroyed), real allocator for plan
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser = regex.Parser.init(arena, pattern);
    const ast = try parser.parse();
    return try decompose(ast, allocator);
}

test "decompose pure literal pattern" {
    var plan = try testDecompose("function");
    defer plan.deinit(std.testing.allocator);

    // "function" = 8 bytes → 6 trigrams, should be selective
    try std.testing.expect(plan.isSelective());

    switch (plan) {
        .trigrams => |hashes| {
            try std.testing.expectEqual(@as(usize, 6), hashes.len);
        },
        .and_plan => |plans| {
            try std.testing.expect(plans.len >= 1);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "decompose alternation pattern" {
    var plan = try testDecompose("TODO|FIXME");
    defer plan.deinit(std.testing.allocator);

    try std.testing.expect(plan.isSelective());

    switch (plan) {
        .or_plan => |branches| {
            try std.testing.expectEqual(@as(usize, 2), branches.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "decompose short literal returns MatchAll" {
    var plan = try testDecompose("fn");
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(!plan.isSelective());
}

test "decompose regex with literal fragments" {
    var plan = try testDecompose("import\\s+\\{");
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.isSelective());
}

test "decompose dot-star between literals" {
    var plan = try testDecompose("TypeError.*found");
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.isSelective());
}

test "decompose pure wildcard returns MatchAll" {
    var plan = try testDecompose("\\d+\\.\\d+");
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(!plan.isSelective());
}

test "decompose alternation with short branch returns MatchAll" {
    var plan = try testDecompose("TODO|ab");
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(!plan.isSelective());
}

test "decompose quantifier with min >= 1" {
    var plan = try testDecompose("error+");
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.isSelective());
}
