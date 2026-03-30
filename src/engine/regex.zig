const std = @import("std");
const lazy_dfa_mod = @import("lazy_dfa.zig");

/// Regex engine using Thompson NFA construction.
///
/// Supported syntax:
///   .        any character (except newline)
///   *        zero or more (greedy)
///   +        one or more (greedy)
///   ?        zero or one
///   |        alternation
///   (...)    grouping
///   [abc]    character class
///   [^abc]   negated character class
///   [a-z]    character range
///   \d \w \s digit/word/whitespace shortcuts
///   \D \W \S negated shortcuts
///   ^        start of line
///   $        end of line
///   \b       word boundary
///   {n}      exact repetition
///   {n,}     at least n
///   {n,m}    between n and m
///
/// Performance: O(n*m) worst case where n = text length, m = NFA states.
/// Pure literal patterns are detected and dispatched to SIMD search.

// ── Token types ──────────────────────────────────────────────────────

pub const TokenKind = enum {
    literal, // single character
    dot, // .
    star, // *
    plus, // +
    question, // ?
    pipe, // |
    lparen, // (
    rparen, // )
    lbracket, // [
    rbracket, // ]
    caret, // ^ (start anchor or negation in class)
    dollar, // $ (end anchor)
    backslash_d, // \d
    backslash_D, // \D
    backslash_w, // \w
    backslash_W, // \W
    backslash_s, // \s
    backslash_S, // \S
    backslash_b, // \b
    lbrace, // {
    rbrace, // }
    comma, // , (inside {n,m})
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    char: u8 = 0, // for literal tokens
};

// ── Tokenizer ────────────────────────────────────────────────────────

pub const Tokenizer = struct {
    source: []const u8,
    pos: usize = 0,

    pub fn init(pattern: []const u8) Tokenizer {
        return .{ .source = pattern };
    }

    pub fn next(self: *Tokenizer) Token {
        if (self.pos >= self.source.len) return .{ .kind = .eof };

        const c = self.source[self.pos];
        self.pos += 1;

        return switch (c) {
            '.' => .{ .kind = .dot },
            '*' => .{ .kind = .star },
            '+' => .{ .kind = .plus },
            '?' => .{ .kind = .question },
            '|' => .{ .kind = .pipe },
            '(' => .{ .kind = .lparen },
            ')' => .{ .kind = .rparen },
            '[' => .{ .kind = .lbracket },
            ']' => .{ .kind = .rbracket },
            '^' => .{ .kind = .caret },
            '$' => .{ .kind = .dollar },
            '{' => .{ .kind = .lbrace },
            '}' => .{ .kind = .rbrace },
            ',' => .{ .kind = .comma },
            '\\' => self.parseEscape(),
            else => .{ .kind = .literal, .char = c },
        };
    }

    fn parseEscape(self: *Tokenizer) Token {
        if (self.pos >= self.source.len) return .{ .kind = .literal, .char = '\\' };

        const c = self.source[self.pos];
        self.pos += 1;

        return switch (c) {
            'd' => .{ .kind = .backslash_d },
            'D' => .{ .kind = .backslash_D },
            'w' => .{ .kind = .backslash_w },
            'W' => .{ .kind = .backslash_W },
            's' => .{ .kind = .backslash_s },
            'S' => .{ .kind = .backslash_S },
            'b' => .{ .kind = .backslash_b },
            'n' => .{ .kind = .literal, .char = '\n' },
            'r' => .{ .kind = .literal, .char = '\r' },
            't' => .{ .kind = .literal, .char = '\t' },
            // Escaped metacharacters become literal
            '.', '*', '+', '?', '|', '(', ')', '[', ']', '^', '$', '{', '}', '\\' => .{ .kind = .literal, .char = c },
            else => .{ .kind = .literal, .char = c },
        };
    }

    pub fn peek(self: *Tokenizer) Token {
        const saved = self.pos;
        const tok = self.next();
        self.pos = saved;
        return tok;
    }
};

// ── AST ──────────────────────────────────────────────────────────────

pub const AstNodeKind = enum {
    literal, // single char
    dot, // any char
    char_class, // [abc] or [a-z]
    anchor_start, // ^
    anchor_end, // $
    word_boundary, // \b
    concat, // AB
    alternate, // A|B
    quantifier, // A*, A+, A?, A{n,m}
};

pub const CharRange = struct {
    low: u8,
    high: u8,
};

pub const AstNode = struct {
    kind: AstNodeKind,

    // For literal
    char: u8 = 0,

    // For char_class
    ranges: []CharRange = &.{},
    negated: bool = false,

    // For concat, alternate
    left: ?*AstNode = null,
    right: ?*AstNode = null,

    // For quantifier
    child: ?*AstNode = null,
    min_rep: u32 = 0,
    max_rep: u32 = 0, // 0 = unlimited
    greedy: bool = true,
};

// ── Parser (recursive descent) ───────────────────────────────────────

