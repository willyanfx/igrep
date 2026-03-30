const std = @import("std");
const regex_mod = @import("regex.zig");

const NfaState = regex_mod.NfaState;
const Nfa = regex_mod.Nfa;
const CharRange = regex_mod.CharRange;

/// Lazy DFA: caches NFA state-set transitions on demand.
///
/// Instead of simulating the full NFA for every character, we hash each
/// unique state-set into a compact DFA state ID.  On a cache hit (same
/// set of NFA states + same input byte) we jump straight to the next
/// DFA state without touching the NFA at all.
///
/// Uses byte equivalence classes to compress transition tables: bytes that
/// behave identically in the regex share a class, so each state only needs
/// `num_classes` entries instead of 256. This typically reduces state size
/// from 1KB to ~40 bytes, dramatically improving cache locality.
///
/// The cache is bounded: once it exceeds `MAX_DFA_STATES` we flush and
/// restart, which degrades gracefully to plain NFA speed on pathological
/// patterns that generate too many unique state-sets.
pub const LazyDfa = struct {
    /// Maximum cached DFA states before we flush.
    const MAX_DFA_STATES: usize = 4096;

    /// A DFA state is identified by its index in `states`.
    const StateId = u32;
    const UNKNOWN: StateId = std.math.maxInt(StateId);

    /// A DFA state: the NFA bitset it represents + compressed transition table.
    const DfaState = struct {
        /// Owned copy of the NFA bitset for this DFA state.
        bitset: []u64,
        /// Whether this state-set contains an NFA accept state.
        is_match: bool,
        /// Hash of the bitset (for intern lookup).
        hash: u64,
        /// Compressed transition table: trans[byte_class] = next DFA state, or UNKNOWN.
        /// Indexed by equivalence class (not raw byte), lazily filled.
        trans: []StateId,
    };

    allocator: std.mem.Allocator,
    nfa: *const Nfa,
    set_size: usize,

    /// All known DFA states.
    states: std.ArrayList(DfaState),

    /// Map from bitset hash → DFA state ID for dedup.
    hash_to_state: std.AutoHashMap(u64, StateId),

    /// Scratch buffer for NFA simulation (avoids per-step allocation).
    scratch_buf: []u64,

    /// Number of cache flushes.
    flush_count: u32,

    /// Byte equivalence classes (optional, for compression)
    byte_classes: *const [256]u8,
    num_classes: u16,

    /// Optimization 2: Required literal prefix for quick elimination
    required_literal: ?[]const u8 = null,
    literal_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, nfa: *const Nfa, byte_classes: *const [256]u8, num_classes: u16) !LazyDfa {
        return initWithLiteral(allocator, nfa, byte_classes, num_classes, null);
    }

    /// Initialize with optional required literal for prefiltering
    pub fn initWithLiteral(allocator: std.mem.Allocator, nfa: *const Nfa, byte_classes: *const [256]u8, num_classes: u16, literal: ?[]const u8) !LazyDfa {
        const num_states = nfa.states.len;
        const set_size = (num_states + 63) / 64;
        const scratch = try allocator.alloc(u64, set_size);
        @memset(scratch, 0);

        const lit_len = if (literal) |l| l.len else 0;

        return .{
            .allocator = allocator,
            .nfa = nfa,
            .set_size = set_size,
            .states = .{},
            .hash_to_state = std.AutoHashMap(u64, StateId).init(allocator),
            .scratch_buf = scratch,
            .flush_count = 0,
            .byte_classes = byte_classes,
            .num_classes = num_classes,
            .required_literal = literal,
            .literal_len = lit_len,
        };
    }

    pub fn deinit(self: *LazyDfa) void {
        for (self.states.items) |state| {
            self.allocator.free(state.bitset);
            self.allocator.free(state.trans);
        }
        if (self.states.capacity > 0) self.states.deinit(self.allocator);
        self.hash_to_state.deinit();
        self.allocator.free(self.scratch_buf);
    }

    /// Flush all cached states (on overflow).
    fn flush(self: *LazyDfa) void {
        for (self.states.items) |state| {
            self.allocator.free(state.bitset);
            self.allocator.free(state.trans);
        }
        self.states.items.len = 0;
        self.hash_to_state.clearRetainingCapacity();
        self.flush_count += 1;
    }

    /// Hash a bitset.
    fn hashBitset(self: *const LazyDfa, bitset: []const u64) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (bitset[0..self.set_size]) |word| {
            // Mix using FNV-1a at word granularity (faster than byte-by-byte)
            h ^= word;
            h *%= 0x100000001b3;
        }
        return h;
    }

    /// Look up or create a DFA state for the given NFA bitset.
    fn internState(self: *LazyDfa, bitset: []const u64) !StateId {
        const hash = self.hashBitset(bitset);

        if (self.hash_to_state.get(hash)) |existing_id| {
            const existing = &self.states.items[existing_id];
            if (std.mem.eql(u64, existing.bitset[0..self.set_size], bitset[0..self.set_size])) {
                return existing_id;
            }
        }

        if (self.states.items.len >= MAX_DFA_STATES) {
            self.flush();
        }

        const owned = try self.allocator.alloc(u64, self.set_size);
        @memcpy(owned, bitset[0..self.set_size]);

        const is_match = self.bitsetContainsAccept(owned);

        // Allocate compressed transition table (num_classes entries), initialized to UNKNOWN
        const trans = try self.allocator.alloc(StateId, self.num_classes);
        @memset(trans, UNKNOWN);

        const id: StateId = @intCast(self.states.items.len);
        try self.states.append(self.allocator, .{
            .bitset = owned,
            .is_match = is_match,
            .hash = hash,
            .trans = trans,
        });
        try self.hash_to_state.put(hash, id);

        return id;
    }

    fn bitsetContainsAccept(self: *const LazyDfa, bitset: []const u64) bool {
        for (self.nfa.states, 0..) |state, i| {
            if (state.kind == .accept) {
                const idx: u32 = @intCast(i);
                if ((bitset[idx / 64] >> @intCast(idx % 64)) & 1 == 1) {
                    return true;
                }
            }
        }
        return false;
    }

    /// Compute the next DFA state from `current` on input `byte`.
    /// Hot path: byte class lookup + single array lookup. Cold path: NFA simulation + cache fill.
    inline fn step(self: *LazyDfa, current: StateId, byte: u8, text: []const u8, next_pos: usize) !StateId {
        const class = self.byte_classes[byte];
        const trans = self.states.items[current].trans;
        const cached = trans[class];
        if (cached != UNKNOWN) return cached;

        return self.stepSlow(current, byte, class, text, next_pos);
    }

    /// Cold path: simulate one NFA step, intern result, fill transition table.
    fn stepSlow(self: *LazyDfa, current: StateId, byte: u8, class: u8, text: []const u8, next_pos: usize) !StateId {
        const current_bitset = self.states.items[current].bitset;
        @memset(self.scratch_buf[0..self.set_size], 0);

        const num_states = self.nfa.states.len;
        for (0..num_states) |si| {
            const idx: u32 = @intCast(si);
            if ((current_bitset[idx / 64] >> @intCast(idx % 64)) & 1 == 0) continue;

            const state = &self.nfa.states[si];
            switch (state.kind) {
                .match_char => {
                    if (byte == state.char) {
                        addStateNoAlloc(self.scratch_buf[0..self.set_size], self.nfa, state.out1, text, next_pos);
                    }
                },
                .match_any => {
                    if (byte != '\n') {
                        addStateNoAlloc(self.scratch_buf[0..self.set_size], self.nfa, state.out1, text, next_pos);
                    }
                },
                .match_class => {
                    const matches = if (state.class_lut) |lut| lut[byte] else matchCharClass(byte, state.ranges, state.negated);
                    if (matches) {
                        addStateNoAlloc(self.scratch_buf[0..self.set_size], self.nfa, state.out1, text, next_pos);
                    }
                },
                .split, .accept, .anchor_start, .anchor_end, .word_boundary => {},
            }
        }

        // Seed start state at new position (unanchored search)
        addStateNoAlloc(self.scratch_buf[0..self.set_size], self.nfa, self.nfa.start, text, next_pos);

        const next_id = try self.internState(self.scratch_buf[0..self.set_size]);

        // Fill the transition table (the current state may have moved due to flush,
        // so re-index). After a flush the current state is gone, so skip caching.
        if (current < self.states.items.len) {
            self.states.items[current].trans[class] = next_id;
        }

        return next_id;
    }

    /// Run the lazy DFA over `text` and return true if any position matches.
    /// Optimization 2: Uses required literal prefilter if available.
    pub fn isMatch(self: *LazyDfa, text: []const u8) !bool {
        // Optimization 2: If we have a required literal, only check positions where it appears
        if (self.required_literal) |literal| {
            var search_from: usize = 0;
            while (std.mem.indexOfPos(u8, text, search_from, literal)) |lit_pos| {
                // Run DFA from the literal position
                if (try self.isMatchFrom(text, lit_pos)) return true;
                search_from = lit_pos + 1;
            }
            return false;
        }

        // Standard full-scan when no prefilter
        return self.isMatchFullScan(text);
    }

    /// Standard full scan without literal prefilter
    fn isMatchFullScan(self: *LazyDfa, text: []const u8) !bool {
        // Build initial state
        @memset(self.scratch_buf[0..self.set_size], 0);
        addStateNoAlloc(self.scratch_buf[0..self.set_size], self.nfa, self.nfa.start, text, 0);

        var current = try self.internState(self.scratch_buf[0..self.set_size]);

        if (self.states.items[current].is_match) return true;

        // Process each byte — hot loop with O(1) cache lookups
        for (text, 0..) |byte, pos| {
            current = try self.step(current, byte, text, pos + 1);
            if (self.states.items[current].is_match) return true;
        }

        return false;
    }

    /// Run DFA from a specific starting position in text.
    /// Used by literal prefilter to check windows around literal occurrences.
    fn isMatchFrom(self: *LazyDfa, text: []const u8, start_pos: usize) !bool {
        if (start_pos >= text.len) return false;

        // Build initial state at start_pos
        @memset(self.scratch_buf[0..self.set_size], 0);
        addStateNoAlloc(self.scratch_buf[0..self.set_size], self.nfa, self.nfa.start, text, start_pos);

        var current = try self.internState(self.scratch_buf[0..self.set_size]);

        if (self.states.items[current].is_match) return true;

        // Process each byte from start_pos onwards
        for (text[start_pos..], 0..) |byte, i| {
            current = try self.step(current, byte, text, start_pos + i + 1);
            if (self.states.items[current].is_match) return true;
        }

        return false;
    }
};

