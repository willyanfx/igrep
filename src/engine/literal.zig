const std = @import("std");
const simd_utils = @import("../util/simd.zig");

/// SIMD-accelerated literal string search.
///
/// Strategy:
/// 1. For single-byte patterns: vectorized memchr scan.
/// 2. For multi-byte patterns: find first byte via SIMD, then verify remaining bytes.
/// 3. Falls back to scalar loop for edge cases and short haystacks.

/// Check if `haystack` contains `needle` (case-sensitive).
pub fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    if (needle.len == 1) {
        // Use SIMD byte scan for single-byte patterns
        return simd_utils.findNextByte(haystack, needle[0], 0) != null;
    }

    return findFirst(haystack, needle) != null;
}

/// Check if `haystack` contains `needle` (case-insensitive).
pub fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    if (needle.len == 1) {
        const lower = toLower(needle[0]);
        for (haystack) |c| {
            if (toLower(c) == lower) return true;
        }
        return false;
    }

    return findFirstCaseInsensitive(haystack, needle) != null;
}

/// SIMD-accelerated case-insensitive search using first+last byte pair technique.
/// Folds both haystack bytes to lowercase in the SIMD registers before comparison.
fn findFirstCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    const first_lower = toLower(needle[0]);
    const last_lower = toLower(needle[needle.len - 1]);

    const search_end = haystack.len - needle.len + 1;

    if (haystack.len >= simd_utils.VECTOR_LEN and needle.len >= 2) {
        const Vec = @Vector(simd_utils.VECTOR_LEN, u8);
        const first_vec: Vec = @splat(first_lower);
        const last_vec: Vec = @splat(last_lower);
        // Constants for vectorized toLower
        const a_vec: Vec = @splat('A');
        const z_vec: Vec = @splat('Z');
        const offset_vec: Vec = @splat(32);

        var i: usize = 0;
        while (i + simd_utils.VECTOR_LEN <= search_end) {
            // Load chunks and fold to lowercase via SIMD
            const first_chunk: Vec = haystack[i..][0..simd_utils.VECTOR_LEN].*;
            const last_chunk: Vec = haystack[i + needle.len - 1 ..][0..simd_utils.VECTOR_LEN].*;

            const first_lower_chunk = simdToLower(first_chunk, a_vec, z_vec, offset_vec);
            const last_lower_chunk = simdToLower(last_chunk, a_vec, z_vec, offset_vec);

            const first_match: @Vector(simd_utils.VECTOR_LEN, bool) = first_lower_chunk == first_vec;
            const last_match: @Vector(simd_utils.VECTOR_LEN, bool) = last_lower_chunk == last_vec;

            const first_bits = simd_utils.movemask(first_match);
            const last_bits = simd_utils.movemask(last_match);
            var mask = first_bits & last_bits;

            while (mask != 0) {
                const bit_pos = @ctz(mask);
                const candidate = i + bit_pos;

                if (matchAtCaseInsensitive(haystack[candidate..], needle)) {
                    return candidate;
                }
                mask &= mask - 1;
            }

            i += simd_utils.VECTOR_LEN;
        }

        // Scalar tail
        if (i < search_end) {
            return scalarFindCI(haystack[i..], needle, i);
        }
        return null;
    }

    return scalarFindCI(haystack, needle, 0);
}

/// Vectorized ASCII toLower: if 'A' <= c <= 'Z', return c + 32, else c.
inline fn simdToLower(
    v: @Vector(simd_utils.VECTOR_LEN, u8),
    a_vec: @Vector(simd_utils.VECTOR_LEN, u8),
    z_vec: @Vector(simd_utils.VECTOR_LEN, u8),
    offset_vec: @Vector(simd_utils.VECTOR_LEN, u8),
) @Vector(simd_utils.VECTOR_LEN, u8) {
    // is_upper = (v >= 'A') & (v <= 'Z')
    const ge_a: @Vector(simd_utils.VECTOR_LEN, bool) = v >= a_vec;
    const le_z: @Vector(simd_utils.VECTOR_LEN, bool) = v <= z_vec;
    // Use select: where both conditions hold, add 32; else keep original
    const ge_mask: @Vector(simd_utils.VECTOR_LEN, u1) = @bitCast(ge_a);
    const le_mask: @Vector(simd_utils.VECTOR_LEN, u1) = @bitCast(le_z);
    const upper_mask_u1 = ge_mask & le_mask;
    const upper_mask: @Vector(simd_utils.VECTOR_LEN, bool) = @bitCast(upper_mask_u1);
    return @select(u8, upper_mask, v +% offset_vec, v);
}

/// Scalar case-insensitive find, returns absolute offset.
fn scalarFindCI(haystack: []const u8, needle: []const u8, base: usize) ?usize {
    if (needle.len > haystack.len) return null;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        if (matchAtCaseInsensitive(haystack[i..], needle)) {
            return base + i;
        }
    }
    return null;
}

/// Find the first occurrence of `needle` in `haystack`.
/// Returns the byte offset or null if not found.
pub fn findFirst(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    const first_byte = needle[0];
    const last_byte = needle[needle.len - 1];

    // Use SIMD-accelerated search for first+last byte pairs
    // when the haystack is large enough to benefit.
    if (haystack.len >= simd_utils.VECTOR_LEN and needle.len >= 2) {
        return simdFindFirstLastPair(haystack, needle, first_byte, last_byte);
    }

    // Scalar fallback
    return scalarFind(haystack, needle);
}