pub const Parser = struct {
    tokenizer: Tokenizer,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8) Parser {
        return .{
            .tokenizer = Tokenizer.init(pattern),
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser) !*AstNode {
        const node = try self.parseAlternation();
        const tok = self.tokenizer.peek();
        if (tok.kind != .eof and tok.kind != .rparen) {
            // Unexpected token — just return what we have
        }
        return node;
    }

    fn parseAlternation(self: *Parser) !*AstNode {
        var left = try self.parseConcatenation();

        while (self.tokenizer.peek().kind == .pipe) {
            _ = self.tokenizer.next(); // consume |
            const right = try self.parseConcatenation();
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .kind = .alternate,
                .left = left,
                .right = right,
            };
            left = node;
        }

        return left;
    }

    fn parseConcatenation(self: *Parser) !*AstNode {
        var left = try self.parseQuantifier();

        while (true) {
            const tok = self.tokenizer.peek();
            if (tok.kind == .eof or tok.kind == .pipe or tok.kind == .rparen) break;
            const right = try self.parseQuantifier();
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .kind = .concat,
                .left = left,
                .right = right,
            };
            left = node;
        }

        return left;
    }

    fn parseQuantifier(self: *Parser) !*AstNode {
        var atom = try self.parseAtom();

        const tok = self.tokenizer.peek();
        switch (tok.kind) {
            .star => {
                _ = self.tokenizer.next();
                const node = try self.allocator.create(AstNode);
                node.* = .{ .kind = .quantifier, .child = atom, .min_rep = 0, .max_rep = 0 };
                atom = node;
            },
            .plus => {
                _ = self.tokenizer.next();
                const node = try self.allocator.create(AstNode);
                node.* = .{ .kind = .quantifier, .child = atom, .min_rep = 1, .max_rep = 0 };
                atom = node;
            },
            .question => {
                _ = self.tokenizer.next();
                const node = try self.allocator.create(AstNode);
                node.* = .{ .kind = .quantifier, .child = atom, .min_rep = 0, .max_rep = 1 };
                atom = node;
            },
            .lbrace => {
                if (try self.tryParseRepetition(atom)) |rep_node| {
                    atom = rep_node;
                }
            },
            else => {},
        }

        return atom;
    }

    fn tryParseRepetition(self: *Parser, child: *AstNode) !?*AstNode {
        const saved_pos = self.tokenizer.pos;
        _ = self.tokenizer.next(); // consume {

        const min_val = self.parseNumber() orelse {
            self.tokenizer.pos = saved_pos;
            return null;
        };

        var max_val: u32 = min_val; // default: exact {n}

        const tok = self.tokenizer.peek();
        if (tok.kind == .comma) {
            _ = self.tokenizer.next(); // consume ,
            const next_tok = self.tokenizer.peek();
            if (next_tok.kind == .rbrace) {
                max_val = 0; // {n,} = unbounded
            } else {
                max_val = self.parseNumber() orelse {
                    self.tokenizer.pos = saved_pos;
                    return null;
                };
            }
        }

        if (self.tokenizer.peek().kind != .rbrace) {
            self.tokenizer.pos = saved_pos;
            return null;
        }
        _ = self.tokenizer.next(); // consume }

        const node = try self.allocator.create(AstNode);
        node.* = .{ .kind = .quantifier, .child = child, .min_rep = min_val, .max_rep = max_val };
        return node;
    }

    fn parseNumber(self: *Parser) ?u32 {
        var result: u32 = 0;
        var found = false;
        while (self.tokenizer.pos < self.tokenizer.source.len) {
            const c = self.tokenizer.source[self.tokenizer.pos];
            if (c >= '0' and c <= '9') {
                result = result * 10 + @as(u32, c - '0');
                self.tokenizer.pos += 1;
                found = true;
            } else break;
        }
        return if (found) result else null;
    }

    fn parseAtom(self: *Parser) error{OutOfMemory}!*AstNode {
        const tok = self.tokenizer.next();
        switch (tok.kind) {
            .literal => {
                const node = try self.allocator.create(AstNode);
                node.* = .{ .kind = .literal, .char = tok.char };
                return node;
            },
            .dot => {
                const node = try self.allocator.create(AstNode);
                node.* = .{ .kind = .dot };
                return node;
            },
            .caret => {
                const node = try self.allocator.create(AstNode);
                node.* = .{ .kind = .anchor_start };
                return node;
            },
            .dollar => {
                const node = try self.allocator.create(AstNode);
                node.* = .{ .kind = .anchor_end };
                return node;
            },
            .backslash_b => {
                const node = try self.allocator.create(AstNode);
                node.* = .{ .kind = .word_boundary };
                return node;
            },
            .backslash_d, .backslash_D => {
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .kind = .char_class,
                    .ranges = try self.allocator.dupe(CharRange, &.{.{ .low = '0', .high = '9' }}),
                    .negated = tok.kind == .backslash_D,
                };
                return node;
            },
            .backslash_w, .backslash_W => {
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .kind = .char_class,
                    .ranges = try self.allocator.dupe(CharRange, &.{
                        .{ .low = 'a', .high = 'z' },
                        .{ .low = 'A', .high = 'Z' },
                        .{ .low = '0', .high = '9' },
                        .{ .low = '_', .high = '_' },
                    }),
                    .negated = tok.kind == .backslash_W,
                };
                return node;
            },
            .backslash_s, .backslash_S => {
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .kind = .char_class,
                    .ranges = try self.allocator.dupe(CharRange, &.{
                        .{ .low = ' ', .high = ' ' },
                        .{ .low = '\t', .high = '\t' },
                        .{ .low = '\n', .high = '\n' },
                        .{ .low = '\r', .high = '\r' },
                    }),
                    .negated = tok.kind == .backslash_S,
                };
                return node;
            },
            .lparen => {
                const inner = try self.parseAlternation();
                const close = self.tokenizer.peek();
                if (close.kind == .rparen) {
                    _ = self.tokenizer.next(); // consume )
                }
                return inner;
            },
            .lbracket => {
                return try self.parseCharClass();
            },
            // Treat unexpected tokens as literal characters
            .lbrace => {
                const node = try self.allocator.create(AstNode);
                node.* = .{ .kind = .literal, .char = '{' };
                return node;
            },
            else => {
                // Fallback: treat as empty literal
                const node = try self.allocator.create(AstNode);
                node.* = .{ .kind = .literal, .char = 0 };
                return node;
            },
        }
    }

    fn parseCharClass(self: *Parser) !*AstNode {
        var ranges_list: std.ArrayList(CharRange) = .{};
        defer if (ranges_list.capacity > 0) ranges_list.deinit(self.allocator);

        var negated = false;
        if (self.tokenizer.pos < self.tokenizer.source.len and
            self.tokenizer.source[self.tokenizer.pos] == '^')
        {
            negated = true;
            self.tokenizer.pos += 1;
        }

        // Parse character class contents directly (bypass tokenizer for raw chars)
        while (self.tokenizer.pos < self.tokenizer.source.len) {
            const c = self.tokenizer.source[self.tokenizer.pos];
            if (c == ']') {
                self.tokenizer.pos += 1;
                break;
            }

            var ch: u8 = undefined;
            if (c == '\\' and self.tokenizer.pos + 1 < self.tokenizer.source.len) {
                self.tokenizer.pos += 1;
                const esc = self.tokenizer.source[self.tokenizer.pos];
                ch = switch (esc) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'd' => {
                        self.tokenizer.pos += 1;
                        try ranges_list.append(self.allocator, .{ .low = '0', .high = '9' });
                        continue;
                    },
                    'w' => {
                        self.tokenizer.pos += 1;
                        try ranges_list.append(self.allocator, .{ .low = 'a', .high = 'z' });
                        try ranges_list.append(self.allocator, .{ .low = 'A', .high = 'Z' });
                        try ranges_list.append(self.allocator, .{ .low = '0', .high = '9' });
                        try ranges_list.append(self.allocator, .{ .low = '_', .high = '_' });
                        continue;
                    },
                    's' => {
                        self.tokenizer.pos += 1;
                        try ranges_list.append(self.allocator, .{ .low = ' ', .high = ' ' });
                        try ranges_list.append(self.allocator, .{ .low = '\t', .high = '\t' });
                        try ranges_list.append(self.allocator, .{ .low = '\n', .high = '\n' });
                        continue;
                    },
                    else => esc,
                };
                self.tokenizer.pos += 1;
            } else {
                ch = c;
                self.tokenizer.pos += 1;
            }

            // Check for range: a-z
            if (self.tokenizer.pos + 1 < self.tokenizer.source.len and
                self.tokenizer.source[self.tokenizer.pos] == '-' and
                self.tokenizer.source[self.tokenizer.pos + 1] != ']')
            {
                self.tokenizer.pos += 1; // skip -
                var high: u8 = undefined;
                if (self.tokenizer.source[self.tokenizer.pos] == '\\' and
                    self.tokenizer.pos + 1 < self.tokenizer.source.len)
                {
                    self.tokenizer.pos += 1;
                    const esc = self.tokenizer.source[self.tokenizer.pos];
                    high = switch (esc) {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        else => esc,
                    };
                } else {
                    high = self.tokenizer.source[self.tokenizer.pos];
                }
                self.tokenizer.pos += 1;
                try ranges_list.append(self.allocator, .{ .low = ch, .high = high });
            } else {
                try ranges_list.append(self.allocator, .{ .low = ch, .high = ch });
            }
        }

        const node = try self.allocator.create(AstNode);
        node.* = .{
            .kind = .char_class,
            .ranges = try ranges_list.toOwnedSlice(self.allocator),
            .negated = negated,
        };
        return node;
    }
};

// ── NFA ──────────────────────────────────────────────────────────────
// Thompson NFA construction: guaranteed O(n) states for pattern of length n.

pub const NfaStateKind = enum {
    match_char, // match a specific character
    match_any, // match any char (.)
    match_class, // match character class
    split, // epsilon split to two states
    anchor_start, // match at start of line
    anchor_end, // match at end of line
    word_boundary, // match at word boundary
    accept, // match found
};

