const std = @import("std");
const builtin = @import("builtin");

/// Adaptive SIMD width selection based on target CPU features.
/// At comptime, we detect available SIMD capabilities and choose the best vector width.
///
/// On x86_64:
///   - AVX2 capable: 32 bytes (256-bit)
///   - SSE/SSE2 capable: 16 bytes (128-bit)
/// On ARM:
///   - NEON capable: 16 bytes (128-bit)
/// Default fallback: 16 bytes (128-bit) — works everywhere

pub const VECTOR_LEN: comptime_int = selectVectorLen();

/// Select the best vector width based on CPU features.
fn selectVectorLen() comptime_int {
    // Check for AVX2 support on x86_64
    if (builtin.target.cpu.arch == .x86_64) {
        if (builtin.cpu.features.isEnabled(.avx2)) {
            return 32; // 256-bit AVX2
        }
    }
    // Default to 16 bytes (128-bit SSE/NEON)
    return 16;
}

/// The wider SIMD path for CPUs that support it.
/// Used in optimization loops when available.
pub const WIDE_VECTOR_LEN: comptime_int = 32;

/// Convert a boolean vector to a bitmask where each bit corresponds
/// to one lane of the vector. This is analogous to x86 _mm_movemask_epi8.
pub fn movemask(bools: @Vector(VECTOR_LEN, bool)) std.meta.Int(.unsigned, VECTOR_LEN) {
    return @bitCast(bools);
}

/// Splat a single byte across a vector.
pub fn splat(byte: u8) @Vector(VECTOR_LEN, u8) {
    return @splat(byte);
}

/// Load VECTOR_LEN bytes from a slice into a vector.
/// The slice must have at least VECTOR_LEN bytes available.
pub fn load(data: []const u8) @Vector(VECTOR_LEN, u8) {
    return data[0..VECTOR_LEN].*;
}

/// Count the number of matching bytes in a vector comparison.
pub fn countMatches(vec: @Vector(VECTOR_LEN, u8), needle_byte: u8) u32 {
    const needle_vec: @Vector(VECTOR_LEN, u8) = @splat(needle_byte);
    const matches = vec == needle_vec;
    const mask = movemask(matches);
    return @popCount(mask);
}

/// Find the position of the first matching byte in a vector.
/// Returns null if no match found.
pub fn findByte(vec: @Vector(VECTOR_LEN, u8), needle_byte: u8) ?u4 {
    const needle_vec: @Vector(VECTOR_LEN, u8) = @splat(needle_byte);
    const matches = vec == needle_vec;
    const mask = movemask(matches);
    if (mask == 0) return null;
    return @intCast(@ctz(mask));
}

/// SIMD diagnostics struct for runtime introspection.
pub const SimdInfo = struct {
    vector_len: u32,
    wide_vector_len: u32,
    has_avx2: bool,
    target_arch: []const u8,
};

/// Get information about detected SIMD capabilities.
/// Useful for diagnostics and understanding which path is taken.
pub fn simdInfo() SimdInfo {
    const has_avx2 = builtin.target.cpu.arch == .x86_64 and
        builtin.cpu.features.isEnabled(.avx2);

    const arch_name = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm",
        else => "unknown",
    };

    return .{
        .vector_len = VECTOR_LEN,
        .wide_vector_len = WIDE_VECTOR_LEN,
        .has_avx2 = has_avx2,
        .target_arch = arch_name,
    };
}

/// Find the next occurrence of `byte` in `data` starting from `start`.
/// Uses adaptive SIMD width: 32 bytes (AVX2) on capable CPUs, else 16 bytes (SSE/NEON).
/// Falls back to scalar for the tail.
pub fn findNextByte(data: []const u8, byte: u8, start: usize) ?usize {
    if (start >= data.len) return null;

    var pos = start;

    // Use wide vector if available for the main loop
    if (VECTOR_LEN == 16 and WIDE_VECTOR_LEN == 32 and data.len - start >= 32) {
        return findNextByteWide(data, byte, start);
    }

    // Standard path with current VECTOR_LEN
    const needle_vec: @Vector(VECTOR_LEN, u8) = @splat(byte);

    while (pos + VECTOR_LEN <= data.len) {
        const chunk: @Vector(VECTOR_LEN, u8) = data[pos..][0..VECTOR_LEN].*;
        const matches = chunk == needle_vec;
        const mask = movemask(matches);
        if (mask != 0) {
            return pos + @as(usize, @ctz(mask));
        }
        pos += VECTOR_LEN;
    }

    // Scalar tail
    while (pos < data.len) {
        if (data[pos] == byte) return pos;
        pos += 1;
    }
    return null;
}

