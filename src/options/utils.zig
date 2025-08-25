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

    const number_part = arg[1..];

    // Fast path: check for simple cases first (most common)
    // Check if the second character is a digit (common integer case)
    if (number_part[0] >= '0' and number_part[0] <= '9') {
        return isSimpleNumber(number_part);
    }

    // Fast path: check for decimal starting with dot (e.g., "-.5")
    if (number_part[0] == '.' and number_part.len > 1 and
        number_part[1] >= '0' and number_part[1] <= '9')
    {
        return isSimpleDecimal(number_part);
    }

    // Slow path: complex patterns
    return isComplexNumber(number_part);
}

/// Fast validation for simple numbers (digits with optional decimal point)
fn isSimpleNumber(s: []const u8) bool {
    var has_dot = false;
    var has_e = false;

    for (s) |c| {
        if (c == '.') {
            if (has_dot or has_e) return false; // Multiple dots or dot after e
            has_dot = true;
        } else if (c == 'e' or c == 'E') {
            if (has_e) return false; // Multiple e's
            has_e = true;
            // If we have scientific notation, delegate to complex validation
            return isValidScientificFloat(s);
        } else if (c < '0' or c > '9') {
            return false; // Invalid character
        }
    }
    return true;
}

/// Fast validation for simple decimals starting with dot
fn isSimpleDecimal(s: []const u8) bool {
    if (s[0] != '.') return false;

    for (s[1..]) |c| {
        if (c == 'e' or c == 'E') {
            // Scientific notation, delegate to complex validation
            return isValidScientificFloat(s);
        } else if (c < '0' or c > '9') {
            return false; // Invalid character
        }
    }
    return true;
}

/// Handle complex number patterns (special values, scientific notation)
fn isComplexNumber(s: []const u8) bool {
    // Check for IEEE 754 special values
    if (std.ascii.eqlIgnoreCase(s, "inf") or
        std.ascii.eqlIgnoreCase(s, "infinity") or
        std.ascii.eqlIgnoreCase(s, "nan"))
    {
        return true;
    }

    // Check for scientific notation pattern
    if (hasScientificNotation(s)) {
        return isValidScientificFloat(s);
    }

    // Check for decimal pattern that wasn't caught by fast path
    if (hasDecimalPoint(s)) {
        return isValidDecimalFloat(s);
    }

    // Check for integer pattern
    return isValidInteger(s);
}

/// Check if string contains scientific notation (e or E)
fn hasScientificNotation(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "e") != null or std.mem.indexOf(u8, s, "E") != null;
}

/// Check if string contains a decimal point
fn hasDecimalPoint(s: []const u8) bool {
    return std.mem.indexOf(u8, s, ".") != null;
}

/// Validate scientific notation format
fn isValidScientificFloat(s: []const u8) bool {
    // Find the e/E position
    const e_pos = std.mem.indexOf(u8, s, "e") orelse std.mem.indexOf(u8, s, "E") orelse return false;

    if (e_pos == 0 or e_pos == s.len - 1) return false; // e/E can't be at start or end

    const mantissa = s[0..e_pos];
    const exponent = s[e_pos + 1 ..];

    // Validate mantissa (can be decimal or integer)
    const mantissa_valid = if (hasDecimalPoint(mantissa))
        isValidDecimalFloat(mantissa)
    else
        isValidInteger(mantissa);

    // Validate exponent (must be integer, can have + or -)
    const exponent_valid = if (exponent.len > 0 and (exponent[0] == '+' or exponent[0] == '-'))
        isValidInteger(exponent[1..])
    else
        isValidInteger(exponent);

    return mantissa_valid and exponent_valid;
}

/// Validate decimal float format
fn isValidDecimalFloat(s: []const u8) bool {
    if (s.len == 0) return false;

    var dot_count: usize = 0;
    var digit_count: usize = 0;

    for (s) |c| {
        if (c == '.') {
            dot_count += 1;
            if (dot_count > 1) return false; // Multiple dots invalid
        } else if (c >= '0' and c <= '9') {
            digit_count += 1;
        } else {
            return false; // Invalid character
        }
    }

    // Must have at least one digit and exactly one dot
    return dot_count == 1 and digit_count > 0;
}