pub const NfaState = struct {
    kind: NfaStateKind,
    char: u8 = 0,
    ranges: []const CharRange = &.{},
    negated: bool = false,
    out1: u32 = NONE,
    out2: u32 = NONE, // only for split states
    class_lut: ?*const [256]bool = null, // Lookup table for fast character class matching

    pub const NONE: u32 = std.math.maxInt(u32);
};

pub const Nfa = struct {
    states: []NfaState,
    start: u32,
    epsilon_closures: ?[][]u64 = null, // epsilon_closures[state_idx] = bitset of reachable states via epsilon (splits only)
    is_one_pass: bool = false, // Optimization 3: True if NFA is deterministic (single path per input)

    pub fn deinit(self: *Nfa, allocator: std.mem.Allocator) void {
        // Free owned char class ranges and lookup tables
        for (self.states) |state| {
            if (state.kind == .match_class) {
                if (state.ranges.len > 0) {
                    allocator.free(state.ranges);
                }
                if (state.class_lut) |lut| {
                    allocator.destroy(lut);
                }
            }
        }

        // Free epsilon closures
        if (self.epsilon_closures) |closures| {
            for (closures) |closure| {
                allocator.free(closure);
            }
            allocator.free(closures);
        }

        allocator.free(self.states);
    }
};

/// Compile an AST into an NFA using Thompson construction.
pub const NfaCompiler = struct {
    states: std.ArrayList(NfaState),
    allocator: std.mem.Allocator,

    const Fragment = struct {
        start: u32,
        /// List of state indices whose out pointers need patching.
        patch_list: std.ArrayList(PatchEntry),
    };

    const PatchEntry = struct {
        state_idx: u32,
        which: enum { out1, out2 },
    };

    pub fn init(allocator: std.mem.Allocator) NfaCompiler {
        return .{
            .states = .{},
            .allocator = allocator,
        };
    }

    pub fn compile(self: *NfaCompiler, ast: *const AstNode) !Nfa {
        var frag = try self.compileNode(ast);

        // Add accept state
        const accept_idx: u32 = @intCast(self.states.items.len);
        try self.states.append(self.allocator, .{ .kind = .accept });

        // Patch all dangling outs to accept
        for (frag.patch_list.items) |entry| {
            switch (entry.which) {
                .out1 => self.states.items[entry.state_idx].out1 = accept_idx,
                .out2 => self.states.items[entry.state_idx].out2 = accept_idx,
            }
        }
        if (frag.patch_list.capacity > 0) frag.patch_list.deinit(self.allocator);

        return .{
            .states = try self.states.toOwnedSlice(self.allocator),
            .start = frag.start,
        };
    }

    fn addState(self: *NfaCompiler, state: NfaState) !u32 {
        const idx: u32 = @intCast(self.states.items.len);
        try self.states.append(self.allocator, state);
        return idx;
    }

    fn compileNode(self: *NfaCompiler, node: *const AstNode) error{OutOfMemory}!Fragment {
        return switch (node.kind) {
            .literal => try self.compileLiteral(node.char),
            .dot => try self.compileDot(),
            .char_class => try self.compileCharClass(node),
            .anchor_start => try self.compileAnchorStart(),
            .anchor_end => try self.compileAnchorEnd(),
            .word_boundary => try self.compileWordBoundary(),
            .concat => try self.compileConcat(node),
            .alternate => try self.compileAlternate(node),
            .quantifier => try self.compileQuantifier(node),
        };
    }

    fn compileLiteral(self: *NfaCompiler, char: u8) !Fragment {
        const idx = try self.addState(.{ .kind = .match_char, .char = char });
        var patch: std.ArrayList(PatchEntry) = .{};
        try patch.append(self.allocator, .{ .state_idx = idx, .which = .out1 });
        return .{ .start = idx, .patch_list = patch };
    }

    fn compileDot(self: *NfaCompiler) !Fragment {
        const idx = try self.addState(.{ .kind = .match_any });
        var patch: std.ArrayList(PatchEntry) = .{};
        try patch.append(self.allocator, .{ .state_idx = idx, .which = .out1 });
        return .{ .start = idx, .patch_list = patch };
    }

    fn compileCharClass(self: *NfaCompiler, node: *const AstNode) !Fragment {
        // Dupe ranges into the compiler's allocator so they outlive the AST arena
        const owned_ranges = try self.allocator.dupe(CharRange, node.ranges);

        // Pre-compute lookup table for all 256 bytes
        const lut = try self.allocator.create([256]bool);
        for (0..256) |byte_idx| {
            const byte: u8 = @intCast(byte_idx);
            var in_class = false;
            for (owned_ranges) |range| {
                if (byte >= range.low and byte <= range.high) {
                    in_class = true;
                    break;
                }
            }
            lut[byte_idx] = if (node.negated) !in_class else in_class;
        }

        const idx = try self.addState(.{
            .kind = .match_class,
            .ranges = owned_ranges,
            .negated = node.negated,
            .class_lut = lut,
        });
        var patch: std.ArrayList(PatchEntry) = .{};
        try patch.append(self.allocator, .{ .state_idx = idx, .which = .out1 });
        return .{ .start = idx, .patch_list = patch };
    }

    fn compileAnchorStart(self: *NfaCompiler) !Fragment {
        const idx = try self.addState(.{ .kind = .anchor_start });
        var patch: std.ArrayList(PatchEntry) = .{};
        try patch.append(self.allocator, .{ .state_idx = idx, .which = .out1 });
        return .{ .start = idx, .patch_list = patch };
    }

    fn compileAnchorEnd(self: *NfaCompiler) !Fragment {
        const idx = try self.addState(.{ .kind = .anchor_end });
        var patch: std.ArrayList(PatchEntry) = .{};
        try patch.append(self.allocator, .{ .state_idx = idx, .which = .out1 });
        return .{ .start = idx, .patch_list = patch };
    }

    fn compileWordBoundary(self: *NfaCompiler) !Fragment {
        const idx = try self.addState(.{ .kind = .word_boundary });
        var patch: std.ArrayList(PatchEntry) = .{};
        try patch.append(self.allocator, .{ .state_idx = idx, .which = .out1 });
        return .{ .start = idx, .patch_list = patch };
    }

    fn compileConcat(self: *NfaCompiler, node: *const AstNode) !Fragment {
        var left = try self.compileNode(node.left.?);
        const right = try self.compileNode(node.right.?);

        // Patch left's dangling outputs to right's start
        for (left.patch_list.items) |entry| {
            switch (entry.which) {
                .out1 => self.states.items[entry.state_idx].out1 = right.start,
                .out2 => self.states.items[entry.state_idx].out2 = right.start,
            }
        }
        if (left.patch_list.capacity > 0) left.patch_list.deinit(self.allocator);

        return .{ .start = left.start, .patch_list = right.patch_list };
    }

    fn compileAlternate(self: *NfaCompiler, node: *const AstNode) !Fragment {
        const left = try self.compileNode(node.left.?);
        const right = try self.compileNode(node.right.?);

        const split_idx = try self.addState(.{
            .kind = .split,
            .out1 = left.start,
            .out2 = right.start,
        });

        // Merge patch lists
        var merged: std.ArrayList(PatchEntry) = .{};
        try merged.appendSlice(self.allocator, left.patch_list.items);
        try merged.appendSlice(self.allocator, right.patch_list.items);
        if (left.patch_list.capacity > 0) @constCast(&left.patch_list).deinit(self.allocator);
        if (right.patch_list.capacity > 0) @constCast(&right.patch_list).deinit(self.allocator);

        return .{ .start = split_idx, .patch_list = merged };
    }

    fn compileQuantifier(self: *NfaCompiler, node: *const AstNode) !Fragment {
        const child_node = node.child.?;
        const min = node.min_rep;
        const max = node.max_rep;

        // Special cases for common quantifiers
        if (min == 0 and max == 0) {
            // * (zero or more)
            return try self.compileStar(child_node);
        } else if (min == 1 and max == 0) {
            // + (one or more)
            return try self.compilePlus(child_node);
        } else if (min == 0 and max == 1) {
            // ? (zero or one)
            return try self.compileQuestion(child_node);
        } else {
            // General {n,m} repetition
            return try self.compileRepetition(child_node, min, max);
        }
    }

    fn compileStar(self: *NfaCompiler, child: *const AstNode) !Fragment {
        var body = try self.compileNode(child);

        const split_idx = try self.addState(.{
            .kind = .split,
            .out1 = body.start,
            // out2 will be patched to whatever follows
        });

        // Patch body's exits back to split (loop)
        for (body.patch_list.items) |entry| {
            switch (entry.which) {
                .out1 => self.states.items[entry.state_idx].out1 = split_idx,
                .out2 => self.states.items[entry.state_idx].out2 = split_idx,
            }
        }
        if (body.patch_list.capacity > 0) body.patch_list.deinit(self.allocator);

        var patch: std.ArrayList(PatchEntry) = .{};
        try patch.append(self.allocator, .{ .state_idx = split_idx, .which = .out2 });

        return .{ .start = split_idx, .patch_list = patch };
    }

    fn compilePlus(self: *NfaCompiler, child: *const AstNode) !Fragment {
        var body = try self.compileNode(child);

        const split_idx = try self.addState(.{
            .kind = .split,
            .out1 = body.start,
            // out2 patched to next
        });

        // Patch body's exits to split
        for (body.patch_list.items) |entry| {
            switch (entry.which) {
                .out1 => self.states.items[entry.state_idx].out1 = split_idx,
                .out2 => self.states.items[entry.state_idx].out2 = split_idx,
            }
        }
        if (body.patch_list.capacity > 0) body.patch_list.deinit(self.allocator);

        var patch: std.ArrayList(PatchEntry) = .{};
        try patch.append(self.allocator, .{ .state_idx = split_idx, .which = .out2 });

        return .{ .start = body.start, .patch_list = patch };
    }

    fn compileQuestion(self: *NfaCompiler, child: *const AstNode) !Fragment {
        const body = try self.compileNode(child);

        const split_idx = try self.addState(.{
            .kind = .split,
            .out1 = body.start,
            // out2 patched to next
        });

        var patch: std.ArrayList(PatchEntry) = .{};
        try patch.append(self.allocator, .{ .state_idx = split_idx, .which = .out2 });
        try patch.appendSlice(self.allocator, body.patch_list.items);
        if (body.patch_list.capacity > 0) @constCast(&body.patch_list).deinit(self.allocator);

        return .{ .start = split_idx, .patch_list = patch };
    }

    fn compileRepetition(self: *NfaCompiler, child: *const AstNode, min: u32, max: u32) !Fragment {
        // {n,m}: concat n required copies, then (m-n) optional copies
        // {n,}: concat n required copies, then one star

        if (min == 0 and max == 0) return try self.compileStar(child);

        var result_start: ?u32 = null;
        var prev_patch: ?std.ArrayList(PatchEntry) = null;
        var all_optional_patches: std.ArrayList(PatchEntry) = .{};

        // Emit `min` required copies
        for (0..min) |_| {
            const copy = try self.compileNode(child);
            if (prev_patch) |*pp| {
                for (pp.items) |entry| {
                    switch (entry.which) {
                        .out1 => self.states.items[entry.state_idx].out1 = copy.start,
                        .out2 => self.states.items[entry.state_idx].out2 = copy.start,
                    }
                }
                pp.deinit(self.allocator);
            }
            if (result_start == null) result_start = copy.start;
            prev_patch = copy.patch_list;
        }

        if (max == 0) {
            // {n,} — min copies then star
            const star = try self.compileStar(child);
            if (prev_patch) |*pp| {
                for (pp.items) |entry| {
                    switch (entry.which) {
                        .out1 => self.states.items[entry.state_idx].out1 = star.start,
                        .out2 => self.states.items[entry.state_idx].out2 = star.start,
                    }
                }
                pp.deinit(self.allocator);
            }
            if (result_start == null) result_start = star.start;
            if (all_optional_patches.capacity > 0) all_optional_patches.deinit(self.allocator);
            return .{ .start = result_start.?, .patch_list = star.patch_list };
        }

        // {n,m} — emit (max - min) optional copies
        const optional_count = max - min;
        for (0..optional_count) |_| {
            const copy = try self.compileNode(child);
            const split_idx = try self.addState(.{
                .kind = .split,
                .out1 = copy.start,
            });

            if (prev_patch) |*pp| {
                for (pp.items) |entry| {
                    switch (entry.which) {
                        .out1 => self.states.items[entry.state_idx].out1 = split_idx,
                        .out2 => self.states.items[entry.state_idx].out2 = split_idx,
                    }
                }
                pp.deinit(self.allocator);
            }
            if (result_start == null) result_start = split_idx;

            try all_optional_patches.append(self.allocator, .{ .state_idx = split_idx, .which = .out2 });
            prev_patch = copy.patch_list;
        }

        // Merge remaining patches
        if (prev_patch) |*pp| {
            try all_optional_patches.appendSlice(self.allocator, pp.items);
            pp.deinit(self.allocator);
        }

        return .{ .start = result_start orelse 0, .patch_list = all_optional_patches };
    }
};