// ── NFA helper functions ────────────────────────────────────────────

fn addStateNoAlloc(set: []u64, nfa: *const Nfa, state_idx: u32, text: []const u8, pos: usize) void {
    if (state_idx == NfaState.NONE) return;
    if (state_idx >= nfa.states.len) return;
    if (getBit(set, state_idx)) return;

    setBit(set, state_idx);

    const state = &nfa.states[state_idx];
    switch (state.kind) {
        .split => {
            // Optimization 1: Use pre-computed epsilon closure if available
            if (nfa.epsilon_closures) |closures| {
                if (state_idx < closures.len) {
                    const closure = closures[state_idx];
                    // OR the entire closure into the set
                    for (closure, 0..) |word, i| {
                        set[i] |= word;
                    }
                    return;
                }
            }
            // Fallback to recursive epsilon closure
            addStateNoAlloc(set, nfa, state.out1, text, pos);
            addStateNoAlloc(set, nfa, state.out2, text, pos);
        },
        .anchor_start => {
            if (pos == 0 or (pos > 0 and text[pos - 1] == '\n')) {
                addStateNoAlloc(set, nfa, state.out1, text, pos);
            }
        },
        .anchor_end => {
            if (pos >= text.len or text[pos] == '\n') {
                addStateNoAlloc(set, nfa, state.out1, text, pos);
            }
        },
        .word_boundary => {
            const before_word = pos > 0 and isWordChar(text[pos - 1]);
            const after_word = pos < text.len and isWordChar(text[pos]);
            if (before_word != after_word) {
                addStateNoAlloc(set, nfa, state.out1, text, pos);
            }
        },
        else => {},
    }
}

