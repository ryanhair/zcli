const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");

// Union type to handle different ArrayList types for array accumulation
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

    pub fn deinit(self: *ArrayListUnion) void {
        switch (self.*) {
            inline else => |*list| list.deinit(),
        }
    }
};

/// Generic helper to create ArrayListUnion for a given element type
pub fn createArrayListUnion(comptime ElementType: type, allocator: std.mem.Allocator) ArrayListUnion {
    return switch (ElementType) {
        []const u8 => ArrayListUnion{ .strings = std.ArrayList([]const u8).init(allocator) },
        i32 => ArrayListUnion{ .i32s = std.ArrayList(i32).init(allocator) },
        u32 => ArrayListUnion{ .u32s = std.ArrayList(u32).init(allocator) },
        i16 => ArrayListUnion{ .i16s = std.ArrayList(i16).init(allocator) },
        u16 => ArrayListUnion{ .u16s = std.ArrayList(u16).init(allocator) },
        i8 => ArrayListUnion{ .i8s = std.ArrayList(i8).init(allocator) },
        u8 => ArrayListUnion{ .u8s = std.ArrayList(u8).init(allocator) },
        i64 => ArrayListUnion{ .i64s = std.ArrayList(i64).init(allocator) },
        u64 => ArrayListUnion{ .u64s = std.ArrayList(u64).init(allocator) },
        f32 => ArrayListUnion{ .f32s = std.ArrayList(f32).init(allocator) },
        f64 => ArrayListUnion{ .f64s = std.ArrayList(f64).init(allocator) },
        else => @compileError("Unsupported array element type: " ++ @typeName(ElementType)),
    };
}

/// Generic helper to append a value to an ArrayListUnion
pub fn appendToArrayListUnion(comptime ElementType: type, list_union: *ArrayListUnion, value: []const u8, option_name: []const u8) !void {
    return switch (ElementType) {
        []const u8 => list_union.strings.append(value),
        i32 => blk: {
            const parsed_value = utils.parseOptionValue(i32, value) catch |err| {
                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                return err;
            };
            break :blk list_union.i32s.append(parsed_value);
        },
        u32 => blk: {
            const parsed_value = utils.parseOptionValue(u32, value) catch |err| {
                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                return err;
            };
            break :blk list_union.u32s.append(parsed_value);
        },
        i16 => blk: {
            const parsed_value = utils.parseOptionValue(i16, value) catch |err| {
                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                return err;
            };
            break :blk list_union.i16s.append(parsed_value);
        },
        u16 => blk: {
            const parsed_value = utils.parseOptionValue(u16, value) catch |err| {
                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                return err;
            };
            break :blk list_union.u16s.append(parsed_value);
        },
        i8 => blk: {
            const parsed_value = utils.parseOptionValue(i8, value) catch |err| {
                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                return err;
            };
            break :blk list_union.i8s.append(parsed_value);
        },
        u8 => blk: {
            const parsed_value = utils.parseOptionValue(u8, value) catch |err| {
                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                return err;
            };
            break :blk list_union.u8s.append(parsed_value);
        },
        i64 => blk: {
            const parsed_value = utils.parseOptionValue(i64, value) catch |err| {
                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                return err;
            };
            break :blk list_union.i64s.append(parsed_value);
        },
        u64 => blk: {
            const parsed_value = utils.parseOptionValue(u64, value) catch |err| {
                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                return err;
            };
            break :blk list_union.u64s.append(parsed_value);
        },
        f32 => blk: {
            const parsed_value = utils.parseOptionValue(f32, value) catch |err| {
                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                return err;
            };
            break :blk list_union.f32s.append(parsed_value);
        },
        f64 => blk: {
            const parsed_value = utils.parseOptionValue(f64, value) catch |err| {
                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                return err;
            };
            break :blk list_union.f64s.append(parsed_value);
        },
        else => @compileError("Unsupported array element type: " ++ @typeName(ElementType)),
    };
}