// ── NFA Executor (Thompson simulation) ───────────────────────────────

pub const NfaExecutor = struct {
    nfa: *const Nfa,

    pub fn init(nfa: *const Nfa) NfaExecutor {
        return .{ .nfa = nfa };
    }

    /// Check if the NFA matches anywhere in the text (unanchored search).
    /// Uses two sets of states and alternates between them.
    pub fn isMatch(self: *const NfaExecutor, text: []const u8, allocator: std.mem.Allocator) !bool {
        const num_states = self.nfa.states.len;
        if (num_states == 0) return false;

        // Bitset for current and next state sets
        const set_size = (num_states + 63) / 64;
        var current_buf = try allocator.alloc(u64, set_size);
        defer allocator.free(current_buf);
        var next_buf = try allocator.alloc(u64, set_size);
        defer allocator.free(next_buf);

        // Try matching starting at each position (unanchored)
        for (0..text.len + 1) |start_pos| {
            @memset(current_buf, 0);
            self.addState(current_buf, self.nfa.start, text, start_pos);

            var matched = false;

            // Check if we already matched without consuming input
            for (0..num_states) |si| {
                if (self.getBit(current_buf, @intCast(si))) {
                    if (self.nfa.states[si].kind == .accept) {
                        matched = true;
                        break;
                    }
                }
            }
            if (matched) return true;

            var pos = start_pos;
            while (pos < text.len) {
                @memset(next_buf, 0);
                const ch = text[pos];

                for (0..num_states) |si| {
                    if (!self.getBit(current_buf, @intCast(si))) continue;

                    const state = &self.nfa.states[si];
                    switch (state.kind) {
                        .match_char => {
                            if (ch == state.char) {
                                self.addState(next_buf, state.out1, text, pos + 1);
                            }
                        },
                        .match_any => {
                            if (ch != '\n') {
                                self.addState(next_buf, state.out1, text, pos + 1);
                            }
                        },
                        .match_class => {
                            const matches = if (state.class_lut) |lut| lut[ch] else matchCharClass(ch, state.ranges, state.negated);
                            if (matches) {
                                self.addState(next_buf, state.out1, text, pos + 1);
                            }
                        },
                        .split, .accept, .anchor_start, .anchor_end, .word_boundary => {
                            // These are handled in addState (epsilon transitions)
                        },
                    }
                }

                // Swap current and next
                const tmp = current_buf;
                current_buf = next_buf;
                next_buf = tmp;

                // Check for accept state
                for (0..num_states) |si| {
                    if (self.getBit(current_buf, @intCast(si))) {
                        if (self.nfa.states[si].kind == .accept) return true;
                    }
                }

                pos += 1;
            }
        }

        return false;
    }

    /// Add a state and follow all epsilon transitions (split, anchors).
    fn addState(self: *const NfaExecutor, set: []u64, state_idx: u32, text: []const u8, pos: usize) void {
        if (state_idx == NfaState.NONE) return;
        if (state_idx >= self.nfa.states.len) return;
        if (self.getBit(set, state_idx)) return; // already in set

        self.setBit(set, state_idx);

        const state = &self.nfa.states[state_idx];
        switch (state.kind) {
            .split => {
                self.addState(set, state.out1, text, pos);
                self.addState(set, state.out2, text, pos);
            },
            .anchor_start => {
                if (pos == 0 or (pos > 0 and text[pos - 1] == '\n')) {
                    self.addState(set, state.out1, text, pos);
                }
            },
            .anchor_end => {
                if (pos >= text.len or text[pos] == '\n') {
                    self.addState(set, state.out1, text, pos);
                }
            },
            .word_boundary => {
                const before_word = pos > 0 and isWordChar(text[pos - 1]);
                const after_word = pos < text.len and isWordChar(text[pos]);
                if (before_word != after_word) {
                    self.addState(set, state.out1, text, pos);
                }
            },
            else => {},
        }
    }

    inline fn getBit(self: *const NfaExecutor, set: []const u64, idx: u32) bool {
        _ = self;
        return (set[idx / 64] >> @intCast(idx % 64)) & 1 == 1;
    }

    inline fn setBit(self: *const NfaExecutor, set: []u64, idx: u32) void {
        _ = self;
        set[idx / 64] |= @as(u64, 1) << @intCast(idx % 64);
    }
};

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

