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

    pub fn deinit(self: *ArrayListUnion) void {
        switch (self.*) {
            inline else => |*list| list.deinit(),
        }
    }
};

/// Create ArrayListUnion for a given element type
/// Uses comptime to eliminate repetition and ensure type safety
pub fn createArrayListUnion(comptime ElementType: type, allocator: std.mem.Allocator) ArrayListUnion {
    return switch (ElementType) {
        []const u8 => .{ .strings = std.ArrayList([]const u8).init(allocator) },
        i32 => .{ .i32s = std.ArrayList(i32).init(allocator) },
        u32 => .{ .u32s = std.ArrayList(u32).init(allocator) },
        i16 => .{ .i16s = std.ArrayList(i16).init(allocator) },
        u16 => .{ .u16s = std.ArrayList(u16).init(allocator) },
        i8 => .{ .i8s = std.ArrayList(i8).init(allocator) },
        u8 => .{ .u8s = std.ArrayList(u8).init(allocator) },
        i64 => .{ .i64s = std.ArrayList(i64).init(allocator) },
        u64 => .{ .u64s = std.ArrayList(u64).init(allocator) },
        f32 => .{ .f32s = std.ArrayList(f32).init(allocator) },
        f64 => .{ .f64s = std.ArrayList(f64).init(allocator) },
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
pub fn appendToArrayListUnion(comptime ElementType: type, list_union: *ArrayListUnion, value: []const u8, option_name: []const u8) !void {
    switch (comptime ElementType) {
        []const u8 => try list_union.strings.append(value),
        inline i32, u32, i16, u16, i8, u8, i64, u64, f32, f64 => |T| {
            const field_name = comptime getFieldName(T);
            const parsed = utils.parseOptionValue(T, value) catch |err| {
                logging.invalidOptionValue(option_name, value, "value");
                return err;
            };
            try @field(list_union, field_name).append(parsed);
        },
        else => @compileError("Unsupported array element type: " ++ @typeName(ElementType)),
    }
}

/// Generic helper to append a value to an ArrayListUnion (for short options)
/// Replaces ~80 lines of repetitive switch cases with clean generic code
pub fn appendToArrayListUnionShort(comptime ElementType: type, list_union: *ArrayListUnion, value: []const u8, char: u8) !void {
    switch (comptime ElementType) {
        []const u8 => try list_union.strings.append(value),
        inline i32, u32, i16, u16, i8, u8, i64, u64, f32, f64 => |T| {
            const field_name = comptime getFieldName(T);
            const parsed = utils.parseOptionValue(T, value) catch |err| {
                logging.invalidShortOptionValue(char, value, "value");
                return err;
            };
            try @field(list_union, field_name).append(parsed);
        },
        else => @compileError("Unsupported array element type: " ++ @typeName(ElementType)),
    }
}

/// Generic helper to convert ArrayListUnion to owned slice
/// Replaces ~15 lines of repetitive switch cases with clean generic code
pub fn arrayListUnionToOwnedSlice(comptime ElementType: type, list_union: *ArrayListUnion) !ElementType {
    const ChildType = @typeInfo(ElementType).pointer.child;

    return switch (comptime ChildType) {
        []const u8 => list_union.strings.toOwnedSlice(),
        inline i32, u32, i16, u16, i8, u8, i64, u64, f32, f64 => |T| {
            const field_name = comptime getFieldName(T);
            return @field(list_union, field_name).toOwnedSlice();
        },
        else => @compileError("Unsupported array element type: " ++ @typeName(ChildType)),
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

        try std.testing.expectError(error.InvalidOptionValue, appendToArrayListUnion(i32, &list, "not_a_number", "test"));
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
