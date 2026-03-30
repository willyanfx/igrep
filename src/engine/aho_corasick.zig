const std = @import("std");

/// Aho-Corasick automaton for simultaneous multi-pattern matching in O(n) time.
/// Uses a trie with failure links (suffix links) built via BFS.
/// Optimized for grep use case: reports first match position only.
pub const AhoCorasick = struct {
    /// Flat array of trie nodes. Node 0 is the root.
    nodes: []Node,
    /// Number of patterns in the automaton.
    pattern_count: u32,
    allocator: std.mem.Allocator,

    const NONE: u32 = std.math.maxInt(u32);

    const Node = struct {
        /// Goto transitions: child[byte] = next state ID, or NONE.
        /// Stored as a sorted list of (byte, state_id) pairs for memory efficiency.
        children: []Transition,
        /// Failure link: longest proper suffix that is also a prefix of some pattern.
        fail: u32,
        /// If this node is the end of a pattern, stores the pattern index.
        /// NONE if not a match state.
        output: u32,
        /// Dictionary suffix link: follows fail links to next match state.
        dict_suffix: u32,
        /// Depth from root (used for match position calculation).
        depth: u16,
    };

    const Transition = struct {
        byte: u8,
        state: u32,
    };

    /// Build an Aho-Corasick automaton from a set of patterns.
    pub fn build(allocator: std.mem.Allocator, patterns: []const []const u8) !AhoCorasick {
        if (patterns.len == 0) {
            const nodes = try allocator.alloc(Node, 1);
            nodes[0] = .{
                .children = &.{},
                .fail = 0,
                .output = NONE,
                .dict_suffix = NONE,
                .depth = 0,
            };
            return .{ .nodes = nodes, .pattern_count = 0, .allocator = allocator };
        }

        // Phase 1: Build trie
        var node_list: std.ArrayList(Node) = .{};
        errdefer {
            for (node_list.items) |*n| {
                if (n.children.len > 0) allocator.free(n.children);
            }
            if (node_list.capacity > 0) node_list.deinit(allocator);
        }

        // Root node
        try node_list.append(allocator, .{
            .children = &.{},
            .fail = 0,
            .output = NONE,
            .dict_suffix = NONE,
            .depth = 0,
        });

        for (patterns, 0..) |pattern, pat_idx| {
            var current: u32 = 0;
            for (pattern) |byte| {
                const child = findChild(node_list.items[current].children, byte);
                if (child != NONE) {
                    current = child;
                } else {
                    const new_id: u32 = @intCast(node_list.items.len);
                    try node_list.append(allocator, .{
                        .children = &.{},
                        .fail = 0,
                        .output = NONE,
                        .dict_suffix = NONE,
                        .depth = node_list.items[current].depth + 1,
                    });
                    // Add transition to parent
                    try addChild(allocator, &node_list.items[current], byte, new_id);
                    current = new_id;
                }
            }
            node_list.items[current].output = @intCast(pat_idx);
        }

        // Phase 2: Build failure links via BFS
        var queue: std.ArrayList(u32) = .{};
        defer if (queue.capacity > 0) queue.deinit(allocator);

        // All depth-1 nodes fail to root
        for (node_list.items[0].children) |child| {
            node_list.items[child.state].fail = 0;
            try queue.append(allocator, child.state);
        }

        var front: usize = 0;
        while (front < queue.items.len) {
            const u = queue.items[front];
            front += 1;

            for (node_list.items[u].children) |child| {
                const v = child.state;
                try queue.append(allocator, v);

                // Follow failure links from parent to find failure state for v
                var f = node_list.items[u].fail;
                while (f != 0 and findChild(node_list.items[f].children, child.byte) == NONE) {
                    f = node_list.items[f].fail;
                }
                const fc = findChild(node_list.items[f].children, child.byte);
                if (fc != NONE and fc != v) {
                    node_list.items[v].fail = fc;
                } else {
                    node_list.items[v].fail = 0;
                }

                // Dictionary suffix link
                const fail_state = node_list.items[v].fail;
                if (node_list.items[fail_state].output != NONE) {
                    node_list.items[v].dict_suffix = fail_state;
                } else {
                    node_list.items[v].dict_suffix = node_list.items[fail_state].dict_suffix;
                }
            }
        }

        const nodes = try node_list.toOwnedSlice(allocator);
        return .{
            .nodes = nodes,
            .pattern_count = @intCast(patterns.len),
            .allocator = allocator,
        };
    }

    /// Find the first occurrence of any pattern in the haystack.
    /// Returns the byte position of the start of the first match, or null.
    pub fn findFirst(self: *const AhoCorasick, haystack: []const u8) ?usize {
        if (self.pattern_count == 0) return null;

        var state: u32 = 0;
        for (haystack, 0..) |byte, i| {
            // Follow failure links until we find a goto transition or reach root
            while (state != 0 and findChild(self.nodes[state].children, byte) == NONE) {
                state = self.nodes[state].fail;
            }
            const next = findChild(self.nodes[state].children, byte);
            if (next != NONE) {
                state = next;
            }
            // else: stay at root

            // Check for match at this state or via dictionary suffix links
            if (self.nodes[state].output != NONE) {
                return i + 1 - self.nodes[state].depth;
            }
            var ds = self.nodes[state].dict_suffix;
            while (ds != NONE) {
                if (self.nodes[ds].output != NONE) {
                    return i + 1 - self.nodes[ds].depth;
                }
                ds = self.nodes[ds].dict_suffix;
            }
        }
        return null;
    }

    /// Find the first occurrence starting at or after `start`.
    pub fn findFirstFrom(self: *const AhoCorasick, haystack: []const u8, start: usize) ?usize {
        if (start >= haystack.len) return null;
        if (self.findFirst(haystack[start..])) |pos| {
            return start + pos;
        }
        return null;
    }

    /// Check if any pattern occurs in the haystack.
    pub fn contains(self: *const AhoCorasick, haystack: []const u8) bool {
        return self.findFirst(haystack) != null;
    }

    pub fn deinit(self: *AhoCorasick) void {
        for (self.nodes) |*node| {
            if (node.children.len > 0) self.allocator.free(node.children);
        }
        self.allocator.free(self.nodes);
    }

    // ── Internal helpers ─────────────────────────────────────────────

    fn findChild(children: []const Transition, byte: u8) u32 {
        // Binary search for small arrays, linear for very small
        if (children.len <= 8) {
            for (children) |c| {
                if (c.byte == byte) return c.state;
            }
            return NONE;
        }
        var lo: usize = 0;
        var hi: usize = children.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (children[mid].byte < byte) {
                lo = mid + 1;
            } else if (children[mid].byte > byte) {
                hi = mid;
            } else {
                return children[mid].state;
            }
        }
        return NONE;
    }

    fn addChild(allocator: std.mem.Allocator, node: *Node, byte: u8, state: u32) !void {
        const old = node.children;
        const new_children = try allocator.alloc(Transition, old.len + 1);
        // Insert in sorted order
        var inserted = false;
        var j: usize = 0;
        for (old) |c| {
            if (!inserted and byte < c.byte) {
                new_children[j] = .{ .byte = byte, .state = state };
                j += 1;
                inserted = true;
            }
            new_children[j] = c;
            j += 1;
        }
        if (!inserted) {
            new_children[j] = .{ .byte = byte, .state = state };
        }
        if (old.len > 0) allocator.free(old);
        node.children = new_children;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "AhoCorasick basic multi-pattern" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{ "he", "she", "his", "hers" };
    var ac = try AhoCorasick.build(allocator, &patterns);
    defer ac.deinit();

    try std.testing.expect(ac.contains("ushers"));
    try std.testing.expect(ac.contains("she sells"));
    try std.testing.expect(!ac.contains("xyz"));
    try std.testing.expect(ac.contains("this"));

    // Check position
    try std.testing.expectEqual(@as(usize, 1), ac.findFirst("ushers").?);
}