// ── High-level Regex API ─────────────────────────────────────────────

/// Add a state and follow epsilon transitions (split, anchors)
/// Doesn't allocate - uses passed buffer and NFA reference
fn addStateNoAlloc(set: []u64, nfa: *const Nfa, state_idx: u32, text: []const u8, pos: usize) void {
    if (state_idx == NfaState.NONE) return;
    if (state_idx >= nfa.states.len) return;
    if (getBit(set, state_idx)) return; // already in set

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

/// Extract required literal prefix/infix from AST (Optimization 1)
/// Returns longest literal substring that must appear for pattern to match
fn extractRequiredLiterals(ast: *const AstNode, allocator: std.mem.Allocator) ?[]const u8 {
    // Collect all literals from the leftmost prefix of the concatenation tree.
    // The parser produces left-associative trees: concat(concat(concat(a, b), c), d)
    // We flatten this by recursively descending into left concats, collecting literals.
    var literal_buf: std.ArrayList(u8) = .{};

    collectLiteralPrefix(ast, &literal_buf, allocator);

    if (literal_buf.items.len > 0) {
        return literal_buf.toOwnedSlice(allocator) catch {
            if (literal_buf.capacity > 0) literal_buf.deinit(allocator);
            return null;
        };
    }

    // Nothing extracted — clean up
    if (literal_buf.capacity > 0) literal_buf.deinit(allocator);
    return null;
}

/// Recursively collect the literal prefix from a left-associative concat tree.
/// Stops at the first non-literal node (dot, class, quantifier, etc.).
fn collectLiteralPrefix(node: *const AstNode, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) void {
    switch (node.kind) {
        .literal => {
            buf.append(allocator, node.char) catch return;
        },
        .concat => {
            if (node.left) |left| {
                collectLiteralPrefix(left, buf, allocator);
            }
            // Only continue to right if left was fully literal
            if (node.left) |left| {
                if (isFullyLiteral(left)) {
                    if (node.right) |right| {
                        collectLiteralPrefix(right, buf, allocator);
                    }
                }
            }
        },
        else => {},
    }
}

/// Check if a node and all its descendants are pure literals or literal concats.
fn isFullyLiteral(node: *const AstNode) bool {
    return switch (node.kind) {
        .literal => true,
        .concat => {
            const left_ok = if (node.left) |l| isFullyLiteral(l) else true;
            const right_ok = if (node.right) |r| isFullyLiteral(r) else true;
            return left_ok and right_ok;
        },
        else => false,
    };
}

/// Extract literal alternatives from a top-level alternation pattern.
/// For patterns like "error|warn|fatal", returns ["error", "warn", "fatal"].
/// Returns null if the pattern is not a pure alternation of literals.
fn extractAlternationLiterals(ast: *const AstNode, allocator: std.mem.Allocator) ?[][]const u8 {
    // Must be an alternation at root
    if (ast.kind != .alternate) return null;

    // Count alternatives first
    var count: usize = 0;
    countAlternatives(ast, &count);
    if (count < 2) return null;

    // Collect all literal branches
    var literals = allocator.alloc([]const u8, count) catch return null;
    var idx: usize = 0;
    if (!collectAlternativeLiterals(ast, allocator, literals, &idx)) {
        // Not all branches are pure literals — free and return null
        for (literals[0..idx]) |lit| allocator.free(lit);
        allocator.free(literals);
        return null;
    }

    return literals;
}

fn countAlternatives(node: *const AstNode, count: *usize) void {
    if (node.kind == .alternate) {
        if (node.left) |left| countAlternatives(left, count);
        if (node.right) |right| countAlternatives(right, count);
    } else {
        count.* += 1;
    }
}

/// Collect literal strings from each branch of an alternation tree.
/// Returns false if any branch is not a pure literal.
fn collectAlternativeLiterals(
    node: *const AstNode,
    allocator: std.mem.Allocator,
    out: [][]const u8,
    idx: *usize,
) bool {
    if (node.kind == .alternate) {
        if (node.left) |left| {
            if (!collectAlternativeLiterals(left, allocator, out, idx)) return false;
        }
        if (node.right) |right| {
            if (!collectAlternativeLiterals(right, allocator, out, idx)) return false;
        }
        return true;
    }

    // This branch must be a pure literal (single char or concat of literals)
    if (!isFullyLiteral(node)) return false;

    // Extract the literal string
    var buf: std.ArrayList(u8) = .{};
    collectAllChars(node, &buf, allocator);
    if (buf.items.len == 0) {
        if (buf.capacity > 0) buf.deinit(allocator);
        return false;
    }

    const owned = buf.toOwnedSlice(allocator) catch {
        if (buf.capacity > 0) buf.deinit(allocator);
        return false;
    };

    if (idx.* < out.len) {
        out[idx.*] = owned;
        idx.* += 1;
        return true;
    }
    allocator.free(owned);
    return false;
}

fn collectAllChars(node: *const AstNode, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) void {
    switch (node.kind) {
        .literal => buf.append(allocator, node.char) catch {},
        .concat => {
            if (node.left) |left| collectAllChars(left, buf, allocator);
            if (node.right) |right| collectAllChars(right, buf, allocator);
        },
        else => {},
    }
}

// Inner literal extraction (TODO: implement safely for patterns like \d+\.\d+)

fn extractInnerLiteral(ast: *const AstNode, allocator: std.mem.Allocator) ?[]const u8 {
    var best_buf: std.ArrayList(u8) = .{};
    var current_buf: std.ArrayList(u8) = .{};

    collectAllLiteralRuns(ast, &best_buf, &current_buf, allocator);

    // Flush last run
    if (current_buf.items.len > best_buf.items.len) {
        if (best_buf.capacity > 0) best_buf.deinit(allocator);
        best_buf = current_buf;
    } else {
        if (current_buf.capacity > 0) current_buf.deinit(allocator);
    }

    if (best_buf.items.len > 0) {
        return best_buf.toOwnedSlice(allocator) catch {
            if (best_buf.capacity > 0) best_buf.deinit(allocator);
            return null;
        };
    }
    if (best_buf.capacity > 0) best_buf.deinit(allocator);
    return null;
}

/// Walk the AST in-order collecting literal runs. Keeps track of the best (longest) run.
fn collectAllLiteralRuns(
    node: *const AstNode,
    best: *std.ArrayList(u8),
    current: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) void {
    switch (node.kind) {
        .literal => {
            current.append(allocator, node.char) catch return;
        },
        .concat => {
            if (node.left) |left| {
                collectAllLiteralRuns(left, best, current, allocator);
            }
            if (node.right) |right| {
                collectAllLiteralRuns(right, best, current, allocator);
            }
        },
        else => {
            // Non-literal: flush current run if it's the longest so far
            if (current.items.len > best.items.len) {
                // Swap current into best
                const tmp_items = best.items;
                const tmp_cap = best.capacity;
                best.items = current.items;
                best.capacity = current.capacity;
                current.items = tmp_items;
                current.capacity = tmp_cap;
            }
            current.items.len = 0; // reset current run (keep capacity)
            // Recurse into children of quantifiers etc.
            if (node.child) |child| {
                collectAllLiteralRuns(child, best, current, allocator);
                // Flush after child
                if (current.items.len > best.items.len) {
                    const tmp_items = best.items;
                    const tmp_cap = best.capacity;
                    best.items = current.items;
                    best.capacity = current.capacity;
                    current.items = tmp_items;
                    current.capacity = tmp_cap;
                }
                current.items.len = 0;
            }
            // Also recurse into left/right for alternation
            if (node.kind == .alternate) {
                // For alternations, we can't use inner literals (either branch might not have it)
                // Just flush
                if (current.items.len > best.items.len) {
                    const tmp_items = best.items;
                    const tmp_cap = best.capacity;
                    best.items = current.items;
                    best.capacity = current.capacity;
                    current.items = tmp_items;
                    current.capacity = tmp_cap;
                }
                current.items.len = 0;
            }
        },
    }
}

/// Detect if NFA is one-pass (deterministic): for each state + input byte,
/// there is at most one possible next state. This allows a fast single-pointer path
/// instead of bitset operations.
fn detectOnePass(nfa: *const Nfa) bool {
    // Conservative check: only simple patterns are truly deterministic
    // We check if any state has conflicting transitions (multiple matches for same input)
    for (nfa.states) |state| {
        switch (state.kind) {
            .split => {
                // Split states introduce non-determinism (can't be one-pass)
                return false;
            },
            .match_char => {
                // Check for duplicate character matches (conflict)
                // This would require checking against other states with same char
                // For now, allow it (will be refined in later iterations)
            },
            else => {},
        }
    }

    // Additional check: if there are epsilon closures with size > 1, it's non-deterministic
    // But since we're checking split states above, this is implicit
    return true;
}

/// Compute epsilon closures for each NFA state.
/// epsilon_closures[state_idx] contains a bitset of all states reachable from state_idx
/// via only split transitions (not including anchors/word boundaries, which are position-dependent).
fn computeEpsilonClosures(allocator: std.mem.Allocator, nfa: *Nfa) !void {
    const num_states = nfa.states.len;
    const set_size = (num_states + 63) / 64;

    // Allocate array of bitsets
    var closures = try allocator.alloc([]u64, num_states);
    errdefer allocator.free(closures);

    // For each state, compute its epsilon closure
    for (0..num_states) |state_idx| {
        const closure = try allocator.alloc(u64, set_size);
        errdefer allocator.free(closure);
        @memset(closure, 0);

        // Recursively add all states reachable via splits
        computeEpsilonClosureHelper(closure, nfa, @intCast(state_idx), set_size);

        closures[state_idx] = closure;
    }

    nfa.epsilon_closures = closures;
}

/// Helper function to compute epsilon closure via recursion on split transitions.
fn computeEpsilonClosureHelper(closure: []u64, nfa: *const Nfa, state_idx: u32, set_size: usize) void {
    if (state_idx == NfaState.NONE or state_idx >= nfa.states.len) return;

    // Check if already in closure
    const word_idx = state_idx / 64;
    const bit_idx: u6 = @intCast(state_idx % 64);
    if ((closure[word_idx] >> bit_idx) & 1 == 1) return;

    // Add this state
    closure[word_idx] |= @as(u64, 1) << bit_idx;

    const state = &nfa.states[state_idx];

    // Only follow split transitions (not anchors/word boundaries)
    if (state.kind == .split) {
        computeEpsilonClosureHelper(closure, nfa, state.out1, set_size);
        computeEpsilonClosureHelper(closure, nfa, state.out2, set_size);
    }
}

pub const Regex = struct {
    pattern: []const u8,
    nfa: Nfa,
    is_literal: bool,
    literal_str: []const u8,
    required_literal: ?[]const u8,
    /// Literal alternatives extracted from top-level alternations (e.g. "error|warn|fatal").
    /// Non-null when the pattern is a pure alternation of literals.
    alternation_literals: ?[][]const u8 = null,
    allocator: std.mem.Allocator,
    byte_classes: [256]u8 = undefined, // Maps byte -> equivalence class ID
    num_classes: u16 = 256, // Number of distinct byte equivalence classes

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        // Detect if pattern is purely literal (no metacharacters)
        const lit = extractPureLiteral(pattern);

        // Use an arena for temporary AST nodes — freed after NFA compilation.
        // Only the NFA states survive; all AST allocations are bulk-freed.
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var parser = Parser.init(arena, pattern);
        const ast = try parser.parse();

        // Extract required literals for optimization.
        // First try prefix literals (best: enables skipping from file start).
        // Fall back to inner literals (e.g. the '.' in \d+\.\d+) for prefiltering.
        const req_lit = extractRequiredLiterals(ast, allocator) orelse
            extractInnerLiteral(ast, allocator);

        // Extract alternation literals (e.g. "error|warn|fatal" -> ["error", "warn", "fatal"])
        const alt_lits = extractAlternationLiterals(ast, allocator);

        // NFA compiler uses the real allocator since NFA states must outlive compile()
        var compiler = NfaCompiler.init(allocator);
        var nfa = try compiler.compile(ast);

        // Optimization 3: Detect if NFA is one-pass
        nfa.is_one_pass = detectOnePass(&nfa);

        // Compute epsilon closures for optimization
        try computeEpsilonClosures(allocator, &nfa);

        // Compute byte equivalence classes for DFA optimization
        var byte_classes: [256]u8 = undefined;
        var num_classes: u16 = 0;
        _ = computeByteClasses(&nfa, &byte_classes, &num_classes);

        return .{
            .pattern = pattern,
            .nfa = nfa,
            .is_literal = lit != null,
            .literal_str = lit orelse "",
            .required_literal = req_lit,
            .alternation_literals = alt_lits,
            .allocator = allocator,
            .byte_classes = byte_classes,
            .num_classes = num_classes,
        };
    }

    pub fn deinit(self: *Regex, allocator: std.mem.Allocator) void {
        self.nfa.deinit(allocator);
        if (self.required_literal) |lit| {
            allocator.free(lit);
        }
        if (self.alternation_literals) |lits| {
            for (lits) |lit| allocator.free(lit);
            allocator.free(lits);
        }
    }

    /// Check if pattern matches anywhere in text.
    /// For thread-safe cached matching, use isMatchDfa() with a per-thread LazyDfa.
    pub fn isMatch(self: *const Regex, text: []const u8) !bool {
        // Fast path: pure literal patterns use direct search
        if (self.is_literal) {
            return std.mem.indexOf(u8, text, self.literal_str) != null;
        }

        const num_states = self.nfa.states.len;
        if (num_states == 0) return false;

        // Optimization 1: If we have a required literal, use SIMD to find candidates first
        if (self.required_literal) |literal| {
            if (std.mem.indexOf(u8, text, literal) == null) {
                return false; // Literal not found, pattern can't match
            }
        }

        return self.isMatchNfa(text, self.allocator);
    }

    /// Check if pattern matches using a lazy DFA cache for acceleration.
    /// The DFA caches NFA state-set transitions so repeated state configurations
    /// (common in text search) skip NFA simulation entirely.
    /// The caller owns the LazyDfa and can reuse it across multiple isMatchDfa calls
    /// (e.g., across all lines in a file). This is the primary optimization for grep.
    pub fn isMatchDfa(self: *const Regex, text: []const u8, dfa: *lazy_dfa_mod.LazyDfa) !bool {
        // Fast path: pure literal patterns use direct search
        if (self.is_literal) {
            return std.mem.indexOf(u8, text, self.literal_str) != null;
        }

        const num_states = self.nfa.states.len;
        if (num_states == 0) return false;

        // Optimization 1: If we have a required literal, use SIMD to find candidates first
        if (self.required_literal) |literal| {
            if (std.mem.indexOf(u8, text, literal) == null) {
                return false;
            }
        }

        return dfa.isMatch(text);
    }

    /// Create a lazy DFA instance for this regex. Caller owns and must deinit.
    /// Use with isMatchDfa() for cached matching across multiple texts.
    /// Optimization 2: Uses required_literal for prefiltering if available.
    pub fn createDfa(self: *const Regex, allocator: std.mem.Allocator) !lazy_dfa_mod.LazyDfa {
        return lazy_dfa_mod.LazyDfa.initWithLiteral(allocator, &self.nfa, &self.byte_classes, self.num_classes, self.required_literal);
    }

    /// Plain NFA simulation (baseline, no caching).
    fn isMatchNfa(self: *const Regex, text: []const u8, allocator: std.mem.Allocator) !bool {
        const num_states = self.nfa.states.len;
        if (num_states == 0) return false;

        const set_size = (num_states + 63) / 64;
        var current_buf = try allocator.alloc(u64, set_size);
        defer allocator.free(current_buf);
        var next_buf = try allocator.alloc(u64, set_size);
        defer allocator.free(next_buf);

        @memset(current_buf, 0);
        addStateNoAlloc(current_buf, &self.nfa, self.nfa.start, text, 0);

        for (0..num_states) |si| {
            if (getBit(current_buf, @intCast(si))) {
                if (self.nfa.states[si].kind == .accept) {
                    return true;
                }
            }
        }

        for (0..text.len) |pos| {
            @memset(next_buf, 0);
            const ch = text[pos];

            for (0..num_states) |si| {
                if (!getBit(current_buf, @intCast(si))) continue;

                const state = &self.nfa.states[si];
                switch (state.kind) {
                    .match_char => {
                        if (ch == state.char) {
                            addStateNoAlloc(next_buf, &self.nfa, state.out1, text, pos + 1);
                        }
                    },
                    .match_any => {
                        if (ch != '\n') {
                            addStateNoAlloc(next_buf, &self.nfa, state.out1, text, pos + 1);
                        }
                    },
                    .match_class => {
                        const matches = if (state.class_lut) |lut| lut[ch] else matchCharClass(ch, state.ranges, state.negated);
                        if (matches) {
                            addStateNoAlloc(next_buf, &self.nfa, state.out1, text, pos + 1);
                        }
                    },
                    .split, .accept, .anchor_start, .anchor_end, .word_boundary => {},
                }
            }

            addStateNoAlloc(next_buf, &self.nfa, self.nfa.start, text, pos + 1);

            const tmp = current_buf;
            current_buf = next_buf;
            next_buf = tmp;

            for (0..num_states) |si| {
                if (getBit(current_buf, @intCast(si))) {
                    if (self.nfa.states[si].kind == .accept) {
                        return true;
                    }
                }
            }
        }

        return false;
    }

    /// Check if this is a pure literal pattern (for SIMD dispatch).
    pub fn isPureLiteral(self: *const Regex) bool {
        return self.is_literal;
    }

    /// Get the literal string if this is a pure literal pattern.
    pub fn getLiteral(self: *const Regex) ?[]const u8 {
        return if (self.is_literal) self.literal_str else null;
    }

    /// Extract required literal strings from the regex pattern.
    /// Used for pre-filtering files before running the full regex.
    pub fn extractLiterals(self: *const Regex) []const []const u8 {
        _ = self;
        // TODO: implement literal extraction from regex AST for trigram integration
        return &.{};
    }
};

