const std = @import("std");

// For very long strings, use a practical limit to avoid excessive computation
// (and to bound the stack matrix below). Counted in codepoints, not bytes.
const max_practical_len = 256;

/// Decode `s` as UTF-8 into `out` (one entry per codepoint), returning the count
/// — truncated at `out.len`. Malformed bytes decode to themselves (Latin-1
/// style) so a bad identifier never errors; ASCII maps 1:1, so pure-ASCII names
/// are unchanged. `out.len` must be `max_practical_len`.
fn decodeCodepoints(s: []const u8, out: *[max_practical_len]u21) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) : (n += 1) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            out[n] = s[i];
            i += 1;
            continue;
        };
        if (i + seq_len > s.len) {
            out[n] = s[i];
            i += 1;
            continue;
        }
        out[n] = std.unicode.utf8Decode(s[i .. i + seq_len]) catch {
            out[n] = s[i];
            i += 1;
            continue;
        };
        i += seq_len;
    }
    return n;
}

/// Calculate Levenshtein edit distance between two strings, measured in Unicode
/// codepoints (not bytes) so distances aren't skewed for non-ASCII identifiers.
/// This is the core algorithm for finding similar command names.
/// Uses a memory-efficient two-row approach: O(min(n,m)) instead of O(n*m).
pub fn editDistance(a: []const u8, b: []const u8) usize {
    // Comptime callers (the plugin-hook typo guard) evaluate the decode + DP for
    // identifier-length strings, which exceeds the default 1000-branch budget;
    // raise it here so every comptime call site doesn't have to. No-op at runtime.
    @setEvalBranchQuota(10_000);
    var a_buf: [max_practical_len]u21 = undefined;
    var b_buf: [max_practical_len]u21 = undefined;
    const a_len = decodeCodepoints(a, &a_buf);
    const b_len = decodeCodepoints(b, &b_buf);

    if (a_len == 0) return b_len;
    if (b_len == 0) return a_len;

    // Work with the shorter string as columns to minimize the row width.
    // Explicit usize annotations keep the loop bounds usize at comptime
    // (comptime-known @min/@max results otherwise narrow to a tiny integer
    // type, overflowing the `for (1..len + 1)` ranges below).
    const shorter_len: usize = @min(a_len, b_len);
    const longer_len: usize = @max(a_len, b_len);

    const shorter = if (a_len <= b_len) a_buf[0..a_len] else b_buf[0..b_len];
    const longer = if (a_len <= b_len) b_buf[0..b_len] else a_buf[0..a_len];

    var prev_row: [max_practical_len + 1]usize = undefined; // +1 for initialization
    var curr_row: [max_practical_len + 1]usize = undefined;

    // Initialize first row
    for (0..shorter_len + 1) |j| {
        prev_row[j] = j;
    }

    // Fill the matrix row by row
    for (1..longer_len + 1) |i| {
        curr_row[0] = i;

        for (1..shorter_len + 1) |j| {
            const cost: usize = if (longer[i - 1] == shorter[j - 1]) 0 else 1;

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

test "editDistance counts codepoints, not bytes (#458)" {
    // 'é' is two UTF-8 bytes; a byte-wise distance would report 2 (substitute
    // the two bytes) instead of the true single-codepoint substitution.
    try std.testing.expectEqual(@as(usize, 1), editDistance("café", "cafe"));
    // Identical multibyte strings are distance 0, not skewed by byte count.
    try std.testing.expectEqual(@as(usize, 0), editDistance("naïve", "naïve"));
    // Multibyte length semantics: "" vs a 5-codepoint word is 5, not its 6 bytes.
    try std.testing.expectEqual(@as(usize, 5), editDistance("", "café!"));
    // A 4-byte codepoint (emoji) is a single unit — one substitution.
    try std.testing.expectEqual(@as(usize, 1), editDistance("😀", "😁"));
    try std.testing.expectEqual(@as(usize, 0), editDistance("a😀b", "a😀b"));
}
