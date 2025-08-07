const std = @import("std");

pub const ParseError = error{
    MissingRequiredArgument,
    InvalidArgumentType,
    TooManyArguments,
    OutOfMemory,
};

/// Parse positional arguments based on the provided Args struct type
///
/// The args parameter should come from command-line arguments (e.g., from std.process.argsAlloc).
/// For varargs fields ([][]const u8), the returned slice references the original args without copying.
/// This means the lifetime of varargs fields is tied to the lifetime of the input args parameter.
///
/// Example:
/// ```zig
/// const Args = struct {
///     command: []const u8,
///     files: [][]const u8,  // varargs - captures all remaining arguments
/// };
/// 
/// const args = try std.process.argsAlloc(allocator);
/// defer std.process.argsFree(allocator, args);
/// 
/// const parsed = try parseArgs(Args, args[1..]);
/// // parsed.files references args - don't free args while using parsed
/// ```
pub fn parseArgs(comptime ArgsType: type, args: []const []const u8) ParseError!ArgsType {
    const type_info = @typeInfo(ArgsType);

    if (type_info != .@"struct") {
        @compileError("Args must be a struct type");
    }

    const struct_info = type_info.@"struct";
    var result: ArgsType = undefined;
    var arg_index: usize = 0;

    // Process each field in the struct
    inline for (struct_info.fields, 0..) |field, field_index| {
        const field_type = field.type;

        if (comptime isVarArgs(field_type)) {
            // This is a varargs field ([][]const u8) - capture remaining arguments
            const remaining_args = args[arg_index..];
            
            // SAFETY: @constCast is required here to convert []const []const u8 to [][]const u8
            // This is safe because:
            // 1. We're not modifying the slice or its contents
            // 2. The strings themselves remain immutable ([]const u8)
            // 3. We're only removing the const qualifier from the outer slice
            // 4. The lifetime of the args is managed by the caller
            // Alternative would be to allocate and copy, but that adds unnecessary overhead
            // and memory management complexity for the user.
            @field(result, field.name) = @constCast(remaining_args);
            break;
        } else if (@typeInfo(field_type) == .optional) {
            // Optional field
            if (arg_index < args.len) {
                @field(result, field.name) = try parseValue(field_type, args[arg_index]);
                arg_index += 1;
            } else {
                // Use null for optional
                @field(result, field.name) = null;
            }
        } else {
            // Required field
            if (arg_index >= args.len) {
                std.log.err("Missing required argument '{s}' (argument {})", .{ field.name, field_index + 1 });
                return ParseError.MissingRequiredArgument;
            }

            @field(result, field.name) = try parseValue(field_type, args[arg_index]);
            arg_index += 1;
        }
    }

    // Check if there are too many arguments (only if no varargs field)
    if (!hasVarArgs(ArgsType) and arg_index < args.len) {
        std.log.err("Too many arguments provided. Expected {}, got {}", .{ getRequiredArgCount(ArgsType), args.len });
        return ParseError.TooManyArguments;
    }

    return result;
}

/// Parse a single value based on its type
fn parseValue(comptime T: type, value: []const u8) ParseError!T {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                // []const u8 - just return the string
                return value;
            } else {
                @compileError("Unsupported pointer type: " ++ @typeName(T));
            }
        },
        .int => {
            return std.fmt.parseInt(T, value, 10) catch {
                std.log.err("Invalid integer value: '{s}'", .{value});
                return ParseError.InvalidArgumentType;
            };
        },
        .float => {
            return std.fmt.parseFloat(T, value) catch {
                std.log.err("Invalid float value: '{s}'", .{value});
                return ParseError.InvalidArgumentType;
            };
        },
        .bool => {
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
                return true;
            } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
                return false;
            } else {
                std.log.err("Invalid boolean value: '{s}'. Expected 'true', 'false', '1', or '0'", .{value});
                return ParseError.InvalidArgumentType;
            }
        },
        .@"enum" => {
            return std.meta.stringToEnum(T, value) orelse {
                std.log.err("Invalid enum value: '{s}'", .{value});
                return ParseError.InvalidArgumentType;
            };
        },
        .optional => |opt_info| {
            // Parse the underlying type
            return try parseValue(opt_info.child, value);
        },
        else => {
            @compileError("Unsupported argument type: " ++ @typeName(T));
        },
    }
}

/// Check if a type represents varargs ([][]const u8)
pub fn isVarArgs(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info == .pointer) {
        const ptr_info = type_info.pointer;
        if (ptr_info.size == .slice) {
            const child_info = @typeInfo(ptr_info.child);
            if (child_info == .pointer) {
                const child_ptr_info = child_info.pointer;
                return child_ptr_info.size == .slice and child_ptr_info.child == u8;
            }
        }
    }
    return false;
}

