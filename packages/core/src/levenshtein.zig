const std = @import("std");

/// Calculate Levenshtein edit distance between two strings
/// This is the core algorithm for finding similar command names
/// Uses a more memory-efficient approach for larger strings
pub fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    // For very long strings, use a practical limit to avoid excessive computation
    const max_practical_len = 256;
    // Explicit usize annotations keep the loop bounds usize when the function
    // runs at comptime (comptime-known @min/@max results otherwise narrow to
    // tiny integer types, overflowing the `for (1..len + 1)` ranges below).
    const a_len: usize = @min(a.len, max_practical_len);
    const b_len: usize = @min(b.len, max_practical_len);

    // Use a more memory-efficient approach with two arrays instead of a full matrix
    // This reduces memory usage from O(n*m) to O(min(n,m))

    // Use two arrays instead of full matrix - more memory efficient
    // We'll work with the shorter string as columns to minimize memory usage
    const shorter_len: usize = @min(a_len, b_len);
    const longer_len: usize = @max(a_len, b_len);

    const shorter_str = if (a_len <= b_len) a[0..a_len] else b[0..b_len];
    const longer_str = if (a_len <= b_len) b[0..b_len] else a[0..a_len];

    // Use stack arrays for reasonable sizes, otherwise return simple difference
    if (shorter_len > 512) {
        // For very long strings, fall back to simple length difference
        // This avoids stack overflow while still providing some useful metric
        return if (longer_len > shorter_len) longer_len - shorter_len else 0;
    }

    var prev_row: [513]usize = undefined; // +1 for initialization
    var curr_row: [513]usize = undefined;

    // Initialize first row
    for (0..shorter_len + 1) |j| {
        prev_row[j] = j;
    }

    // Fill the matrix row by row
    for (1..longer_len + 1) |i| {
        curr_row[0] = i;

        for (1..shorter_len + 1) |j| {
            const cost: usize = if (longer_str[i - 1] == shorter_str[j - 1]) 0 else 1;

            curr_row[j] = @min(@min(prev_row[j] + 1, // deletion
                curr_row[j - 1] + 1 // insertion
            ), prev_row[j - 1] + cost // substitution
            );
        }

        // Swap rows
        const temp = prev_row;
        prev_row = curr_row;
        curr_row = temp;
    }

    return prev_row[shorter_len];
}

// Tests
test "editDistance basic" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("hello", "hello"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("hello", "helo"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("hello", "helloo"));
    try std.testing.expectEqual(@as(usize, 2), editDistance("hello", "bell"));
    try std.testing.expectEqual(@as(usize, 4), editDistance("hello", "world"));
}

test "editDistance works at comptime" {
    // plugin_types.validatePlugin runs this at comptime for the hook
    // typo-guard, so comptime evaluation must keep working.
    comptime {
        std.debug.assert(editDistance("preExeucte", "preExecute") == 2);
        std.debug.assert(editDistance("postExecute", "preExecute") == 3);
        std.debug.assert(editDistance("preExecute", "preExecute") == 0);
        std.debug.assert(editDistance("onErorr", "onError") == 2);
    }
}

test "editDistance edge cases" {
    // Empty strings
    try std.testing.expectEqual(@as(usize, 0), editDistance("", ""));
    try std.testing.expectEqual(@as(usize, 5), editDistance("", "hello"));
    try std.testing.expectEqual(@as(usize, 3), editDistance("abc", ""));

    // Identical strings
    try std.testing.expectEqual(@as(usize, 0), editDistance("identical", "identical"));

    // Very different strings
    try std.testing.expectEqual(@as(usize, 6), editDistance("abc", "xyz123"));
}