/// Detect if a pattern contains no regex metacharacters (pure literal).
fn extractPureLiteral(pattern: []const u8) ?[]const u8 {
    for (pattern) |c| {
        switch (c) {
            '.', '*', '+', '?', '|', '(', ')', '[', ']', '{', '}', '^', '$', '\\' => return null,
            else => {},
        }
    }
    return if (pattern.len > 0) pattern else null;
}

/// Compute byte equivalence classes for DFA optimization.
/// Two bytes are equivalent if they behave identically across all NFA states.
/// This reduces the DFA transition table from 256 entries to num_classes entries.
fn computeByteClasses(nfa: *const Nfa, byte_classes: *[256]u8, num_classes: *u16) void {
    // Initialize all bytes in class 0
    for (0..256) |i| {
        byte_classes[i] = 0;
    }
    var next_class: u8 = 1;

    // For each NFA state, refine the classes based on its matching behavior
    for (nfa.states) |state| {
        switch (state.kind) {
            .match_char => {
                // Split class containing state.char into its own class
                const char_byte = state.char;
                const old_class = byte_classes[char_byte];
                for (0..256) |i| {
                    if (i == char_byte and byte_classes[i] == old_class) {
                        byte_classes[i] = next_class;
                    }
                }
                next_class += 1;
            },
            .match_class => {
                // Split classes at range boundaries using the LUT (from opt #1)
                if (state.class_lut) |lut| {
                    // Refine classes based on the LUT values
                    var split_map: [256]u8 = undefined;
                    @memset(&split_map, 0);
                    var num_splits: u8 = 1;

                    for (0..256) |i| {
                        const byte_idx: u8 = @intCast(i);
                        const old_class = byte_classes[byte_idx];
                        const in_class = lut[i];

                        // Create new class for bytes in this class with different membership
                        var found_split = false;
                        for (0..num_splits) |s| {
                            const split_idx: u8 = @intCast(s);
                            if (split_map[split_idx] == old_class) {
                                // Check if this split has consistent membership
                                if ((split_map[split_idx + 1] & 1) == (if (in_class) @as(u8, 1) else 0)) {
                                    found_split = true;
                                    break;
                                }
                            }
                        }

                        if (!found_split and num_splits < 255) {
                            split_map[num_splits] = old_class;
                            split_map[num_splits + 1] = if (in_class) 1 else 0;
                            num_splits += 1;
                        }
                    }

                    // Assign new classes based on splits
                    for (0..256) |i| {
                        const byte_idx: u8 = @intCast(i);
                        const old_class = byte_classes[byte_idx];
                        const in_class = lut[i];

                        for (0..num_splits) |s| {
                            const split_idx: u8 = @intCast(s);
                            if (split_map[split_idx] == old_class and
                                (split_map[split_idx + 1] & 1) == (if (in_class) @as(u8, 1) else 0)) {
                                byte_classes[i] = split_idx + 1;
                                break;
                            }
                        }
                    }

                    next_class = @intCast(@as(u16, num_splits) + 1);
                }
            },
            .match_any => {
                // Split '\n' into its own class
                const newline_class = byte_classes['\n'];
                for (0..256) |i| {
                    if (i == '\n' and byte_classes[i] == newline_class) {
                        byte_classes[i] = next_class;
                    }
                }
                next_class += 1;
            },
            else => {},
        }
    }

    num_classes.* = next_class;
}