/// Validate integer format
fn isValidInteger(s: []const u8) bool {
    if (s.len == 0) return false;

    for (s) |c| {
        if (c < '0' or c > '9') {
            return false;
        }
    }

    return true;
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

/// Enhanced float parsing with IEEE 754 special values support
pub fn parseFloat(comptime T: type, value: []const u8) !T {
    // Handle special IEEE 754 values
    if (std.ascii.eqlIgnoreCase(value, "inf") or
        std.ascii.eqlIgnoreCase(value, "infinity"))
    {
        return std.math.inf(T);
    }

    if (std.ascii.eqlIgnoreCase(value, "-inf") or
        std.ascii.eqlIgnoreCase(value, "-infinity"))
    {
        return -std.math.inf(T);
    }

    if (std.ascii.eqlIgnoreCase(value, "nan")) {
        return std.math.nan(T);
    }

    // Use standard parsing with better error handling
    return std.fmt.parseFloat(T, value) catch {
        // Check for specific common mistakes
        if (std.mem.count(u8, value, ".") > 1) {
            return error.MultipleDecimalPoints;
        }
        return error.InvalidFloatFormat;
    };
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
            return parseFloat(T, value) catch {
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

test "isNegativeNumber function - basic cases" {
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

test "isNegativeNumber function - scientific notation" {
    // Valid scientific notation
    try std.testing.expect(isNegativeNumber("-1e5"));
    try std.testing.expect(isNegativeNumber("-2.5e-3"));
    try std.testing.expect(isNegativeNumber("-1E+10"));
    try std.testing.expect(isNegativeNumber("-.5e2"));
    try std.testing.expect(isNegativeNumber("-123.456e-12"));
    try std.testing.expect(isNegativeNumber("-1e+0"));
    try std.testing.expect(isNegativeNumber("-1e-0"));

    // Invalid scientific notation
    try std.testing.expect(!isNegativeNumber("-e5")); // Missing mantissa
    try std.testing.expect(!isNegativeNumber("-1e")); // Missing exponent
    try std.testing.expect(!isNegativeNumber("-1.e.5")); // Multiple dots
    try std.testing.expect(!isNegativeNumber("-1ee5")); // Multiple e's
}

test "isNegativeNumber function - IEEE 754 special values" {
    // Infinity
    try std.testing.expect(isNegativeNumber("-inf"));
    try std.testing.expect(isNegativeNumber("-infinity"));
    try std.testing.expect(isNegativeNumber("-INF"));
    try std.testing.expect(isNegativeNumber("-Infinity"));
    try std.testing.expect(isNegativeNumber("-INFINITY"));

    // NaN
    try std.testing.expect(isNegativeNumber("-nan"));
    try std.testing.expect(isNegativeNumber("-NaN"));
    try std.testing.expect(isNegativeNumber("-NAN"));
}

test "isNegativeNumber function - decimal edge cases" {
    // Valid decimal cases
    try std.testing.expect(isNegativeNumber("-0.")); // Trailing dot is valid
    try std.testing.expect(isNegativeNumber("-.5")); // Leading dot is valid
    try std.testing.expect(isNegativeNumber("-123.456")); // Standard decimal

    // Invalid decimal cases
    try std.testing.expect(!isNegativeNumber("-.")); // Just dash-dot
    try std.testing.expect(!isNegativeNumber("-..5")); // Multiple dots
    try std.testing.expect(!isNegativeNumber("-1.2.3")); // Multiple dots
}

test "parseFloat function - special values" {
    // Positive infinity
    try std.testing.expect(std.math.isPositiveInf(try parseFloat(f64, "inf")));
    try std.testing.expect(std.math.isPositiveInf(try parseFloat(f64, "infinity")));
    try std.testing.expect(std.math.isPositiveInf(try parseFloat(f64, "INF")));
    try std.testing.expect(std.math.isPositiveInf(try parseFloat(f64, "Infinity")));

    // Negative infinity
    try std.testing.expect(std.math.isNegativeInf(try parseFloat(f64, "-inf")));
    try std.testing.expect(std.math.isNegativeInf(try parseFloat(f64, "-infinity")));
    try std.testing.expect(std.math.isNegativeInf(try parseFloat(f64, "-INF")));
    try std.testing.expect(std.math.isNegativeInf(try parseFloat(f64, "-Infinity")));

    // NaN
    try std.testing.expect(std.math.isNan(try parseFloat(f64, "nan")));
    try std.testing.expect(std.math.isNan(try parseFloat(f64, "NaN")));
    try std.testing.expect(std.math.isNan(try parseFloat(f64, "NAN")));
}

test "parseFloat function - scientific notation" {
    // Basic scientific notation
    try std.testing.expectApproxEqAbs(@as(f64, -0.0015), try parseFloat(f64, "-1.5e-3"), 0.0000001);
    try std.testing.expectApproxEqAbs(@as(f64, 25000.0), try parseFloat(f64, "2.5e4"), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 100000.0), try parseFloat(f64, "1e+5"), 0.0001);

    // With decimal points
    try std.testing.expectApproxEqAbs(@as(f64, -0.05), try parseFloat(f64, "-.5e-1"), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 1230000.0), try parseFloat(f64, "123.e4"), 0.0001);
}

test "parseFloat function - error cases" {
    // Multiple decimal points should be detected specifically
    try std.testing.expectError(error.MultipleDecimalPoints, parseFloat(f64, "1.2.3"));
    try std.testing.expectError(error.MultipleDecimalPoints, parseFloat(f64, "1.2.3e5"));

    // Invalid formats should return InvalidFloatFormat
    try std.testing.expectError(error.InvalidFloatFormat, parseFloat(f64, "not_a_number"));
    try std.testing.expectError(error.InvalidFloatFormat, parseFloat(f64, "1e"));
    try std.testing.expectError(error.InvalidFloatFormat, parseFloat(f64, "e5"));
}

test "parseFloat function - edge cases" {
    // Leading and trailing decimal points (these should work with std.fmt.parseFloat)
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), try parseFloat(f64, ".5"), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 123.0), try parseFloat(f64, "123."), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), try parseFloat(f64, "0."), 0.0001);
}

