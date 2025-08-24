const std = @import("std");
const types = @import("types.zig");
const logging = @import("../logging.zig");

/// Convert dashes to underscores in option names
pub fn dashesToUnderscores(buf: []u8, input: []const u8) ![]const u8 {
    if (input.len > buf.len) {
        logging.optionNameTooLong(input, @intCast(buf.len));
        return error.UnknownOption;
    }

    for (input, 0..) |char, i| {
        buf[i] = if (char == '-') '_' else char;
    }

    return buf[0..input.len];
}

/// Check if a string starting with '-' is actually a negative number, not an option
pub fn isNegativeNumber(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') {
        return false;
    }

    // Check if the second character is a digit
    if (arg[1] >= '0' and arg[1] <= '9') {
        return true;
    }

    // Check for decimal point (e.g., "-0.5", "-.5")
    if (arg[1] == '.' and arg.len > 2 and arg[2] >= '0' and arg[2] <= '9') {
        return true;
    }

    return false;
}

/// Check if a type is boolean
pub fn isBooleanType(comptime T: type) bool {
    return T == bool;
}

/// Check if a type is an array type (for accumulating values)
/// Returns true for arrays like [][]const u8, []i32, etc.
/// Returns false for strings like []const u8
pub fn isArrayType(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info != .pointer or type_info.pointer.size != .slice) {
        return false;
    }

    // []const u8 is a string, not an array for accumulation
    if (type_info.pointer.child == u8) {
        return false;
    }

    return true;
}

/// Parse a value for an option
pub fn parseOptionValue(comptime T: type, value: []const u8) !T {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                return value;
            } else {
                @compileError("Unsupported option type: " ++ @typeName(T));
            }
        },
        .int => {
            // Use base 10 exclusively to avoid ambiguity with octal (010) or hex (0x10)
            return std.fmt.parseInt(T, value, 10) catch {
                return error.InvalidOptionValue;
            };
        },
        .float => {
            return std.fmt.parseFloat(T, value) catch {
                return error.InvalidOptionValue;
            };
        },
        .@"enum" => {
            return std.meta.stringToEnum(T, value) orelse {
                return error.InvalidOptionValue;
            };
        },
        .optional => |opt_info| {
            return try parseOptionValue(opt_info.child, value);
        },
        else => {
            @compileError("Unsupported option type: " ++ @typeName(T));
        },
    }
}

// Tests

test "isNegativeNumber function" {
    try std.testing.expect(isNegativeNumber("-123"));
    try std.testing.expect(isNegativeNumber("-0.5"));
    try std.testing.expect(isNegativeNumber("-.5"));
    try std.testing.expect(isNegativeNumber("-1.0"));

    try std.testing.expect(!isNegativeNumber("--option"));
    try std.testing.expect(!isNegativeNumber("-option"));
    try std.testing.expect(!isNegativeNumber("123"));
    try std.testing.expect(!isNegativeNumber("0.5"));
    try std.testing.expect(!isNegativeNumber("-"));
    try std.testing.expect(!isNegativeNumber(""));
}

test "dashesToUnderscores function" {
    var buf: [64]u8 = undefined;

    // Basic conversion
    const result1 = try dashesToUnderscores(&buf, "no-color");
    try std.testing.expectEqualStrings("no_color", result1);

    // Multiple dashes
    const result2 = try dashesToUnderscores(&buf, "log-level-max");
    try std.testing.expectEqualStrings("log_level_max", result2);

    // No dashes
    const result3 = try dashesToUnderscores(&buf, "verbose");
    try std.testing.expectEqualStrings("verbose", result3);

    // Too long for fixed buffer - should fail
    const long_name = "this-is-a-very-long-option-name-that-exceeds-the-maximum-allowed-length";
    try std.testing.expectError(error.UnknownOption, dashesToUnderscores(&buf, long_name));
    
    // Test with dynamic allocation - should succeed
    const allocator = std.testing.allocator;
    const dynamic_buf = try allocator.alloc(u8, long_name.len);
    defer allocator.free(dynamic_buf);
    const result4 = try dashesToUnderscores(dynamic_buf, long_name);
    try std.testing.expectEqualStrings("this_is_a_very_long_option_name_that_exceeds_the_maximum_allowed_length", result4);
}

