const std = @import("std");
const utils = @import("utils.zig");
const diagnostics = @import("../diagnostic_errors.zig");

/// One typed accumulator per array field. Scalar slots are void and allocate
/// nothing; enums retain their actual representation, including signed/wide tags.
pub fn ArrayLists(comptime Options: type) type {
    const fields = std.meta.fields(Options);
    var slots: [fields.len]type = undefined;
    for (fields, 0..) |field, i| {
        slots[i] = if (utils.isArrayType(field.type))
            std.ArrayList(@typeInfo(field.type).pointer.child)
        else
            void;
    }
    return std.meta.Tuple(&slots);
}

pub fn createArrayList(comptime T: type) std.ArrayList(T) {
    if (@typeInfo(T) != .@"enum") switch (T) {
        []const u8, i8, i16, i32, i64, u8, u16, u32, u64, f32, f64 => {},
        else => @compileError("Unsupported array element type: " ++ @typeName(T)),
    };
    return .empty;
}

/// Respect literal boundaries unless a delimiter is declared. Empty segments
/// are invalid only in delimited input. Allocation failures carry no diagnostic.
pub fn appendArrayValue(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayList(T), value: []const u8, delimiter: ?u8, option_name: []const u8, is_short: bool, diag: ?*?diagnostics.ZcliDiagnostic) !void {
    if (delimiter) |separator| {
        var it = std.mem.splitScalar(u8, value, separator);
        while (it.next()) |segment| {
            try appendElement(T, allocator, list, value, segment, true, option_name, is_short, diag);
        }
    } else {
        try appendElement(T, allocator, list, value, value, false, option_name, is_short, diag);
    }
}

fn appendElement(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayList(T), value: []const u8, segment: []const u8, delimited: bool, option_name: []const u8, is_short: bool, diag: ?*?diagnostics.ZcliDiagnostic) !void {
    const parsed = if (delimited and segment.len == 0) error.InvalidOptionValue else utils.parseOptionValue(T, segment);
    const element = parsed catch |err| {
        if (diag) |d| d.* = .{ .OptionInvalidValue = .{
            .option_name = option_name,
            .is_short = is_short,
            .provided_value = if (@typeInfo(T) == .@"enum") segment else value,
            .expected_type = diagnostics.expectedTypeName(T),
            .suggestion = diagnostics.nearestEnumValue(T, segment),
        } };
        return err;
    };
    try list.append(allocator, element);
}

fn appendCsv(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayList(T), value: []const u8, option_name: []const u8, is_short: bool, diag: ?*?diagnostics.ZcliDiagnostic) !void {
    try appendArrayValue(T, allocator, list, value, ',', option_name, is_short, diag);
}

// Tests
test "typed arrays parse strings and numbers into owned slices" {
    const allocator = std.testing.allocator;

    // Test string arrays
    {
        var list = createArrayList([]const u8);
        defer list.deinit(allocator);

        try appendCsv([]const u8, allocator, &list, "first", "test", false, null);
        try appendCsv([]const u8, allocator, &list, "second", "test", false, null);

        const result = try list.toOwnedSlice(allocator);
        defer allocator.free(result);

        try std.testing.expectEqual(@as(usize, 2), result.len);
        try std.testing.expectEqualStrings("first", result[0]);
        try std.testing.expectEqualStrings("second", result[1]);
    }

    // Test integer arrays
    {
        var list = createArrayList(i32);
        defer list.deinit(allocator);

        try appendCsv(i32, allocator, &list, "42", "numbers", false, null);
        try appendCsv(i32, allocator, &list, "-10", "numbers", false, null);

        const result = try list.toOwnedSlice(allocator);
        defer allocator.free(result);

        try std.testing.expectEqual(@as(usize, 2), result.len);
        try std.testing.expectEqual(@as(i32, 42), result[0]);
        try std.testing.expectEqual(@as(i32, -10), result[1]);
    }

    // Test invalid integer should error
    {
        var list = createArrayList(i32);
        defer list.deinit(allocator);

        try std.testing.expectError(error.InvalidOptionValue, appendCsv(i32, allocator, &list, "not_a_number", "test", false, null));
    }
}

