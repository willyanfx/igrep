const std = @import("std");
const simd_utils = @import("../util/simd.zig");

/// SIMD-accelerated literal string search.
///
/// Strategy:
/// 1. For single-byte patterns: vectorized memchr scan.
/// 2. For multi-byte patterns: pick the rarest byte in the needle (by source code
///    frequency table), scan for it via SIMD, then verify full needle at candidates.
/// 3. Falls back to scalar loop for edge cases and short haystacks.

/// Byte frequency table for source code (lower = rarer).
/// Derived from byte distributions in mixed-language corpora (JS/TS/Python/Go/Rust/C).
/// Values 0-255 where 0 = never seen, 255 = extremely common (space, 'e', 't', etc.).
const byte_frequency: [256]u8 = freq: {
    var table = [_]u8{0} ** 256;
    // Control chars: very rare
    for (0..32) |i| table[i] = 1;
    table['\t'] = 80; // tab is common in source
    table['\n'] = 90; // newline is very common
    table['\r'] = 10; // CR less common

    // Printable ASCII frequencies (approximate, biased toward source code)
    table[' '] = 255; // space: most common byte in source code
    table['!'] = 20;
    table['"'] = 60;
    table['#'] = 30;
    table['$'] = 15;
    table['%'] = 12;
    table['&'] = 25;
    table['\''] = 55;
    table['('] = 80;
    table[')'] = 80;
    table['*'] = 40;
    table['+'] = 30;
    table[','] = 70;
    table['-'] = 50;
    table['.'] = 75;
    table['/'] = 55;
    table['0'] = 50;
    table['1'] = 45;
    table['2'] = 35;
    table['3'] = 30;
    table['4'] = 25;
    table['5'] = 25;
    table['6'] = 20;
    table['7'] = 20;
    table['8'] = 20;
    table['9'] = 20;
    table[':'] = 55;
    table[';'] = 60;
    table['<'] = 35;
    table['='] = 65;
    table['>'] = 35;
    table['?'] = 20;
    table['@'] = 15;
    // Uppercase: moderately common
    table['A'] = 40;
    table['B'] = 25;
    table['C'] = 30;
    table['D'] = 25;
    table['E'] = 35;
    table['F'] = 25;
    table['G'] = 20;
    table['H'] = 20;
    table['I'] = 35;
    table['J'] = 15;
    table['K'] = 12;
    table['L'] = 25;
    table['M'] = 25;
    table['N'] = 25;
    table['O'] = 25;
    table['P'] = 25;
    table['Q'] = 5;
    table['R'] = 25;
    table['S'] = 30;
    table['T'] = 35;
    table['U'] = 20;
    table['V'] = 15;
    table['W'] = 15;
    table['X'] = 10;
    table['Y'] = 12;
    table['Z'] = 5;
    table['['] = 40;
    table['\\'] = 30;
    table[']'] = 40;
    table['^'] = 5;
    table['_'] = 50;
    table['`'] = 20;
    // Lowercase: very common in identifiers
    table['a'] = 130;
    table['b'] = 50;
    table['c'] = 80;
    table['d'] = 70;
    table['e'] = 180;
    table['f'] = 70;
    table['g'] = 45;
    table['h'] = 50;
    table['i'] = 140;
    table['j'] = 20;
    table['k'] = 25;
    table['l'] = 80;
    table['m'] = 55;
    table['n'] = 120;
    table['o'] = 120;
    table['p'] = 65;
    table['q'] = 8;
    table['r'] = 110;
    table['s'] = 120;
    table['t'] = 150;
    table['u'] = 75;
    table['v'] = 35;
    table['w'] = 35;
    table['x'] = 25;
    table['y'] = 40;
    table['z'] = 10;
    table['{'] = 55;
    table['|'] = 15;
    table['}'] = 55;
    table['~'] = 3;
    // High bytes (128-255): very rare in source code
    for (128..256) |i| table[i] = 2;
    break :freq table;
};