/// Check if a struct has a varargs field
fn hasVarArgs(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".fields) |field| {
        if (isVarArgs(field.type)) return true;
    }
    return false;
}

/// Count the number of required arguments (non-optional, non-varargs)
fn getRequiredArgCount(comptime T: type) usize {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return 0;

    var count: usize = 0;
    inline for (type_info.@"struct".fields) |field| {
        if (!isVarArgs(field.type) and @typeInfo(field.type) != .optional) {
            count += 1;
        }
    }
    return count;
}

// Tests
test "parseArgs basic types" {
    const TestArgs = struct {
        name: []const u8,
        age: u32,
        verbose: ?bool,
    };

    // Test with all arguments
    {
        const args = [_][]const u8{ "John", "25", "true" };
        const result = try parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("John", result.name);
        try std.testing.expectEqual(@as(u32, 25), result.age);
        try std.testing.expect(result.verbose.?);
    }

    // Test with default value
    {
        const args = [_][]const u8{ "Jane", "30" };
        const result = try parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("Jane", result.name);
        try std.testing.expectEqual(@as(u32, 30), result.age);
        try std.testing.expect(result.verbose == null);
    }
}

test "parseArgs varargs" {
    const TestArgs = struct {
        command: []const u8,
        files: [][]const u8,
    };

    const args = [_][]const u8{ "build", "file1.zig", "file2.zig", "file3.zig" };
    const result = try parseArgs(TestArgs, &args);

    try std.testing.expectEqualStrings("build", result.command);
    try std.testing.expectEqual(@as(usize, 3), result.files.len);
    try std.testing.expectEqualStrings("file1.zig", result.files[0]);
    try std.testing.expectEqualStrings("file2.zig", result.files[1]);
    try std.testing.expectEqualStrings("file3.zig", result.files[2]);
}

test "parseArgs enum" {
    const LogLevel = enum { debug, info, warn, err };
    const TestArgs = struct {
        level: LogLevel,
    };

    const args = [_][]const u8{"info"};
    const result = try parseArgs(TestArgs, &args);

    try std.testing.expectEqual(LogLevel.info, result.level);
}

test "parseArgs error cases" {
    const TestArgs = struct {
        required: []const u8,
        number: u32,
    };

    // Test missing required argument
    {
        const args = [_][]const u8{};
        try std.testing.expectError(ParseError.MissingRequiredArgument, parseArgs(TestArgs, &args));
    }

    // Test invalid number
    {
        const args = [_][]const u8{ "test", "not_a_number" };
        try std.testing.expectError(ParseError.InvalidArgumentType, parseArgs(TestArgs, &args));
    }

    // Test too many arguments (when no varargs)
    {
        const args = [_][]const u8{ "test", "123", "extra" };
        try std.testing.expectError(ParseError.TooManyArguments, parseArgs(TestArgs, &args));
    }
}

test "parseArgs integer types" {
    const TestArgs = struct {
        port: u16,
        timeout: i32,
        size: i64,
    };

    const args = [_][]const u8{ "8080", "-30", "9223372036854775807" };

    const result = try parseArgs(TestArgs, &args);

    try std.testing.expectEqual(@as(u16, 8080), result.port);
    try std.testing.expectEqual(@as(i32, -30), result.timeout);
    try std.testing.expectEqual(@as(i64, 9223372036854775807), result.size);
}

test "parseArgs float types" {
    const TestArgs = struct {
        ratio: f32,
        precision: f64,
    };

    const args = [_][]const u8{ "3.14", "2.718281828" };

    const result = try parseArgs(TestArgs, &args);

    try std.testing.expectApproxEqAbs(@as(f32, 3.14), result.ratio, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.718281828), result.precision, 0.000000001);
}

test "parseArgs optional types" {
    const TestArgs = struct {
        name: []const u8,
        port: ?u16 = null,
        host: ?[]const u8 = null,
    };

    // Test with all optionals provided
    {
        const args = [_][]const u8{ "server", "8080", "localhost" };
        const result = try parseArgs(TestArgs, &args);

        try std.testing.expectEqualStrings("server", result.name);
        try std.testing.expectEqual(@as(u16, 8080), result.port.?);
        try std.testing.expectEqualStrings("localhost", result.host.?);
    }

    // Test with no optionals provided
    {
        const args = [_][]const u8{"client"};
        const result = try parseArgs(TestArgs, &args);

        try std.testing.expectEqualStrings("client", result.name);
        try std.testing.expectEqual(@as(?u16, null), result.port);
        try std.testing.expectEqual(@as(?[]const u8, null), result.host);
    }
}