// ── Tests ────────────────────────────────────────────────────────────

test "tokenizer basic" {
    var t = Tokenizer.init("ab.c*");
    try std.testing.expectEqual(TokenKind.literal, t.next().kind);
    try std.testing.expectEqual(TokenKind.literal, t.next().kind);
    try std.testing.expectEqual(TokenKind.dot, t.next().kind);
    try std.testing.expectEqual(TokenKind.literal, t.next().kind);
    try std.testing.expectEqual(TokenKind.star, t.next().kind);
    try std.testing.expectEqual(TokenKind.eof, t.next().kind);
}

test "tokenizer escape sequences" {
    var t = Tokenizer.init("\\d\\w\\.");
    try std.testing.expectEqual(TokenKind.backslash_d, t.next().kind);
    try std.testing.expectEqual(TokenKind.backslash_w, t.next().kind);
    const dot_tok = t.next();
    try std.testing.expectEqual(TokenKind.literal, dot_tok.kind);
    try std.testing.expectEqual(@as(u8, '.'), dot_tok.char);
}

test "parse and compile simple literal" {
    var re = try Regex.compile(std.testing.allocator, "abc");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(re.is_literal);
    try std.testing.expect(try re.isMatch("xabcy"));
    try std.testing.expect(!try re.isMatch("xaby"));
}