test "AhoCorasick alternation pattern" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{ "import", "export", "require" };
    var ac = try AhoCorasick.build(allocator, &patterns);
    defer ac.deinit();

    try std.testing.expect(ac.contains("import os"));
    try std.testing.expect(ac.contains("export default"));
    try std.testing.expect(ac.contains("require('fs')"));
    try std.testing.expect(!ac.contains("function main()"));

    // Finds earliest match
    const pos = ac.findFirst("no export but import here").?;
    try std.testing.expectEqual(@as(usize, 3), pos); // "export" at 3
}

test "AhoCorasick overlapping patterns" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{ "ab", "abc", "bc" };
    var ac = try AhoCorasick.build(allocator, &patterns);
    defer ac.deinit();

    // "ab" matches first at position 0
    try std.testing.expectEqual(@as(usize, 0), ac.findFirst("abcd").?);
}

test "AhoCorasick empty patterns" {
    const allocator = std.testing.allocator;
    var ac = try AhoCorasick.build(allocator, &[_][]const u8{});
    defer ac.deinit();

    try std.testing.expect(!ac.contains("anything"));
}

test "AhoCorasick single pattern" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{"hello"};
    var ac = try AhoCorasick.build(allocator, &patterns);
    defer ac.deinit();

    try std.testing.expectEqual(@as(usize, 0), ac.findFirst("hello world").?);
    try std.testing.expect(!ac.contains("world"));
}

test "AhoCorasick findFirstFrom" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{ "foo", "bar" };
    var ac = try AhoCorasick.build(allocator, &patterns);
    defer ac.deinit();

    const haystack = "foo and bar and foo";
    try std.testing.expectEqual(@as(usize, 0), ac.findFirstFrom(haystack, 0).?);
    try std.testing.expectEqual(@as(usize, 8), ac.findFirstFrom(haystack, 1).?);
    try std.testing.expectEqual(@as(usize, 16), ac.findFirstFrom(haystack, 12).?);
}