test "helper functions" {
    // hasScientificNotation
    try std.testing.expect(hasScientificNotation("1e5"));
    try std.testing.expect(hasScientificNotation("2.5E-3"));
    try std.testing.expect(!hasScientificNotation("123.456"));

    // hasDecimalPoint
    try std.testing.expect(hasDecimalPoint("1.5"));
    try std.testing.expect(hasDecimalPoint(".5"));
    try std.testing.expect(!hasDecimalPoint("123"));

    // isValidInteger
    try std.testing.expect(isValidInteger("123"));
    try std.testing.expect(isValidInteger("0"));
    try std.testing.expect(!isValidInteger("12.3"));
    try std.testing.expect(!isValidInteger(""));
    try std.testing.expect(!isValidInteger("12a3"));

    // isValidDecimalFloat
    try std.testing.expect(isValidDecimalFloat("123.456"));
    try std.testing.expect(isValidDecimalFloat(".5"));
    try std.testing.expect(isValidDecimalFloat("123."));
    try std.testing.expect(!isValidDecimalFloat("123"));
    try std.testing.expect(!isValidDecimalFloat("1.2.3"));
    try std.testing.expect(!isValidDecimalFloat("."));
    try std.testing.expect(!isValidDecimalFloat(""));

    // isValidScientificFloat
    try std.testing.expect(isValidScientificFloat("1e5"));
    try std.testing.expect(isValidScientificFloat("2.5e-3"));
    try std.testing.expect(isValidScientificFloat("1E+10"));
    try std.testing.expect(isValidScientificFloat(".5e2"));
    try std.testing.expect(!isValidScientificFloat("e5"));
    try std.testing.expect(!isValidScientificFloat("1e"));
    try std.testing.expect(!isValidScientificFloat("1.e.5"));
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