test "short array values use the same element parser" {
    const allocator = std.testing.allocator;

    // Test with short option
    var list = createArrayList([]const u8);
    defer list.deinit(allocator);

    try appendCsv([]const u8, allocator, &list, "value1", "f", true, null);
    try appendCsv([]const u8, allocator, &list, "value2", "f", true, null);

    const result = try list.toOwnedSlice(allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("value1", result[0]);
    try std.testing.expectEqualStrings("value2", result[1]);
}

test "CSV splits on comma and rejects empty segments" {
    const allocator = std.testing.allocator;

    // Strings split into elements.
    {
        var list = createArrayList([]const u8);
        defer list.deinit(allocator);

        try appendCsv([]const u8, allocator, &list, "a,b,c", "tags", false, null);
        const result = try list.toOwnedSlice(allocator);
        defer allocator.free(result);

        try std.testing.expectEqual(@as(usize, 3), result.len);
        try std.testing.expectEqualStrings("a", result[0]);
        try std.testing.expectEqualStrings("b", result[1]);
        try std.testing.expectEqualStrings("c", result[2]);
    }

    // A single value (no comma) yields one element.
    {
        var list = createArrayList([]const u8);
        defer list.deinit(allocator);

        try appendCsv([]const u8, allocator, &list, "solo", "tags", false, null);
        const result = try list.toOwnedSlice(allocator);
        defer allocator.free(result);

        try std.testing.expectEqual(@as(usize, 1), result.len);
        try std.testing.expectEqualStrings("solo", result[0]);
    }

    // Numeric elements are parsed per-segment.
    {
        var list = createArrayList(i32);
        defer list.deinit(allocator);

        try appendCsv(i32, allocator, &list, "1,-2,3", "nums", false, null);
        const result = try list.toOwnedSlice(allocator);
        defer allocator.free(result);

        try std.testing.expectEqualSlices(i32, &.{ 1, -2, 3 }, result);
    }

    // Empty segments (interior, leading, trailing) are rejected.
    {
        var list = createArrayList([]const u8);
        defer list.deinit(allocator);

        try std.testing.expectError(error.InvalidOptionValue, appendCsv([]const u8, allocator, &list, "a,,b", "tags", false, null));
        try std.testing.expectError(error.InvalidOptionValue, appendCsv([]const u8, allocator, &list, ",a", "f", true, null));
        try std.testing.expectError(error.InvalidOptionValue, appendCsv([]const u8, allocator, &list, "a,", "tags", false, null));
    }
}

// Tests migrated from array_options_test.zig
test "parseOptions with array of strings (filter option)" {
    const allocator = std.testing.allocator;
    const options = @import("../options.zig");

    // Define an Options struct similar to container ls
    const TestOptions = struct {
        all: bool = false,
        filter: []const []const u8 = &.{},
        quiet: bool = false,
    };

    // Test case 1: No filter options provided
    {
        const args = [_][]const u8{"--all"};
        const parsed = try options.parseOptions(TestOptions, allocator, &args, null);
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.all == true);
        try std.testing.expect(parsed.options.filter.len == 0);
        try std.testing.expect(parsed.options.quiet == false);
    }

    // Test case 2: Single filter option
    {
        const args = [_][]const u8{ "--filter", "status=running" };
        const parsed = try options.parseOptions(TestOptions, allocator, &args, null);
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.all == false);
        try std.testing.expect(parsed.options.filter.len == 1);
        try std.testing.expectEqualStrings(parsed.options.filter[0], "status=running");
    }

    // Test case 3: Multiple filter options
    {
        const args = [_][]const u8{ "--filter", "status=running", "--filter", "name=web" };
        const parsed = try options.parseOptions(TestOptions, allocator, &args, null);
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.filter.len == 2);
        try std.testing.expectEqualStrings(parsed.options.filter[0], "status=running");
        try std.testing.expectEqualStrings(parsed.options.filter[1], "name=web");
    }

    // Test case 4: Mixed options with filters
    {
        const args = [_][]const u8{ "--all", "--filter", "status=exited", "--quiet" };
        const parsed = try options.parseOptions(TestOptions, allocator, &args, null);
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.all == true);
        try std.testing.expect(parsed.options.quiet == true);
        try std.testing.expect(parsed.options.filter.len == 1);
        try std.testing.expectEqualStrings(parsed.options.filter[0], "status=exited");
    }
}

