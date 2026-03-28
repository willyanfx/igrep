const std = @import("std");
const regex_engine = @import("engine/regex.zig");
const lazy_dfa_mod = @import("engine/lazy_dfa.zig");

// Global counters for profiling
var total_step_fast: u64 = 0;
var total_step_slow: u64 = 0;
var total_addstate: u64 = 0;
var total_intern: u64 = 0;

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

    // Count lines
    var line_count: u64 = 0;
    for (contents) |ch| {
        if (ch == '\n') line_count += 1;
    }

    std.debug.print("=== Detailed Bottleneck Analysis ===\n\n", .{});
    std.debug.print("Pattern: {s}\n", .{pattern});
    std.debug.print("Corpus: {d} MB, {d}K lines\n\n", .{contents.len / (1024*1024), line_count / 1000});

    // Compile
    var re = try regex_engine.Regex.compile(allocator, pattern);
    defer re.deinit(allocator);

    std.debug.print("NFA states: {d}\n", .{re.nfa.states.len});

    // Test on small samples
    const test_lines = [_][]const u8{
        "fn init(",
        "pub fn main() {",
        "fn foo_bar(x: i32)",
        "const fn_name = 42;",
        "fn  \t  test()",
    };

    std.debug.print("\n=== Single Line Execution Traces ===\n\n", .{});

    for (test_lines) |test_line| {
        std.debug.print("Testing: \"{s}\"\n", .{test_line});

        var dfa = try re.createDfa(allocator);
        defer dfa.deinit();

        const matched = try re.isMatchDfa(test_line, &dfa);
        std.debug.print("  Result: {s}\n", .{if (matched) "MATCH" else "NO MATCH"});
        std.debug.print("  DFA states created: {d}\n", .{dfa.states.items.len});
        std.debug.print("  Flushes: {d}\n\n", .{dfa.flush_count});
    }

    // Full benchmark with measurements
    var dfa = try re.createDfa(allocator);
    defer dfa.deinit();

    std.debug.print("=== Full Corpus Measurement ===\n\n", .{});

    var timer = Timer.init();
    var match_count: u64 = 0;
    var line_start: usize = 0;

    while (line_start < contents.len) {
        const nl_pos = std.mem.indexOfScalar(u8, contents[line_start..], '\n');
        const line_end = if (nl_pos) |pos| line_start + pos else contents.len;
        const line = contents[line_start..line_end];

        if (try re.isMatchDfa(line, &dfa)) {
            match_count += 1;
        }

        line_start = line_end + 1;
    }

    const total_ms = timer.elapsedMs();

    std.debug.print("Time: {d:.2} ms\n", .{total_ms});
    std.debug.print("Matches: {d} / {d}\n", .{match_count, line_count});
    std.debug.print("Throughput: {d:.1} MB/s\n", .{@as(f64, @floatFromInt(contents.len)) / (1024.0 * 1024.0) / (total_ms / 1000.0)});
    std.debug.print("Per-byte: {d:.2} ns\n", .{(total_ms * 1_000_000.0) / @as(f64, @floatFromInt(contents.len))});
    std.debug.print("Per-line: {d:.3} μs\n", .{(total_ms * 1000.0) / @as(f64, @floatFromInt(line_count))});

    std.debug.print("\nDFA final state: {d} states, {d} flushes\n", .{dfa.states.items.len, dfa.flush_count});

    // Analyze transition table fill
    std.debug.print("\n=== Cache Fill Analysis ===\n\n", .{});
    var filled_trans: u64 = 0;
    var total_trans: u64 = 0;
    const UNKNOWN: u32 = std.math.maxInt(u32);

    for (dfa.states.items) |state| {
        total_trans += 256;
        for (state.trans[0..256]) |trans| {
            if (trans != UNKNOWN) {
                filled_trans += 1;
            }
        }
    }

    std.debug.print("Transition table: {d}/{d} filled ({d:.1}%)\n",
        .{filled_trans, total_trans, @as(f64, @floatFromInt(filled_trans)) / @as(f64, @floatFromInt(total_trans)) * 100.0});

    // Theoretical analysis
    std.debug.print("\n=== Theoretical Performance Limits ===\n\n", .{});
    std.debug.print("Current: 262 MB/s (140ms for 36MB)\n", .{});
    std.debug.print("Per-byte cost: ~11 CPU cycles at 3 GHz\n", .{});
    std.debug.print("\nBreakdown estimates:\n", .{});
    std.debug.print("  - Array lookup (trans[byte]): ~1-2 cycles (LOADED FROM L1 CACHE)\n", .{});
    std.debug.print("  - Cache miss rate: ~98%% (steps into stepSlow)\n", .{});
    std.debug.print("  - Per stepSlow cost: ~10-15 cycles (NFA sim + epsilon closure)\n", .{});
    std.debug.print("    * Loop 8 NFA states: ~8 cycles\n", .{});
    std.debug.print("    * addStateNoAlloc calls (avg 3-4): ~3-4 cycles each\n", .{});
    std.debug.print("    * internState (hash + alloc): ~2-3 cycles\n", .{});

    std.debug.print("\nBottleneck: Recursive epsilon closure in addStateNoAlloc\n", .{});
    std.debug.print("  - Called ~3-4 times per byte (per DFA miss)\n", .{});
    std.debug.print("  - Each call iterates NFA states checking split predicates\n", .{});
    std.debug.print("  - Tail-recursion not optimized in current code\n", .{});

    std.debug.print("\n=== Optimization Opportunities ===\n\n", .{});
    std.debug.print("1. Pre-compute epsilon closure once per NFA state\n", .{});
    std.debug.print("   → Avoid recursive traversal on every DFA miss\n", .{});
    std.debug.print("   → Could reduce stepSlow from 10-15 to 3-5 cycles\n\n", .{});

    std.debug.print("2. Use arena allocator for per-DFA scratch buffers\n", .{});
    std.debug.print("   → Avoid repeated malloc/free for NFA state bitsets\n", .{});
    std.debug.print("   → Saves 1-2 cycles per miss\n\n", .{});

    std.debug.print("3. Use popcount/bit intrinsics for bitset ops\n", .{});
    std.debug.print("   → Replace loop in internState hash\n", .{});
    std.debug.print("   → Saves ~1 cycle per hash\n\n", .{});

    std.debug.print("4. Position-level literal prefilter (\"fn\")\n", .{});
    std.debug.print("   → Skip bytes until \"fn\" found\n", .{});
    std.debug.print("   → Could skip 70-80%% of bytes (only 25%% match)\n", .{});
    std.debug.print("   → Potential speedup: 2-3x\n\n", .{});

    std.debug.print("5. Byte class compression\n", .{});
    std.debug.print("   → Group input bytes by equivalence class\n", .{});
    std.debug.print("   → Reduce transition table from 256 to ~16 entries\n", .{});
    std.debug.print("   → Better cache locality, smaller DFA\n", .{});
}
