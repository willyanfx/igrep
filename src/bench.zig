const std = @import("std");
const literal = @import("engine/literal.zig");
const simd_utils = @import("util/simd.zig");

/// Simple benchmarking harness for instantGrep.
/// Run with: zig build bench
pub fn main() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll("instantGrep benchmarks\n");
    try stdout.writeAll("======================\n\n");

    try benchLiteralSearch(stdout);
    try benchSIMDOperations(stdout);
}

fn benchLiteralSearch(writer: anytype) !void {
    const size = 1024 * 1024; // 1 MB
    var haystack: [size]u8 = undefined;
    for (&haystack, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    const needle = "INSTANTGREP";
    @memcpy(haystack[size - 100 ..][0..needle.len], needle);

    const iterations = 1000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        const found = literal.contains(&haystack, needle);
        std.mem.doNotOptimizeAway(found);
    }

    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const throughput_gbps = (@as(f64, @floatFromInt(size)) * @as(f64, @floatFromInt(iterations))) / @as(f64, @floatFromInt(elapsed_ns));

    try writer.print("Literal search (1MB, {d} iterations):\n", .{iterations});
    try writer.print("  Total: {d:.2} ms\n", .{elapsed_ms});
    try writer.print("  Per iteration: {d:.2} us\n", .{elapsed_ms * 1000.0 / @as(f64, @floatFromInt(iterations))});
    try writer.print("  Throughput: {d:.2} GB/s\n\n", .{throughput_gbps});
}

fn benchSIMDOperations(writer: anytype) !void {
    const size = 1024 * 1024;
    var data: [size]u8 = undefined;
    for (&data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    const iterations = 10000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        var count: u32 = 0;
        var offset: usize = 0;
        while (offset + simd_utils.VECTOR_LEN <= size) {
            count += simd_utils.countMatches(
                data[offset..][0..simd_utils.VECTOR_LEN].*,
                0x42,
            );
            offset += simd_utils.VECTOR_LEN;
        }
        std.mem.doNotOptimizeAway(count);
    }

    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const throughput_gbps = (@as(f64, @floatFromInt(size)) * @as(f64, @floatFromInt(iterations))) / @as(f64, @floatFromInt(elapsed_ns));

    try writer.print("SIMD byte counting (1MB, {d} iterations):\n", .{iterations});
    try writer.print("  Total: {d:.2} ms\n", .{elapsed_ms});
    try writer.print("  Per iteration: {d:.2} us\n", .{elapsed_ms * 1000.0 / @as(f64, @floatFromInt(iterations))});
    try writer.print("  Throughput: {d:.2} GB/s\n\n", .{throughput_gbps});
}