test "array options default initialization" {
    const allocator = std.testing.allocator;
    const options = @import("../options.zig");

    const TestOptions = struct {
        filter: []const []const u8 = &.{},
        env: []const []const u8 = &.{},
        volume: []const []const u8 = &.{},
    };

    // Parse with no arguments - should use defaults
    const args = [_][]const u8{};
    const parsed = try options.parseOptions(TestOptions, allocator, &args, null);
    defer options.cleanupOptions(TestOptions, parsed.options, allocator);

    // All array options should be empty but valid (not null/undefined)
    try std.testing.expect(parsed.options.filter.len == 0);
    try std.testing.expect(parsed.options.env.len == 0);
    try std.testing.expect(parsed.options.volume.len == 0);

    // Should be safe to iterate over empty arrays
    for (parsed.options.filter) |f| {
        _ = f; // This should not crash
    }
    for (parsed.options.env) |e| {
        _ = e; // This should not crash
    }
    for (parsed.options.volume) |v| {
        _ = v; // This should not crash
    }
}

test "basic array options iteration" {
    const allocator = std.testing.allocator;
    const options = @import("../options.zig");

    const TestOptions = struct {
        filter: []const []const u8 = &.{},
        env: []const []const u8 = &.{},
    };

    // Test with no options provided
    {
        const args = [_][]const u8{};
        const parsed = try options.parseOptions(TestOptions, allocator, &args, null);
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        // This should not crash even with default empty arrays
        try std.testing.expect(parsed.options.filter.len == 0);
        try std.testing.expect(parsed.options.env.len == 0);

        // Should be safe to iterate
        for (parsed.options.filter) |filter| {
            _ = filter;
        }

        for (parsed.options.env) |env| {
            _ = env;
        }
    }

    // Test with array options provided
    {
        const args = [_][]const u8{ "--filter", "test=value", "--env", "FOO=bar" };
        const parsed = try options.parseOptions(TestOptions, allocator, &args, null);
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.filter.len == 1);
        try std.testing.expect(parsed.options.env.len == 1);

        // Should be safe to iterate
        for (parsed.options.filter) |filter| {
            try std.testing.expectEqualStrings(filter, "test=value");
        }

        for (parsed.options.env) |env| {
            try std.testing.expectEqualStrings(env, "FOO=bar");
        }
    }
}

test "actual container ls options parsing" {
    const allocator = std.testing.allocator;
    const options = @import("../options.zig");

    // This is the actual Options struct from container ls
    const ContainerLsOptions = struct {
        all: bool = false,
        filter: []const []const u8 = &.{},
        format: ?[]const u8 = null,
        last: ?u32 = null,
        latest: bool = false,
        no_trunc: bool = false,
        quiet: bool = false,
        size: bool = false,
    };

    // Test the exact case that was causing segfault
    {
        const args = [_][]const u8{"--all"};
        const parsed = try options.parseOptions(ContainerLsOptions, allocator, &args, null);
        defer options.cleanupOptions(ContainerLsOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.all == true);
        try std.testing.expect(parsed.options.filter.len == 0);

        // This iteration was causing the segfault in the real code
        for (parsed.options.filter) |filter| {
            _ = filter;
        }
    }
}