/// Generic helper to append a value to an ArrayListUnion (for short options)
pub fn appendToArrayListUnionShort(comptime ElementType: type, list_union: *ArrayListUnion, value: []const u8, char: u8) !void {
    return switch (ElementType) {
        []const u8 => list_union.strings.append(value),
        i32 => blk: {
            const parsed_value = utils.parseOptionValue(i32, value) catch |err| {
                std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                return err;
            };
            break :blk list_union.i32s.append(parsed_value);
        },
        u32 => blk: {
            const parsed_value = utils.parseOptionValue(u32, value) catch |err| {
                std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                return err;
            };
            break :blk list_union.u32s.append(parsed_value);
        },
        i16 => blk: {
            const parsed_value = utils.parseOptionValue(i16, value) catch |err| {
                std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                return err;
            };
            break :blk list_union.i16s.append(parsed_value);
        },
        u16 => blk: {
            const parsed_value = utils.parseOptionValue(u16, value) catch |err| {
                std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                return err;
            };
            break :blk list_union.u16s.append(parsed_value);
        },
        i8 => blk: {
            const parsed_value = utils.parseOptionValue(i8, value) catch |err| {
                std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                return err;
            };
            break :blk list_union.i8s.append(parsed_value);
        },
        u8 => blk: {
            const parsed_value = utils.parseOptionValue(u8, value) catch |err| {
                std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                return err;
            };
            break :blk list_union.u8s.append(parsed_value);
        },
        i64 => blk: {
            const parsed_value = utils.parseOptionValue(i64, value) catch |err| {
                std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                return err;
            };
            break :blk list_union.i64s.append(parsed_value);
        },
        u64 => blk: {
            const parsed_value = utils.parseOptionValue(u64, value) catch |err| {
                std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                return err;
            };
            break :blk list_union.u64s.append(parsed_value);
        },
        f32 => blk: {
            const parsed_value = utils.parseOptionValue(f32, value) catch |err| {
                std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                return err;
            };
            break :blk list_union.f32s.append(parsed_value);
        },
        f64 => blk: {
            const parsed_value = utils.parseOptionValue(f64, value) catch |err| {
                std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                return err;
            };
            break :blk list_union.f64s.append(parsed_value);
        },
        else => @compileError("Unsupported array element type: " ++ @typeName(ElementType)),
    };
}

/// Generic helper to convert ArrayListUnion to owned slice
pub fn arrayListUnionToOwnedSlice(comptime ElementType: type, list_union: *ArrayListUnion) !ElementType {
    return switch (ElementType) {
        [][]const u8 => list_union.strings.toOwnedSlice(),
        []i32 => list_union.i32s.toOwnedSlice(),
        []u32 => list_union.u32s.toOwnedSlice(),
        []i16 => list_union.i16s.toOwnedSlice(),
        []u16 => list_union.u16s.toOwnedSlice(),
        []i8 => list_union.i8s.toOwnedSlice(),
        []u8 => list_union.u8s.toOwnedSlice(),
        []i64 => list_union.i64s.toOwnedSlice(),
        []u64 => list_union.u64s.toOwnedSlice(),
        []f32 => list_union.f32s.toOwnedSlice(),
        []f64 => list_union.f64s.toOwnedSlice(),
        else => @compileError("Unsupported array element type: " ++ @typeName(ElementType)),
    };
}

// Tests

test "createArrayListUnion" {
    const allocator = std.testing.allocator;

    // Test string arrays
    var string_list = createArrayListUnion([]const u8, allocator);
    defer string_list.deinit();
    try std.testing.expect(string_list == .strings);

    // Test integer arrays
    var i32_list = createArrayListUnion(i32, allocator);
    defer i32_list.deinit();
    try std.testing.expect(i32_list == .i32s);

    // Test float arrays
    var f64_list = createArrayListUnion(f64, allocator);
    defer f64_list.deinit();
    try std.testing.expect(f64_list == .f64s);
}

test "appendToArrayListUnion and arrayListUnionToOwnedSlice" {
    const allocator = std.testing.allocator;

    // Test string arrays
    {
        var list = createArrayListUnion([]const u8, allocator);
        defer list.deinit();

        try appendToArrayListUnion([]const u8, &list, "first", "test");
        try appendToArrayListUnion([]const u8, &list, "second", "test");

        const result = try arrayListUnionToOwnedSlice([][]const u8, &list);
        defer allocator.free(result);

        try std.testing.expectEqual(@as(usize, 2), result.len);
        try std.testing.expectEqualStrings("first", result[0]);
        try std.testing.expectEqualStrings("second", result[1]);
    }

    // Test integer arrays
    {
        var list = createArrayListUnion(i32, allocator);
        defer list.deinit();

        try appendToArrayListUnion(i32, &list, "42", "numbers");
        try appendToArrayListUnion(i32, &list, "-10", "numbers");

        const result = try arrayListUnionToOwnedSlice([]i32, &list);
        defer allocator.free(result);

        try std.testing.expectEqual(@as(usize, 2), result.len);
        try std.testing.expectEqual(@as(i32, 42), result[0]);
        try std.testing.expectEqual(@as(i32, -10), result[1]);
    }

    // Test invalid integer should error
    {
        var list = createArrayListUnion(i32, allocator);
        defer list.deinit();

        try std.testing.expectError(types.OptionParseError.InvalidOptionValue, appendToArrayListUnion(i32, &list, "not_a_number", "test"));
    }
}

test "appendToArrayListUnionShort" {
    const allocator = std.testing.allocator;

    // Test with short option
    var list = createArrayListUnion([]const u8, allocator);
    defer list.deinit();

    try appendToArrayListUnionShort([]const u8, &list, "value1", 'f');
    try appendToArrayListUnionShort([]const u8, &list, "value2", 'f');

    const result = try arrayListUnionToOwnedSlice([][]const u8, &list);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("value1", result[0]);
    try std.testing.expectEqualStrings("value2", result[1]);
}