/// Return the index of the rarest byte in `needle` according to source code frequency.
/// For case-insensitive searches, pass `case_sensitive = false` to consider both cases.
pub fn rarestByteIndex(needle: []const u8) usize {
    if (needle.len <= 1) return 0;
    var best_idx: usize = 0;
    var best_freq: u8 = 255;
    for (needle, 0..) |b, i| {
        const freq = byte_frequency[b];
        if (freq < best_freq) {
            best_freq = freq;
            best_idx = i;
        }
    }
    return best_idx;
}

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
pub fn findFirstCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
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
/// Uses a rare-byte heuristic to pick the SIMD scan anchor, maximizing
/// the chance that each vector comparison yields zero candidates.
pub fn findFirst(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    // Single-byte: use platform-optimized memchr
    if (needle.len == 1) {
        return simd_utils.findNextByte(haystack, needle[0], 0);
    }

    // Multi-byte: SIMD pair technique with rare-byte heuristic.
    // Compares two bytes of the needle at once across 16 positions,
    // then verifies full match only at candidate positions.
    if (haystack.len >= simd_utils.VECTOR_LEN) {
        const rare_idx = rarestByteIndex(needle);
        const rare_byte = needle[rare_idx];
        const second_idx: usize = if (rare_idx == needle.len - 1) 0 else needle.len - 1;
        const second_byte = needle[second_idx];
        return simdFindRarePair(haystack, needle, rare_byte, rare_idx, second_byte, second_idx);
    }

    // Scalar fallback for short haystacks
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

/// SIMD search using "rare byte + second byte" pair technique.
/// Instead of always scanning for needle[0], picks the rarest byte in the needle
/// (by source code frequency) as the primary anchor. This maximizes the chance
/// that SIMD vector comparisons yield zero candidates, skipping 16/32 bytes at once.
/// A second anchor byte (far from the rare byte) further reduces false positives.
fn simdFindRarePair(
    haystack: []const u8,
    needle: []const u8,
    rare_byte: u8,
    rare_idx: usize,
    second_byte: u8,
    second_idx: usize,
) ?usize {
    const search_end = haystack.len - needle.len + 1;

    // Try wide vector path first if available and data is large enough
    if (simd_utils.VECTOR_LEN == 16 and
        simd_utils.WIDE_VECTOR_LEN == 32 and
        search_end >= simd_utils.WIDE_VECTOR_LEN)
    {
        if (simdFindRarePairWide(haystack, needle, rare_byte, rare_idx, second_byte, second_idx)) |pos| {
            return pos;
        }
    }

    // Standard narrow path
    const Vec = @Vector(simd_utils.VECTOR_LEN, u8);
    const rare_vec: Vec = @splat(rare_byte);
    const second_vec: Vec = @splat(second_byte);

    // For patterns >= 4 bytes, also check a middle byte to cut false positives
    const use_mid = needle.len >= 4 and rare_idx != needle.len / 2 and second_idx != needle.len / 2;
    const mid_offset = needle.len / 2;
    const mid_vec: Vec = if (use_mid) @splat(needle[mid_offset]) else @splat(@as(u8, 0));

    var i: usize = 0;

    while (i + simd_utils.VECTOR_LEN <= search_end) {
        // Load at rare_idx offset: if candidate starts at position i+k,
        // then haystack[i+k+rare_idx] should equal rare_byte
        const rare_chunk: Vec = haystack[i + rare_idx ..][0..simd_utils.VECTOR_LEN].*;
        const second_chunk: Vec = haystack[i + second_idx ..][0..simd_utils.VECTOR_LEN].*;

        const rare_match: @Vector(simd_utils.VECTOR_LEN, bool) = rare_chunk == rare_vec;
        const second_match: @Vector(simd_utils.VECTOR_LEN, bool) = second_chunk == second_vec;

        var mask = simd_utils.movemask(rare_match) & simd_utils.movemask(second_match);

        if (use_mid and mask != 0) {
            const mid_chunk: Vec = haystack[i + mid_offset ..][0..simd_utils.VECTOR_LEN].*;
            const mid_match: @Vector(simd_utils.VECTOR_LEN, bool) = mid_chunk == mid_vec;
            mask &= simd_utils.movemask(mid_match);
        }

        while (mask != 0) {
            const bit_pos = @ctz(mask);
            const candidate = i + bit_pos;

            if (std.mem.eql(u8, haystack[candidate..][0..needle.len], needle)) {
                return candidate;
            }

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

/// Wide vector variant of simdFindRarePair using 32-byte scans.
fn simdFindRarePairWide(
    haystack: []const u8,
    needle: []const u8,
    rare_byte: u8,
    rare_idx: usize,
    second_byte: u8,
    second_idx: usize,
) ?usize {
    const WideVec = @Vector(simd_utils.WIDE_VECTOR_LEN, u8);
    const rare_vec: WideVec = @splat(rare_byte);
    const second_vec: WideVec = @splat(second_byte);

    const use_mid = needle.len >= 4 and rare_idx != needle.len / 2 and second_idx != needle.len / 2;
    const mid_offset = needle.len / 2;
    const mid_vec: WideVec = if (use_mid) @splat(needle[mid_offset]) else @splat(@as(u8, 0));

    const search_end = haystack.len - needle.len + 1;
    var i: usize = 0;

    while (i + simd_utils.WIDE_VECTOR_LEN <= search_end) {
        const rare_chunk: WideVec = haystack[i + rare_idx ..][0..simd_utils.WIDE_VECTOR_LEN].*;
        const second_chunk: WideVec = haystack[i + second_idx ..][0..simd_utils.WIDE_VECTOR_LEN].*;

        const rare_match: @Vector(simd_utils.WIDE_VECTOR_LEN, bool) = rare_chunk == rare_vec;
        const second_match: @Vector(simd_utils.WIDE_VECTOR_LEN, bool) = second_chunk == second_vec;

        var mask: u32 = @as(u32, @bitCast(rare_match)) & @as(u32, @bitCast(second_match));

        if (use_mid and mask != 0) {
            const mid_chunk: WideVec = haystack[i + mid_offset ..][0..simd_utils.WIDE_VECTOR_LEN].*;
            const mid_match: @Vector(simd_utils.WIDE_VECTOR_LEN, bool) = mid_chunk == mid_vec;
            mask &= @as(u32, @bitCast(mid_match));
        }

        while (mask != 0) {
            const bit_pos = @ctz(mask);
            const candidate = i + bit_pos;

            if (candidate + needle.len <= haystack.len and
                std.mem.eql(u8, haystack[candidate..][0..needle.len], needle))
            {
                return candidate;
            }

            mask &= mask - 1;
        }

        i += simd_utils.WIDE_VECTOR_LEN;
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

test "rarestByteIndex picks low-frequency bytes" {
    // 'Q' (freq 5) is rarest in "QueryString"
    const idx1 = rarestByteIndex("QueryString");
    try std.testing.expectEqual(@as(usize, 0), idx1); // Q=5

    // 'z' (freq 10) is rarest in "initialize"
    const idx2 = rarestByteIndex("initialize");
    try std.testing.expectEqual(@as(usize, 8), idx2); // z=10

    // 'x' (freq 25) is rarest in "export"
    const idx3 = rarestByteIndex("export");
    try std.testing.expectEqual(@as(usize, 1), idx3); // x=25

    // Single byte: always index 0
    try std.testing.expectEqual(@as(usize, 0), rarestByteIndex("a"));
}

test "findFirst with rare byte heuristic still finds all matches" {
    // Build a haystack long enough for SIMD path
    const haystack = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaimport os; import sys; from import x; export default;";
    try std.testing.expect(findFirst(haystack, "import") != null);
    try std.testing.expect(findFirst(haystack, "export") != null);
    try std.testing.expect(findFirst(haystack, "missing") == null);

    // Verify exact positions
    const pos = findFirst(haystack, "import").?;
    try std.testing.expect(std.mem.eql(u8, haystack[pos..][0..6], "import"));
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
