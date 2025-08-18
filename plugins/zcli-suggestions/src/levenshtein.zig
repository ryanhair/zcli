const std = @import("std");

/// Calculate Levenshtein edit distance between two strings
/// This is the core algorithm for finding similar command names
pub fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    // Create a matrix to store distances
    var matrix: [64][64]usize = undefined;

    // Handle case where strings are too long
    const max_len = 62; // Changed from 63 to avoid overflow with +1
    const a_len = @min(a.len, max_len);
    const b_len = @min(b.len, max_len);

    // Initialize first row and column
    for (0..a_len + 1) |i| {
        matrix[i][0] = i;
    }
    for (0..b_len + 1) |j| {
        matrix[0][j] = j;
    }

    // Fill the matrix
    for (1..a_len + 1) |i| {
        for (1..b_len + 1) |j| {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;

            matrix[i][j] = @min(
                @min(
                    matrix[i - 1][j] + 1, // deletion
                    matrix[i][j - 1] + 1, // insertion
                ),
                matrix[i - 1][j - 1] + cost, // substitution
            );
        }
    }

    return matrix[a_len][b_len];
}

/// Find commands similar to the input using edit distance
pub fn findSimilarCommands(input: []const u8, candidates: []const []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    var suggestions = std.ArrayList([]const u8).init(allocator);
    defer suggestions.deinit();

    for (candidates) |candidate| {
        const distance = editDistance(input, candidate);

        // Only suggest if the edit distance is reasonable
        if (distance <= 3 and distance < input.len) {
            try suggestions.append(candidate);
        }
    }

    return suggestions.toOwnedSlice();
}

/// Find similar commands with configurable threshold and max suggestions
pub fn findSimilarCommandsWithConfig(
    input: []const u8, 
    candidates: []const []const u8, 
    allocator: std.mem.Allocator,
    max_distance: usize,
    max_suggestions: usize
) ![][]const u8 {
    var suggestions_with_distance = std.ArrayList(struct { command: []const u8, distance: usize }).init(allocator);
    defer suggestions_with_distance.deinit();

    for (candidates) |candidate| {
        const distance = editDistance(input, candidate);

        // Only suggest if the edit distance is within threshold
        if (distance <= max_distance and distance < input.len) {
            try suggestions_with_distance.append(.{ .command = candidate, .distance = distance });
        }
    }

    // Sort by distance (closest matches first)
    std.mem.sort(@TypeOf(suggestions_with_distance.items[0]), suggestions_with_distance.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(suggestions_with_distance.items[0]), b: @TypeOf(suggestions_with_distance.items[0])) bool {
            return a.distance < b.distance;
        }
    }.lessThan);

    // Extract just the command names, limited to max_suggestions
    var result = std.ArrayList([]const u8).init(allocator);
    defer result.deinit();

    const limit = @min(max_suggestions, suggestions_with_distance.items.len);
    for (suggestions_with_distance.items[0..limit]) |item| {
        try result.append(item.command);
    }

    return result.toOwnedSlice();
}

// Tests
test "editDistance basic" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("hello", "hello"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("hello", "helo"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("hello", "helloo"));
    try std.testing.expectEqual(@as(usize, 2), editDistance("hello", "bell"));
    try std.testing.expectEqual(@as(usize, 4), editDistance("hello", "world"));
}

test "findSimilarCommands basic" {
    const commands = [_][]const u8{ "list", "search", "create", "delete", "status" };

    const suggestions = findSimilarCommands("serach", &commands, std.testing.allocator) catch &[_][]const u8{};
    defer if (suggestions.len > 0) std.testing.allocator.free(suggestions);
    try std.testing.expect(suggestions.len > 0);
    try std.testing.expectEqualStrings("search", suggestions[0]);
}

test "findSimilarCommandsWithConfig" {
    const commands = [_][]const u8{ "list", "search", "create", "delete", "status", "start" };

    const suggestions = try findSimilarCommandsWithConfig("stat", &commands, std.testing.allocator, 2, 3);
    defer std.testing.allocator.free(suggestions);
    
    try std.testing.expect(suggestions.len > 0);
    // Should find "status" and "start" as similar to "stat"
    var found_status = false;
    var found_start = false;
    for (suggestions) |suggestion| {
        if (std.mem.eql(u8, suggestion, "status")) found_status = true;
        if (std.mem.eql(u8, suggestion, "start")) found_start = true;
    }
    try std.testing.expect(found_status or found_start);
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