test "parseOptionValue integer types" {
    // Valid integers
    try std.testing.expectEqual(@as(i32, 42), try parseOptionValue(i32, "42"));
    try std.testing.expectEqual(@as(u16, 8080), try parseOptionValue(u16, "8080"));
    try std.testing.expectEqual(@as(i64, -123), try parseOptionValue(i64, "-123"));

    // Invalid integers
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(i32, "not_a_number"));
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(u8, "256"));
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(u32, "-1"));
}

test "parseOptionValue decimal-only parsing" {
    // Leading zeros should be parsed as decimal, not octal
    try std.testing.expectEqual(@as(i32, 10), try parseOptionValue(i32, "010"));
    try std.testing.expectEqual(@as(i32, 8), try parseOptionValue(i32, "08"));
    try std.testing.expectEqual(@as(i32, 9), try parseOptionValue(i32, "09"));
    try std.testing.expectEqual(@as(i32, 7), try parseOptionValue(i32, "007"));
    try std.testing.expectEqual(@as(i32, 0), try parseOptionValue(i32, "0"));
    try std.testing.expectEqual(@as(i32, 0), try parseOptionValue(i32, "00"));
    try std.testing.expectEqual(@as(i32, 0), try parseOptionValue(i32, "000"));
    
    // Hex notation should fail (no longer auto-detected)
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(i32, "0x10"));
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(i32, "0X10"));
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(i32, "0xABC"));
    
    // Binary notation should fail
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(i32, "0b101"));
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(i32, "0B101"));
    
    // Octal notation (0o prefix) should fail
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(i32, "0o10"));
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(i32, "0O10"));
    
    // Boundary values
    try std.testing.expectEqual(@as(i8, 127), try parseOptionValue(i8, "127"));
    try std.testing.expectEqual(@as(i8, -128), try parseOptionValue(i8, "-128"));
    try std.testing.expectEqual(@as(u8, 255), try parseOptionValue(u8, "255"));
    try std.testing.expectEqual(@as(u8, 0), try parseOptionValue(u8, "0"));
    
    // Edge cases with whitespace (parseInt handles this)
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(i32, " 42"));
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(i32, "42 "));
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(i32, ""));
}

test "parseOptionValue float types" {
    // Valid floats
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), try parseOptionValue(f32, "3.14"), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -2.5), try parseOptionValue(f64, "-2.5"), 0.001);

    // Invalid floats
    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(f32, "not_a_float"));
}

test "parseOptionValue string types" {
    const value = try parseOptionValue([]const u8, "hello");
    try std.testing.expectEqualStrings("hello", value);
}

test "parseOptionValue enum types" {
    const LogLevel = enum { debug, info, warn, err };

    try std.testing.expectEqual(LogLevel.debug, try parseOptionValue(LogLevel, "debug"));
    try std.testing.expectEqual(LogLevel.err, try parseOptionValue(LogLevel, "err"));

    try std.testing.expectError(error.InvalidOptionValue, parseOptionValue(LogLevel, "invalid"));
}

test "parseOptionValue optional types" {
    const value1 = try parseOptionValue(?i32, "42");
    try std.testing.expectEqual(@as(i32, 42), value1.?);

    const value2 = try parseOptionValue(?[]const u8, "test");
    try std.testing.expectEqualStrings("test", value2.?);
}

test "isBooleanType function" {
    try std.testing.expect(isBooleanType(bool));
    try std.testing.expect(!isBooleanType(u8));
    try std.testing.expect(!isBooleanType([]const u8));
    try std.testing.expect(!isBooleanType(?bool));
}

test "isArrayType function" {
    try std.testing.expect(isArrayType([][]const u8));
    try std.testing.expect(isArrayType([]i32));
    try std.testing.expect(isArrayType([]f64));

    try std.testing.expect(!isArrayType([]const u8)); // String, not array
    try std.testing.expect(!isArrayType(u32));
    try std.testing.expect(!isArrayType(bool));
}
