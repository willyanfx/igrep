const std = @import("std");
const regex_engine = @import("engine/regex.zig");
const lazy_dfa_mod = @import("engine/lazy_dfa.zig");

const Timer = struct {
    start: i128,

    fn now() i128 {
        return std.time.nanoTimestamp();
    }

    fn init() Timer {
        return .{ .start = now() };
    }

    fn elapsedMs(self: Timer) f64 {
        const elapsed = now() - self.start;
        return @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
    }

    fn elapsedUs(self: Timer) f64 {
        const elapsed = now() - self.start;
        return @as(f64, @floatFromInt(elapsed)) / 1_000.0;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const pattern = "fn\\s+\\w+\\(";
    const corpus_path = "/tmp/bench_corpus/huge.zig";

    // Load corpus
    const file = try std.fs.openFileAbsolute(corpus_path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
    defer allocator.free(contents);

    // Count lines for reference
    var line_count: u64 = 0;
    var match_count: u64 = 0;
    for (contents) |ch| {
        if (ch == '\n') line_count += 1;
    }

    std.debug.print("=== igrep Regex Performance Analysis ===\n", .{});
    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Corpus: {s}\n", .{corpus_path});
    std.debug.print("File size: {d} MB\n", .{contents.len / (1024 * 1024)});
    std.debug.print("Lines: {d}K\n\n", .{line_count / 1000});

    // Compile regex
    var re = try regex_engine.Regex.compile(allocator, pattern);
    defer re.deinit(allocator);

    std.debug.print("NFA Analysis:\n", .{});
    std.debug.print("  Total NFA states: {d}\n", .{re.nfa.states.len});
    std.debug.print("  Is pure literal: {}\n", .{re.is_literal});
    std.debug.print("  Required literal: {?s}\n", .{re.required_literal});

    // Count NFA state kinds
    var split_count: u32 = 0;
    var match_char_count: u32 = 0;
    var match_class_count: u32 = 0;
    var anchor_count: u32 = 0;
    var accept_count: u32 = 0;

    for (re.nfa.states) |state| {
        switch (state.kind) {
            .split => split_count += 1,
            .match_char => match_char_count += 1,
            .match_class => match_class_count += 1,
            .anchor_start, .anchor_end, .word_boundary => anchor_count += 1,
            .accept => accept_count += 1,
            else => {},
        }
    }

    std.debug.print("  States: {d} split, {d} char, {d} class, {d} anchor, {d} accept\n\n",
        .{split_count, match_char_count, match_class_count, anchor_count, accept_count});

    // Create lazy DFA
    var dfa = try re.createDfa(allocator);
    defer dfa.deinit();

    std.debug.print("DFA Warmup and Measurements:\n", .{});

    // Warmup run
    var warmup_timer = Timer.init();
    _ = try dfa.isMatch(contents);
    const warmup_ms = warmup_timer.elapsedMs();
    std.debug.print("  Warmup run: {d:.2} ms\n", .{warmup_ms});

    // Measure cache state after warmup
    const dfa_states_after_warmup = dfa.states.items.len;
    std.debug.print("  DFA states after warmup: {d}\n", .{dfa_states_after_warmup});

    // Full measurement: process line by line
    var timer = Timer.init();

    var line_start: usize = 0;
    var line_num: u64 = 0;

    while (line_start < contents.len) {
        const nl_pos = std.mem.indexOfScalar(u8, contents[line_start..], '\n');
        const line_end = if (nl_pos) |pos| line_start + pos else contents.len;
        const line = contents[line_start..line_end];

        if (try re.isMatchDfa(line, &dfa)) {
            match_count += 1;
        }

        line_num += 1;
        line_start = line_end + 1;
    }

    const total_ms = timer.elapsedMs();
    const throughput_mb_s = @as(f64, @floatFromInt(contents.len)) / (1024.0 * 1024.0) / (total_ms / 1000.0);
    const per_line_us = (total_ms * 1000.0) / @as(f64, @floatFromInt(line_count));

    std.debug.print("\n=== Regex Performance Results ===\n", .{});
    std.debug.print("Total time: {d:.2} ms\n", .{total_ms});
    std.debug.print("Matches: {d} / {d} lines\n", .{match_count, line_count});
    std.debug.print("Throughput: {d:.1} MB/s\n", .{throughput_mb_s});
    std.debug.print("Per-line: {d:.3} μs/line\n", .{per_line_us});
    std.debug.print("Theoretical max (array lookup): ~10000+ MB/s\n", .{});
    std.debug.print("Speedup potential: {d:.1}x\n", .{10000.0 / throughput_mb_s});

    std.debug.print("\nDFA Cache Statistics:\n", .{});
    std.debug.print("  Final DFA states: {d}\n", .{dfa.states.items.len});
    std.debug.print("  Flush count: {d}\n", .{dfa.flush_count});

    // Estimate cache hit rate by looking at average transitions per state
    if (dfa.states.items.len > 0) {
        var total_trans: u64 = 0;
        const UNKNOWN: u32 = std.math.maxInt(u32);
        for (dfa.states.items) |state| {
            for (state.trans[0..256]) |trans| {
                if (trans != UNKNOWN) {
                    total_trans += 1;
                }
            }
        }
        const estimated_hit_rate = @as(f64, @floatFromInt(total_trans)) /
                                    (@as(f64, @floatFromInt(dfa.states.items.len)) * 256.0) * 100.0;
        std.debug.print("  Estimated cache fill: {d:.1}%\n", .{estimated_hit_rate});
    }

    std.debug.print("\n=== Bottleneck Analysis ===\n", .{});
    std.debug.print("Array lookup time (256 entries per DFA state): ~1-2 cycles per byte on hot cache\n", .{});
    std.debug.print("NFA simulation on miss: ~{d} state checks per byte\n", .{re.nfa.states.len});
    std.debug.print("Observed: {d:.2} ms for {d} MB → {d:.0} cycles/byte\n",
        .{total_ms, contents.len / (1024*1024), (total_ms / 1000.0 * 3_000_000_000.0) / @as(f64, @floatFromInt(contents.len))});
}