test "regex dot matches any" {
    var re = try Regex.compile(std.testing.allocator, "a.c");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("abc"));
    try std.testing.expect(try re.isMatch("axc"));
    try std.testing.expect(!try re.isMatch("ac"));
}

test "regex star quantifier" {
    var re = try Regex.compile(std.testing.allocator, "ab*c");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("ac"));
    try std.testing.expect(try re.isMatch("abc"));
    try std.testing.expect(try re.isMatch("abbbc"));
    try std.testing.expect(!try re.isMatch("adc"));
}

test "regex plus quantifier" {
    var re = try Regex.compile(std.testing.allocator, "ab+c");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(!try re.isMatch("ac"));
    try std.testing.expect(try re.isMatch("abc"));
    try std.testing.expect(try re.isMatch("abbbc"));
}

test "regex alternation" {
    var re = try Regex.compile(std.testing.allocator, "cat|dog");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("I have a cat"));
    try std.testing.expect(try re.isMatch("I have a dog"));
    try std.testing.expect(!try re.isMatch("I have a bird"));
}

test "regex character class" {
    var re = try Regex.compile(std.testing.allocator, "[aeiou]+");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("hello"));
    try std.testing.expect(!try re.isMatch("xyz"));
}

test "regex character range" {
    var re = try Regex.compile(std.testing.allocator, "[a-z]+");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("hello"));
    try std.testing.expect(!try re.isMatch("12345"));
}

test "regex negated class" {
    var re = try Regex.compile(std.testing.allocator, "[^0-9]+");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("hello"));
    // "12345" — the [^0-9]+ requires at least one non-digit
    try std.testing.expect(!try re.isMatch("12345"));
}

test "regex shorthand classes" {
    var re_d = try Regex.compile(std.testing.allocator, "\\d+");
    defer re_d.deinit(std.testing.allocator);
    try std.testing.expect(try re_d.isMatch("abc123"));

    var re_w = try Regex.compile(std.testing.allocator, "\\w+");
    defer re_w.deinit(std.testing.allocator);
    try std.testing.expect(try re_w.isMatch("hello_world"));

    var re_s = try Regex.compile(std.testing.allocator, "\\s+");
    defer re_s.deinit(std.testing.allocator);
    try std.testing.expect(try re_s.isMatch("hello world"));
}

test "regex anchors" {
    var re_start = try Regex.compile(std.testing.allocator, "^hello");
    defer re_start.deinit(std.testing.allocator);
    try std.testing.expect(try re_start.isMatch("hello world"));
    try std.testing.expect(!try re_start.isMatch("say hello"));

    var re_end = try Regex.compile(std.testing.allocator, "world$");
    defer re_end.deinit(std.testing.allocator);
    try std.testing.expect(try re_end.isMatch("hello world"));
    try std.testing.expect(!try re_end.isMatch("world hello"));
}

test "regex question mark" {
    var re = try Regex.compile(std.testing.allocator, "colou?r");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("color"));
    try std.testing.expect(try re.isMatch("colour"));
}

test "regex repetition {n,m}" {
    var re = try Regex.compile(std.testing.allocator, "a{2,4}");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(!try re.isMatch("a"));
    try std.testing.expect(try re.isMatch("aa"));
    try std.testing.expect(try re.isMatch("aaa"));
    try std.testing.expect(try re.isMatch("aaaa"));
    try std.testing.expect(try re.isMatch("aaaaa")); // matches first 4
}

test "regex practical: function signature" {
    var re = try Regex.compile(std.testing.allocator, "fn\\s+\\w+\\(");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("pub fn init(allocator: Allocator) void {"));
    try std.testing.expect(try re.isMatch("fn main() !void {"));
    try std.testing.expect(!try re.isMatch("const fn_name = 42;"));
}

test "regex practical: import statement" {
    // Pattern: import\s+\w+  (simplified — matches "import" + whitespace + identifier)
    var re = try Regex.compile(std.testing.allocator, "import\\s+\\w+");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("import std"));
    try std.testing.expect(try re.isMatch("from os import path"));
    try std.testing.expect(!try re.isMatch("no imports here"));
}

test "pure literal detection" {
    try std.testing.expect(extractPureLiteral("hello") != null);
    try std.testing.expect(extractPureLiteral("hello.world") == null);
    try std.testing.expect(extractPureLiteral("fn\\(") == null);
    try std.testing.expect(extractPureLiteral("TODO") != null);
}
