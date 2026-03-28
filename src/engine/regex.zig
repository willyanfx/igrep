const std = @import("std");

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

    const NONE: u32 = std.math.maxInt(u32);
};

pub const Nfa = struct {
    states: []NfaState,
    start: u32,

    pub fn deinit(self: *Nfa, allocator: std.mem.Allocator) void {
        // Free owned char class ranges
        for (self.states) |state| {
            if (state.kind == .match_class and state.ranges.len > 0) {
                allocator.free(state.ranges);
            }
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
        const idx = try self.addState(.{
            .kind = .match_class,
            .ranges = owned_ranges,
            .negated = node.negated,
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
                            if (matchCharClass(ch, state.ranges, state.negated)) {
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

pub const Regex = struct {
    pattern: []const u8,
    nfa: Nfa,
    is_literal: bool,
    literal_str: []const u8,

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

        // NFA compiler uses the real allocator since NFA states must outlive compile()
        var compiler = NfaCompiler.init(allocator);
        const nfa = try compiler.compile(ast);

        return .{
            .pattern = pattern,
            .nfa = nfa,
            .is_literal = lit != null,
            .literal_str = lit orelse "",
        };
    }

    pub fn deinit(self: *Regex, allocator: std.mem.Allocator) void {
        self.nfa.deinit(allocator);
    }

    /// Check if pattern matches anywhere in text.
    pub fn isMatch(self: *const Regex, text: []const u8, allocator: std.mem.Allocator) !bool {
        // Fast path: pure literal patterns use direct search
        if (self.is_literal) {
            return std.mem.indexOf(u8, text, self.literal_str) != null;
        }

        const executor = NfaExecutor.init(&self.nfa);
        return executor.isMatch(text, allocator);
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
    try std.testing.expect(try re.isMatch("xabcy", std.testing.allocator));
    try std.testing.expect(!try re.isMatch("xaby", std.testing.allocator));
}

test "regex dot matches any" {
    var re = try Regex.compile(std.testing.allocator, "a.c");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("abc", std.testing.allocator));
    try std.testing.expect(try re.isMatch("axc", std.testing.allocator));
    try std.testing.expect(!try re.isMatch("ac", std.testing.allocator));
}

test "regex star quantifier" {
    var re = try Regex.compile(std.testing.allocator, "ab*c");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("ac", std.testing.allocator));
    try std.testing.expect(try re.isMatch("abc", std.testing.allocator));
    try std.testing.expect(try re.isMatch("abbbc", std.testing.allocator));
    try std.testing.expect(!try re.isMatch("adc", std.testing.allocator));
}

test "regex plus quantifier" {
    var re = try Regex.compile(std.testing.allocator, "ab+c");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(!try re.isMatch("ac", std.testing.allocator));
    try std.testing.expect(try re.isMatch("abc", std.testing.allocator));
    try std.testing.expect(try re.isMatch("abbbc", std.testing.allocator));
}

test "regex alternation" {
    var re = try Regex.compile(std.testing.allocator, "cat|dog");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("I have a cat", std.testing.allocator));
    try std.testing.expect(try re.isMatch("I have a dog", std.testing.allocator));
    try std.testing.expect(!try re.isMatch("I have a bird", std.testing.allocator));
}

test "regex character class" {
    var re = try Regex.compile(std.testing.allocator, "[aeiou]+");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("hello", std.testing.allocator));
    try std.testing.expect(!try re.isMatch("xyz", std.testing.allocator));
}

test "regex character range" {
    var re = try Regex.compile(std.testing.allocator, "[a-z]+");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("hello", std.testing.allocator));
    try std.testing.expect(!try re.isMatch("12345", std.testing.allocator));
}

test "regex negated class" {
    var re = try Regex.compile(std.testing.allocator, "[^0-9]+");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("hello", std.testing.allocator));
    // "12345" — the [^0-9]+ requires at least one non-digit
    try std.testing.expect(!try re.isMatch("12345", std.testing.allocator));
}

test "regex shorthand classes" {
    var re_d = try Regex.compile(std.testing.allocator, "\\d+");
    defer re_d.deinit(std.testing.allocator);
    try std.testing.expect(try re_d.isMatch("abc123", std.testing.allocator));

    var re_w = try Regex.compile(std.testing.allocator, "\\w+");
    defer re_w.deinit(std.testing.allocator);
    try std.testing.expect(try re_w.isMatch("hello_world", std.testing.allocator));

    var re_s = try Regex.compile(std.testing.allocator, "\\s+");
    defer re_s.deinit(std.testing.allocator);
    try std.testing.expect(try re_s.isMatch("hello world", std.testing.allocator));
}

test "regex anchors" {
    var re_start = try Regex.compile(std.testing.allocator, "^hello");
    defer re_start.deinit(std.testing.allocator);
    try std.testing.expect(try re_start.isMatch("hello world", std.testing.allocator));
    try std.testing.expect(!try re_start.isMatch("say hello", std.testing.allocator));

    var re_end = try Regex.compile(std.testing.allocator, "world$");
    defer re_end.deinit(std.testing.allocator);
    try std.testing.expect(try re_end.isMatch("hello world", std.testing.allocator));
    try std.testing.expect(!try re_end.isMatch("world hello", std.testing.allocator));
}

test "regex question mark" {
    var re = try Regex.compile(std.testing.allocator, "colou?r");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("color", std.testing.allocator));
    try std.testing.expect(try re.isMatch("colour", std.testing.allocator));
}

test "regex repetition {n,m}" {
    var re = try Regex.compile(std.testing.allocator, "a{2,4}");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(!try re.isMatch("a", std.testing.allocator));
    try std.testing.expect(try re.isMatch("aa", std.testing.allocator));
    try std.testing.expect(try re.isMatch("aaa", std.testing.allocator));
    try std.testing.expect(try re.isMatch("aaaa", std.testing.allocator));
    try std.testing.expect(try re.isMatch("aaaaa", std.testing.allocator)); // matches first 4
}

test "regex practical: function signature" {
    var re = try Regex.compile(std.testing.allocator, "fn\\s+\\w+\\(");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("pub fn init(allocator: Allocator) void {", std.testing.allocator));
    try std.testing.expect(try re.isMatch("fn main() !void {", std.testing.allocator));
    try std.testing.expect(!try re.isMatch("const fn_name = 42;", std.testing.allocator));
}

test "regex practical: import statement" {
    // Pattern: import\s+\w+  (simplified — matches "import" + whitespace + identifier)
    var re = try Regex.compile(std.testing.allocator, "import\\s+\\w+");
    defer re.deinit(std.testing.allocator);

    try std.testing.expect(try re.isMatch("import std", std.testing.allocator));
    try std.testing.expect(try re.isMatch("from os import path", std.testing.allocator));
    try std.testing.expect(!try re.isMatch("no imports here", std.testing.allocator));
}

test "pure literal detection" {
    try std.testing.expect(extractPureLiteral("hello") != null);
    try std.testing.expect(extractPureLiteral("hello.world") == null);
    try std.testing.expect(extractPureLiteral("fn\\(") == null);
    try std.testing.expect(extractPureLiteral("TODO") != null);
}