inline fn getBit(set: []const u64, idx: u32) bool {
    return (set[idx / 64] >> @intCast(idx % 64)) & 1 == 1;
}

inline fn setBit(set: []u64, idx: u32) void {
    set[idx / 64] |= @as(u64, 1) << @intCast(idx % 64);
}

fn matchCharClass(ch: u8, ranges: []const CharRange, negated: bool) bool {
    var in_class = false;
    for (ranges) |range| {
        if (ch >= range.low and ch <= range.high) {
            in_class = true;
            break;
        }
    }
    return if (negated) !in_class else in_class;
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// ── Tests ────────────────────────────────────────────────────────────

test "LazyDfa basic literal match" {
    const allocator = std.testing.allocator;
    var re = try regex_mod.Regex.compile(allocator, "ab.c");
    defer re.deinit(allocator);

    var dfa = try LazyDfa.init(allocator, &re.nfa, &re.byte_classes, re.num_classes);
    defer dfa.deinit();

    try std.testing.expect(try dfa.isMatch("xabxcy"));
    try std.testing.expect(!try dfa.isMatch("abc"));
    try std.testing.expect(try dfa.isMatch("ab_c"));
    try std.testing.expect(!try dfa.isMatch("abxy"));
}

test "LazyDfa alternation" {
    const allocator = std.testing.allocator;
    var re = try regex_mod.Regex.compile(allocator, "cat|dog");
    defer re.deinit(allocator);

    var dfa = try LazyDfa.init(allocator, &re.nfa, &re.byte_classes, re.num_classes);
    defer dfa.deinit();

    try std.testing.expect(try dfa.isMatch("I have a cat"));
    try std.testing.expect(try dfa.isMatch("I have a dog"));
    try std.testing.expect(!try dfa.isMatch("I have a bird"));
}

test "LazyDfa quantifier" {
    const allocator = std.testing.allocator;
    var re = try regex_mod.Regex.compile(allocator, "ab+c");
    defer re.deinit(allocator);

    var dfa = try LazyDfa.init(allocator, &re.nfa, &re.byte_classes, re.num_classes);
    defer dfa.deinit();

    try std.testing.expect(!try dfa.isMatch("ac"));
    try std.testing.expect(try dfa.isMatch("abc"));
    try std.testing.expect(try dfa.isMatch("abbbc"));
}

test "LazyDfa character class" {
    const allocator = std.testing.allocator;
    var re = try regex_mod.Regex.compile(allocator, "[a-z]+");
    defer re.deinit(allocator);

    var dfa = try LazyDfa.init(allocator, &re.nfa, &re.byte_classes, re.num_classes);
    defer dfa.deinit();

    try std.testing.expect(try dfa.isMatch("hello"));
    try std.testing.expect(!try dfa.isMatch("12345"));
}

test "LazyDfa shorthand classes" {
    const allocator = std.testing.allocator;
    var re = try regex_mod.Regex.compile(allocator, "fn\\s+\\w+\\(");
    defer re.deinit(allocator);

    var dfa = try LazyDfa.init(allocator, &re.nfa, &re.byte_classes, re.num_classes);
    defer dfa.deinit();

    try std.testing.expect(try dfa.isMatch("pub fn init(allocator: Allocator) void {"));
    try std.testing.expect(try dfa.isMatch("fn main() !void {"));
    try std.testing.expect(!try dfa.isMatch("const fn_name = 42;"));
}

test "LazyDfa anchors" {
    const allocator = std.testing.allocator;
    var re_start = try regex_mod.Regex.compile(allocator, "^hello");
    defer re_start.deinit(allocator);

    var dfa_start = try LazyDfa.init(allocator, &re_start.nfa, &re_start.byte_classes, re_start.num_classes);
    defer dfa_start.deinit();

    try std.testing.expect(try dfa_start.isMatch("hello world"));
    try std.testing.expect(!try dfa_start.isMatch("say hello"));
}

test "LazyDfa cache reuse" {
    const allocator = std.testing.allocator;
    var re = try regex_mod.Regex.compile(allocator, "\\d+\\.\\d+");
    defer re.deinit(allocator);

    var dfa = try LazyDfa.init(allocator, &re.nfa, &re.byte_classes, re.num_classes);
    defer dfa.deinit();

    try std.testing.expect(try dfa.isMatch("version 1.23"));
    try std.testing.expect(try dfa.isMatch("pi is 3.14159"));
    try std.testing.expect(!try dfa.isMatch("no numbers here"));

    try std.testing.expect(dfa.states.items.len > 0);
}

test "LazyDfa empty text" {
    const allocator = std.testing.allocator;
    var re = try regex_mod.Regex.compile(allocator, "abc");
    defer re.deinit(allocator);

    var dfa = try LazyDfa.init(allocator, &re.nfa, &re.byte_classes, re.num_classes);
    defer dfa.deinit();

    try std.testing.expect(!try dfa.isMatch(""));
}
