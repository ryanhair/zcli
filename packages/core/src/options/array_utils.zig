const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");
const logging = @import("../logging.zig");

// Union type to handle different ArrayList types for array accumulation
// Now much cleaner with generic helper functions doing the heavy lifting
pub const ArrayListUnion = union(enum) {
    strings: std.ArrayList([]const u8),
    i32s: std.ArrayList(i32),
    u32s: std.ArrayList(u32),
    i16s: std.ArrayList(i16),
    u16s: std.ArrayList(u16),
    i8s: std.ArrayList(i8),
    u8s: std.ArrayList(u8),
    i64s: std.ArrayList(i64),
    u64s: std.ArrayList(u64),
    f32s: std.ArrayList(f32),
    f64s: std.ArrayList(f64),

    pub fn deinit(self: *ArrayListUnion, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*list| list.deinit(allocator),
        }
    }
};

/// Create ArrayListUnion for a given element type
/// Uses comptime to eliminate repetition and ensure type safety
pub fn createArrayListUnion(comptime ElementType: type) ArrayListUnion {
    return switch (ElementType) {
        []const u8 => .{ .strings = std.ArrayList([]const u8){} },
        i32 => .{ .i32s = std.ArrayList(i32){} },
        u32 => .{ .u32s = std.ArrayList(u32){} },
        i16 => .{ .i16s = std.ArrayList(i16){} },
        u16 => .{ .u16s = std.ArrayList(u16){} },
        i8 => .{ .i8s = std.ArrayList(i8){} },
        u8 => .{ .u8s = std.ArrayList(u8){} },
        i64 => .{ .i64s = std.ArrayList(i64){} },
        u64 => .{ .u64s = std.ArrayList(u64){} },
        f32 => .{ .f32s = std.ArrayList(f32){} },
        f64 => .{ .f64s = std.ArrayList(f64){} },
        else => @compileError("Unsupported array element type: " ++ @typeName(ElementType)),
    };
}

/// Helper function to get the union field name for a given type
fn getFieldName(comptime T: type) []const u8 {
    return switch (T) {
        []const u8 => "strings",
        i32 => "i32s",
        u32 => "u32s",
        i16 => "i16s",
        u16 => "u16s",
        i8 => "i8s",
        u8 => "u8s",
        i64 => "i64s",
        u64 => "u64s",
        f32 => "f32s",
        f64 => "f64s",
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    };
}

/// Generic helper to append a value to an ArrayListUnion
/// Replaces ~80 lines of repetitive switch cases with clean generic code
pub fn appendToArrayListUnion(comptime ElementType: type, allocator: std.mem.Allocator, list_union: *ArrayListUnion, value: []const u8, option_name: []const u8) !void {
    switch (comptime ElementType) {
        []const u8 => try list_union.strings.append(allocator, value),
        inline i32, u32, i16, u16, i8, u8, i64, u64, f32, f64 => |T| {
            const field_name = comptime getFieldName(T);
            const parsed = utils.parseOptionValue(T, value) catch |err| {
                logging.invalidOptionValue(option_name, value, "value");
                return err;
            };
            try @field(list_union, field_name).append(allocator, parsed);
        },
        else => @compileError("Unsupported array element type: " ++ @typeName(ElementType)),
    }
}

/// Generic helper to append a value to an ArrayListUnion (for short options)
/// Replaces ~80 lines of repetitive switch cases with clean generic code
pub fn appendToArrayListUnionShort(comptime ElementType: type, allocator: std.mem.Allocator, list_union: *ArrayListUnion, value: []const u8, char: u8) !void {
    switch (comptime ElementType) {
        []const u8 => try list_union.strings.append(allocator, value),
        inline i32, u32, i16, u16, i8, u8, i64, u64, f32, f64 => |T| {
            const field_name = comptime getFieldName(T);
            const parsed = utils.parseOptionValue(T, value) catch |err| {
                logging.invalidShortOptionValue(char, value, "value");
                return err;
            };
            try @field(list_union, field_name).append(allocator, parsed);
        },
        else => @compileError("Unsupported array element type: " ++ @typeName(ElementType)),
    }
}

/// Generic helper to convert ArrayListUnion to owned slice
/// Replaces ~15 lines of repetitive switch cases with clean generic code
pub fn arrayListUnionToOwnedSlice(comptime ElementType: type, allocator: std.mem.Allocator, list_union: *ArrayListUnion) !ElementType {
    const ChildType = @typeInfo(ElementType).pointer.child;

    return switch (comptime ChildType) {
        []const u8 => list_union.strings.toOwnedSlice(allocator),
        inline i32, u32, i16, u16, i8, u8, i64, u64, f32, f64 => |T| {
            const field_name = comptime getFieldName(T);
            return @field(list_union, field_name).toOwnedSlice(allocator);
        },
        else => @compileError("Unsupported array element type: " ++ @typeName(ChildType)),
    };
}