/// Wide vector path for AVX2-capable systems (32-byte scans).
/// Only used when VECTOR_LEN is 16 but we want wider scans for long data.
fn findNextByteWide(data: []const u8, byte: u8, start: usize) ?usize {
    var pos = start;
    const needle_vec_wide: @Vector(WIDE_VECTOR_LEN, u8) = @splat(byte);

    // 32-byte scans when available
    while (pos + WIDE_VECTOR_LEN <= data.len) {
        const chunk: @Vector(WIDE_VECTOR_LEN, u8) = data[pos..][0..WIDE_VECTOR_LEN].*;
        const matches = chunk == needle_vec_wide;
        const mask = movemask_wide(matches);
        if (mask != 0) {
            return pos + @as(usize, @ctz(mask));
        }
        pos += WIDE_VECTOR_LEN;
    }

    // Fall back to narrow vector for remaining bytes
    const needle_vec: @Vector(VECTOR_LEN, u8) = @splat(byte);
    while (pos + VECTOR_LEN <= data.len) {
        const chunk: @Vector(VECTOR_LEN, u8) = data[pos..][0..VECTOR_LEN].*;
        const matches = chunk == needle_vec;
        const mask = movemask(matches);
        if (mask != 0) {
            return pos + @as(usize, @ctz(mask));
        }
        pos += VECTOR_LEN;
    }

    // Scalar tail
    while (pos < data.len) {
        if (data[pos] == byte) return pos;
        pos += 1;
    }
    return null;
}

/// Convert a wide (32-byte) boolean vector to a bitmask.
/// Similar to movemask but for 32-byte vectors.
fn movemask_wide(bools: @Vector(WIDE_VECTOR_LEN, bool)) u32 {
    return @bitCast(bools);
}

// ── Tests ────────────────────────────────────────────────────────────

test "splat creates uniform vector" {
    const vec = splat(0x42);
    const arr: [VECTOR_LEN]u8 = vec;
    for (arr) |b| {
        try std.testing.expectEqual(@as(u8, 0x42), b);
    }
}

test "movemask converts bools to bitmask" {
    var bools: @Vector(VECTOR_LEN, bool) = @splat(false);
    bools[0] = true;
    bools[3] = true;
    const mask = movemask(bools);
    try std.testing.expectEqual(@as(@TypeOf(mask), 0b0000_0000_0000_1001), mask);
}

test "countMatches counts correctly" {
    const data = "hello world!!!!!";
    const vec: @Vector(VECTOR_LEN, u8) = data[0..VECTOR_LEN].*;
    try std.testing.expectEqual(@as(u32, 3), countMatches(vec, 'l'));
}

test "findByte finds first occurrence" {
    const data = "hello world!!!!!";
    const vec: @Vector(VECTOR_LEN, u8) = data[0..VECTOR_LEN].*;
    const pos = findByte(vec, 'o');
    try std.testing.expect(pos != null);
    try std.testing.expectEqual(@as(u4, 4), pos.?);
}

test "findNextByte finds newlines" {
    const data = "line one\nline two\nline three\n";
    try std.testing.expectEqual(@as(?usize, 8), findNextByte(data, '\n', 0));
    try std.testing.expectEqual(@as(?usize, 17), findNextByte(data, '\n', 9));
    try std.testing.expectEqual(@as(?usize, 28), findNextByte(data, '\n', 18));
    try std.testing.expectEqual(@as(?usize, null), findNextByte(data, '\n', 29));
}

test "findNextByte works with data longer than VECTOR_LEN" {
    const data = "0123456789abcdef\nmore data after newline\n";
    try std.testing.expectEqual(@as(?usize, 16), findNextByte(data, '\n', 0));
    try std.testing.expectEqual(@as(?usize, 40), findNextByte(data, '\n', 17));
}

test "simdInfo returns valid diagnostics" {
    const info = simdInfo();
    try std.testing.expect(info.vector_len >= 16);
    try std.testing.expect(info.vector_len <= 32);
    try std.testing.expect(info.wide_vector_len == 32);
    try std.testing.expect(info.target_arch.len > 0);
}

test "findNextByte with very long data uses wide path" {
    // Create data longer than WIDE_VECTOR_LEN to test wide path
    var buf: [256]u8 = undefined;
    @memset(&buf, 'x');
    buf[100] = '\n';
    buf[200] = '\n';

    const data = &buf;
    try std.testing.expectEqual(@as(?usize, 100), findNextByte(data, '\n', 0));
    try std.testing.expectEqual(@as(?usize, 200), findNextByte(data, '\n', 101));
}