/// Find all occurrences of `needle` in `haystack`.
/// Calls `callback` with each match offset.
pub fn findAll(
    haystack: []const u8,
    needle: []const u8,
    callback: *const fn (usize) void,
) void {
    if (needle.len == 0) return;
    var offset: usize = 0;
    while (offset + needle.len <= haystack.len) {
        if (findFirst(haystack[offset..], needle)) |pos| {
            callback(offset + pos);
            offset += pos + 1; // advance past match start to find overlapping matches
        } else {
            break;
        }
    }
}

// ── Internal Implementation ──────────────────────────────────────────

/// SIMD search using the "first, middle, and last byte" technique.
/// Scans for positions where the first and last bytes of the needle
/// match simultaneously, with an optional middle byte check to reduce
/// false positives for longer patterns. Then verifies full match at candidates.
fn simdFindFirstLastPair(
    haystack: []const u8,
    needle: []const u8,
    first_byte: u8,
    last_byte: u8,
) ?usize {
    const Vec = @Vector(simd_utils.VECTOR_LEN, u8);
    const first_vec: Vec = @splat(first_byte);
    const last_vec: Vec = @splat(last_byte);

    // For patterns >= 4 bytes, also check a middle byte to cut false positives
    const use_mid = needle.len >= 4;
    const mid_offset = needle.len / 2;
    const mid_vec: Vec = if (use_mid) @splat(needle[mid_offset]) else @splat(@as(u8, 0));

    const search_end = haystack.len - needle.len + 1;
    var i: usize = 0;

    while (i + simd_utils.VECTOR_LEN <= search_end) {
        // Load VECTOR_LEN bytes starting at position i (first byte candidates)
        const first_chunk: Vec = haystack[i..][0..simd_utils.VECTOR_LEN].*;
        // Load VECTOR_LEN bytes at offset (needle.len - 1) (last byte candidates)
        const last_chunk: Vec = haystack[i + needle.len - 1 ..][0..simd_utils.VECTOR_LEN].*;

        // Compare both first and last bytes simultaneously
        const first_match: @Vector(simd_utils.VECTOR_LEN, bool) = first_chunk == first_vec;
        const last_match: @Vector(simd_utils.VECTOR_LEN, bool) = last_chunk == last_vec;

        // AND the masks: positions where both first and last byte match
        var mask = simd_utils.movemask(first_match) & simd_utils.movemask(last_match);

        // Additional middle byte filter for longer patterns
        if (use_mid and mask != 0) {
            const mid_chunk: Vec = haystack[i + mid_offset ..][0..simd_utils.VECTOR_LEN].*;
            const mid_match: @Vector(simd_utils.VECTOR_LEN, bool) = mid_chunk == mid_vec;
            mask &= simd_utils.movemask(mid_match);
        }

        // Check each candidate position
        while (mask != 0) {
            const bit_pos = @ctz(mask);
            const candidate = i + bit_pos;

            // Verify full needle match
            if (std.mem.eql(u8, haystack[candidate..][0..needle.len], needle)) {
                return candidate;
            }

            // Clear the lowest set bit
            mask &= mask - 1;
        }

        i += simd_utils.VECTOR_LEN;
    }

    // Handle remaining bytes with scalar search
    if (i < search_end) {
        if (scalarFind(haystack[i..], needle)) |pos| {
            return i + pos;
        }
    }

    return null;
}

/// Scalar (non-SIMD) string search.
fn scalarFind(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            return i;
        }
    }
    return null;
}

fn matchAtCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, 0..) |nc, i| {
        const hc = haystack[i];
        if (toLower(hc) != toLower(nc)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ── Tests ────────────────────────────────────────────────────────────

test "literal contains basic" {
    try std.testing.expect(contains("hello world", "world"));
    try std.testing.expect(contains("hello world", "hello"));
    try std.testing.expect(!contains("hello world", "xyz"));
    try std.testing.expect(contains("hello world", ""));
    try std.testing.expect(!contains("hi", "hello"));
}

test "literal contains single byte" {
    try std.testing.expect(contains("abcdef", "c"));
    try std.testing.expect(!contains("abcdef", "z"));
}

test "literal case insensitive" {
    try std.testing.expect(containsCaseInsensitive("Hello World", "hello"));
    try std.testing.expect(containsCaseInsensitive("Hello World", "WORLD"));
    try std.testing.expect(!containsCaseInsensitive("Hello World", "xyz"));
}

test "findFirst returns correct offset" {
    const result = findFirst("hello world", "world");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 6), result.?);
}

test "findFirst handles needle at start" {
    const result = findFirst("hello world", "hello");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?);
}

test "findFirst returns null when not found" {
    try std.testing.expect(findFirst("hello world", "xyz") == null);
}

test "SIMD case-insensitive search on long strings" {
    const haystack = "The Quick Brown Fox Jumps Over The Lazy Dog and then some more text to ensure SIMD path is taken";
    try std.testing.expect(containsCaseInsensitive(haystack, "quick brown"));
    try std.testing.expect(containsCaseInsensitive(haystack, "LAZY DOG"));
    try std.testing.expect(containsCaseInsensitive(haystack, "simd path"));
    try std.testing.expect(!containsCaseInsensitive(haystack, "missing needle"));

    // Verify the SIMD toLower handles boundaries
    try std.testing.expect(containsCaseInsensitive(haystack, "FOX JUMPS"));
    try std.testing.expect(containsCaseInsensitive(haystack, "fox jumps"));
    try std.testing.expect(containsCaseInsensitive(haystack, "FoX jUmPs"));
}