// Tests
test "createArrayListUnion" {
    // Test string arrays
    const string_list = createArrayListUnion([]const u8);
    try std.testing.expect(string_list == .strings);

    // Test integer arrays
    const i32_list = createArrayListUnion(i32);
    try std.testing.expect(i32_list == .i32s);

    // Test float arrays
    const f64_list = createArrayListUnion(f64);
    try std.testing.expect(f64_list == .f64s);
}

test "appendToArrayListUnion and arrayListUnionToOwnedSlice" {
    const allocator = std.testing.allocator;

    // Test string arrays
    {
        var list = createArrayListUnion([]const u8);
        defer list.deinit(allocator);

        try appendToArrayListUnion([]const u8, allocator, &list, "first", "test");
        try appendToArrayListUnion([]const u8, allocator, &list, "second", "test");

        const result = try arrayListUnionToOwnedSlice([][]const u8, allocator, &list);
        defer allocator.free(result);

        try std.testing.expectEqual(@as(usize, 2), result.len);
        try std.testing.expectEqualStrings("first", result[0]);
        try std.testing.expectEqualStrings("second", result[1]);
    }

    // Test integer arrays
    {
        var list = createArrayListUnion(i32);
        defer list.deinit(allocator);

        try appendToArrayListUnion(i32, allocator, &list, "42", "numbers");
        try appendToArrayListUnion(i32, allocator, &list, "-10", "numbers");

        const result = try arrayListUnionToOwnedSlice([]i32, allocator, &list);
        defer allocator.free(result);

        try std.testing.expectEqual(@as(usize, 2), result.len);
        try std.testing.expectEqual(@as(i32, 42), result[0]);
        try std.testing.expectEqual(@as(i32, -10), result[1]);
    }

    // Test invalid integer should error
    {
        var list = createArrayListUnion(i32);
        defer list.deinit(allocator);

        try std.testing.expectError(error.InvalidOptionValue, appendToArrayListUnion(i32, allocator, &list, "not_a_number", "test"));
    }
}

test "appendToArrayListUnionShort" {
    const allocator = std.testing.allocator;

    // Test with short option
    var list = createArrayListUnion([]const u8);
    defer list.deinit(allocator);

    try appendToArrayListUnionShort([]const u8, allocator, &list, "value1", 'f');
    try appendToArrayListUnionShort([]const u8, allocator, &list, "value2", 'f');

    const result = try arrayListUnionToOwnedSlice([][]const u8, allocator, &list);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("value1", result[0]);
    try std.testing.expectEqualStrings("value2", result[1]);
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
        const parsed = options.parseOptions(TestOptions, allocator, &args) catch |err| {
            std.debug.print("Parse error: {any}\n", .{err});
            return error.ParseFailed;
        };
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.all == true);
        try std.testing.expect(parsed.options.filter.len == 0);
        try std.testing.expect(parsed.options.quiet == false);
    }

    // Test case 2: Single filter option
    {
        const args = [_][]const u8{ "--filter", "status=running" };
        const parsed = options.parseOptions(TestOptions, allocator, &args) catch |err| {
            std.debug.print("Parse error: {any}\n", .{err});
            return error.ParseFailed;
        };
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.all == false);
        try std.testing.expect(parsed.options.filter.len == 1);
        try std.testing.expectEqualStrings(parsed.options.filter[0], "status=running");
    }

    // Test case 3: Multiple filter options
    {
        const args = [_][]const u8{ "--filter", "status=running", "--filter", "name=web" };
        const parsed = options.parseOptions(TestOptions, allocator, &args) catch |err| {
            std.debug.print("Parse error: {any}\n", .{err});
            return error.ParseFailed;
        };
        defer options.cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.filter.len == 2);
        try std.testing.expectEqualStrings(parsed.options.filter[0], "status=running");
        try std.testing.expectEqualStrings(parsed.options.filter[1], "name=web");
    }

    // Test case 4: Mixed options with filters
    {
        const args = [_][]const u8{ "--all", "--filter", "status=exited", "--quiet" };
        const parsed = options.parseOptions(TestOptions, allocator, &args) catch |err| {
            std.debug.print("Parse error: {any}\n", .{err});
            return error.ParseFailed;
        };
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
    const parsed = options.parseOptions(TestOptions, allocator, &args) catch |err| {
        std.debug.print("Parse error: {any}\n", .{err});
        return error.ParseFailed;
    };
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
        const parsed = options.parseOptions(TestOptions, allocator, &args) catch |err| {
            std.debug.print("Parse error: {any}\n", .{err});
            return error.ParseFailed;
        };
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
        const parsed = options.parseOptions(TestOptions, allocator, &args) catch |err| {
            std.debug.print("Parse error: {any}\n", .{err});
            return error.ParseFailed;
        };
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
        const parsed = options.parseOptions(ContainerLsOptions, allocator, &args) catch |err| {
            std.debug.print("Parse error: {any}\n", .{err});
            return error.ParseFailed;
        };
        defer options.cleanupOptions(ContainerLsOptions, parsed.options, allocator);

        try std.testing.expect(parsed.options.all == true);
        try std.testing.expect(parsed.options.filter.len == 0);

        // This iteration was causing the segfault in the real code
        for (parsed.options.filter) |filter| {
            _ = filter;
        }
    }
}
