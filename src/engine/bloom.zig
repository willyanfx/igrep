const std = @import("std");

/// Bloom filter for augmenting trigram posting lists.
///
/// Each posting entry is augmented with two 8-bit masks:
/// - locMask: position of the trigram in the file (modulo 8)
/// - nextMask: hash of the character following the trigram
///
/// This gives us "3.5-gram" selectivity — we encode information about
/// the fourth character without storing full 4-grams.
///
/// Placeholder for Milestone 3.

pub const BloomEntry = struct {
    file_id: u32,
    loc_mask: u8,
    next_mask: u8,
};

/// Compute the location mask for a trigram at a given position.
pub fn locationMask(position: usize) u8 {
    return @as(u8, 1) << @intCast(position % 8);
}

/// Compute the next-character mask.
pub fn nextCharMask(char: u8) u8 {
    return @as(u8, 1) << @intCast(char % 8);
}

/// Check if a bloom entry could match at a given position with a given next character.
pub fn mightMatch(entry: BloomEntry, position: usize, next_char: ?u8) bool {
    // Check location mask
    if ((entry.loc_mask & locationMask(position)) == 0) return false;

    // Check next character mask (if applicable)
    if (next_char) |nc| {
        if ((entry.next_mask & nextCharMask(nc)) == 0) return false;
    }

    return true;
}

// ── Tests ────────────────────────────────────────────────────────────

test "location mask wraps at 8" {
    try std.testing.expectEqual(@as(u8, 1), locationMask(0));
    try std.testing.expectEqual(@as(u8, 2), locationMask(1));
    try std.testing.expectEqual(@as(u8, 1), locationMask(8)); // wraps
}

test "bloom entry matching" {
    const entry = BloomEntry{
        .file_id = 1,
        .loc_mask = locationMask(3) | locationMask(7),
        .next_mask = nextCharMask('x') | nextCharMask('y'),
    };

    try std.testing.expect(mightMatch(entry, 3, 'x'));
    try std.testing.expect(mightMatch(entry, 7, 'y'));
    try std.testing.expect(!mightMatch(entry, 0, 'x')); // wrong position
    try std.testing.expect(!mightMatch(entry, 3, 'z')); // wrong next char
}
