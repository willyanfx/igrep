const std = @import("std");
const builtin = @import("builtin");

/// The SIMD vector length to use, in bytes.
/// We pick 16 bytes (128-bit) as the baseline that works everywhere,
/// including ARM NEON and x86 SSE2.
pub const VECTOR_LEN: comptime_int = 16;

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