test "parseArgs varargs with mixed types" {
    const TestArgs = struct {
        action: []const u8,
        verbose: bool = false,
        items: [][]const u8 = &.{},
    };

    // Test with varargs at the end
    {
        const args = [_][]const u8{ "process", "true", "item1", "item2", "item3" };
        const result = try parseArgs(TestArgs, &args);

        try std.testing.expectEqualStrings("process", result.action);
        try std.testing.expect(result.verbose);
        try std.testing.expectEqual(@as(usize, 3), result.items.len);
    }

    // Test with no varargs
    {
        const args = [_][]const u8{ "clean", "false" };
        const result = try parseArgs(TestArgs, &args);

        try std.testing.expectEqualStrings("clean", result.action);
        try std.testing.expect(!result.verbose);
        try std.testing.expectEqual(@as(usize, 0), result.items.len);
    }
}

test "parseArgs boolean edge cases" {
    const TestArgs = struct {
        flag: bool,
    };

    // Test various boolean representations
    const test_cases = .{
        .{ "true", true },
        .{ "false", false },
        .{ "1", true },
        .{ "0", false },
        .{ "TRUE", ParseError.InvalidArgumentType },
        .{ "yes", ParseError.InvalidArgumentType },
        .{ "on", ParseError.InvalidArgumentType },
    };

    inline for (test_cases) |test_case| {
        const args = [_][]const u8{test_case[0]};

        if (@TypeOf(test_case[1]) == ParseError) {
            try std.testing.expectError(test_case[1], parseArgs(TestArgs, &args));
        } else {
            const result = try parseArgs(TestArgs, &args);
            try std.testing.expectEqual(test_case[1], result.flag);
        }
    }
}

test "parseArgs enum edge cases" {
    const Color = enum { red, green, blue };
    const TestArgs = struct {
        color: Color,
    };

    // Test valid enum value
    {
        const args = [_][]const u8{"green"};
        const result = try parseArgs(TestArgs, &args);
        try std.testing.expectEqual(Color.green, result.color);
    }

    // Test invalid enum value
    {
        const args = [_][]const u8{"yellow"};
        try std.testing.expectError(ParseError.InvalidArgumentType, parseArgs(TestArgs, &args));
    }
}

test "parseArgs empty struct" {
    const EmptyArgs = struct {};

    // Test with no arguments
    {
        const args = [_][]const u8{};
        const result = try parseArgs(EmptyArgs, &args);
        _ = result;
    }

    // Test with extra arguments
    {
        const args = [_][]const u8{"extra"};
        try std.testing.expectError(ParseError.TooManyArguments, parseArgs(EmptyArgs, &args));
    }
}

test "parseArgs all supported integer types" {
    const IntArgs = struct {
        i8_val: i8,
        i16_val: i16,
        i32_val: i32,
        i64_val: i64,
        u8_val: u8,
        u16_val: u16,
        u32_val: u32,
        u64_val: u64,
        isize_val: isize,
        usize_val: usize,
    };

    const args = [_][]const u8{ "-128", "32767", "-2147483648", "9223372036854775807", "255", "65535", "4294967295", "18446744073709551615", "-1000", "1000" };

    const result = try parseArgs(IntArgs, &args);
    try std.testing.expectEqual(@as(i8, -128), result.i8_val);
    try std.testing.expectEqual(@as(i16, 32767), result.i16_val);
    try std.testing.expectEqual(@as(i32, -2147483648), result.i32_val);
    try std.testing.expectEqual(@as(i64, 9223372036854775807), result.i64_val);
    try std.testing.expectEqual(@as(u8, 255), result.u8_val);
    try std.testing.expectEqual(@as(u16, 65535), result.u16_val);
    try std.testing.expectEqual(@as(u32, 4294967295), result.u32_val);
    try std.testing.expectEqual(@as(u64, 18446744073709551615), result.u64_val);
    try std.testing.expectEqual(@as(isize, -1000), result.isize_val);
    try std.testing.expectEqual(@as(usize, 1000), result.usize_val);
}

test "parseArgs integer overflow" {
    const TestArgs = struct {
        val: u8,
    };

    // Test overflow
    const args = [_][]const u8{"256"};
    try std.testing.expectError(ParseError.InvalidArgumentType, parseArgs(TestArgs, &args));
}

test "parseArgs negative value for unsigned" {
    const TestArgs = struct {
        val: u32,
    };

    const args = [_][]const u8{"-1"};
    try std.testing.expectError(ParseError.InvalidArgumentType, parseArgs(TestArgs, &args));
}

test "parseArgs all supported float types" {
    const FloatArgs = struct {
        f16_val: f16,
        f32_val: f32,
        f64_val: f64,
        f80_val: f80,
        f128_val: f128,
    };

    const args = [_][]const u8{ "1.5", "3.14159", "2.71828", "123.456", "789.012" };

    const result = try parseArgs(FloatArgs, &args);
    try std.testing.expectApproxEqAbs(@as(f16, 1.5), result.f16_val, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14159), result.f32_val, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.71828), result.f64_val, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f80, 123.456), result.f80_val, 0.001);
    try std.testing.expectApproxEqAbs(@as(f128, 789.012), result.f128_val, 0.001);
}

test "parseArgs varargs empty" {
    const TestArgs = struct {
        files: [][]const u8,
    };

    const args = [_][]const u8{};
    const result = try parseArgs(TestArgs, &args);
    try std.testing.expectEqual(@as(usize, 0), result.files.len);
}

test "parseArgs varargs with preceding required args" {
    const TestArgs = struct {
        command: []const u8,
        verbose: bool,
        files: [][]const u8,
    };

    const args = [_][]const u8{ "build", "true", "file1.txt", "file2.txt", "file3.txt" };
    const result = try parseArgs(TestArgs, &args);

    try std.testing.expectEqualStrings("build", result.command);
    try std.testing.expectEqual(true, result.verbose);
    try std.testing.expectEqual(@as(usize, 3), result.files.len);
    try std.testing.expectEqualStrings("file1.txt", result.files[0]);
    try std.testing.expectEqualStrings("file2.txt", result.files[1]);
    try std.testing.expectEqualStrings("file3.txt", result.files[2]);
}

test "parseArgs optional at end" {
    const TestArgs = struct {
        required: []const u8,
        optional1: ?[]const u8,
        optional2: ?i32,
    };

    // Test with all values
    {
        const args = [_][]const u8{ "req", "opt", "42" };
        const result = try parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("req", result.required);
        try std.testing.expectEqualStrings("opt", result.optional1.?);
        try std.testing.expectEqual(@as(i32, 42), result.optional2.?);
    }

    // Test with partial values
    {
        const args = [_][]const u8{ "req", "opt" };
        const result = try parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("req", result.required);
        try std.testing.expectEqualStrings("opt", result.optional1.?);
        try std.testing.expectEqual(@as(?i32, null), result.optional2);
    }

    // Test with minimal values
    {
        const args = [_][]const u8{"req"};
        const result = try parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("req", result.required);
        try std.testing.expectEqual(@as(?[]const u8, null), result.optional1);
        try std.testing.expectEqual(@as(?i32, null), result.optional2);
    }
}

test "parseArgs special float values" {
    const TestArgs = struct {
        val1: f64,
        val2: f64,
        val3: f64,
    };

    const args = [_][]const u8{ "inf", "-inf", "nan" };
    const result = try parseArgs(TestArgs, &args);

    try std.testing.expect(std.math.isPositiveInf(result.val1));
    try std.testing.expect(std.math.isNegativeInf(result.val2));
    try std.testing.expect(std.math.isNan(result.val3));
}

test "parseArgs unicode strings" {
    const TestArgs = struct {
        text: []const u8,
        emoji: []const u8,
    };

    const args = [_][]const u8{ "Hello, 世界", "🚀🌟" };
    const result = try parseArgs(TestArgs, &args);

    try std.testing.expectEqualStrings("Hello, 世界", result.text);
    try std.testing.expectEqualStrings("🚀🌟", result.emoji);
}

test "parseArgs varargs lifetime and safety" {
    // Test that varargs correctly reference the original args without copying
    const TestArgs = struct {
        command: []const u8,
        files: [][]const u8,
    };

    const args = [_][]const u8{ "test", "file1.txt", "file2.txt" };
    const result = try parseArgs(TestArgs, &args);
    
    // Verify that the varargs slice points to the same memory as the original args
    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expectEqual(@intFromPtr(args[1].ptr), @intFromPtr(result.files[0].ptr));
    try std.testing.expectEqual(@intFromPtr(args[2].ptr), @intFromPtr(result.files[1].ptr));
    
    // This demonstrates that we're not copying the strings, just referencing them
    // The @constCast is safe because we maintain the immutability of the strings
}
