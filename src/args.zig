const std = @import("std");
const logging = @import("logging.zig");
const diagnostic_errors = @import("diagnostic_errors.zig");

pub const ZcliError = diagnostic_errors.ZcliError;
pub const ZcliDiagnostic = diagnostic_errors.ZcliDiagnostic;

/// Check if a struct field has a default value
fn hasDefaultValue(comptime T: type, comptime field_name: []const u8) bool {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return field.default_value_ptr != null;
        }
    }
    return false;
}

/// Parse positional arguments based on the provided Args struct type
///
/// The args parameter should come from command-line arguments (e.g., from std.process.argsAlloc).
/// For varargs fields ([]const []const u8 or [][]const u8), the returned slice references the original args without copying.
/// Prefer using []const []const u8 to avoid @constCast.
/// This means the lifetime of varargs fields is tied to the lifetime of the input args parameter.
///
/// Example:
/// ```zig
/// const Args = struct {
///     command: []const u8,
///     files: []const []const u8,  // varargs - captures all remaining arguments (recommended)
///     // or: files: [][]const u8,  // also supported but requires @constCast internally
/// };
///
/// const args = try std.process.argsAlloc(allocator);
/// defer std.process.argsFree(allocator, args);
///
/// const parsed = try parseArgs(Args, args[1..]);
/// // parsed.files references args - don't free args while using parsed
/// ```
/// Parse positional arguments from command-line arguments into a struct.
///
/// This function takes a struct type and a slice of command-line arguments,
/// and returns an instance of that struct with fields populated from the arguments.
///
/// ## Parameters
/// - `ArgsType`: A struct type defining the expected arguments
/// - `args`: Slice of command-line argument strings
///
/// ## Returns
/// Returns a parsed struct instance or ParseError on failure.
///
/// ## Supported Field Types
/// - Basic types: `[]const u8`, `i32`, `u32`, `f64`, `bool`
/// - Optional types: `?[]const u8`, `?i32`, etc.
/// - Enums: Custom enum types for validated choices
/// - Varargs: `[][]const u8` for capturing remaining arguments (must be last field)
///
/// ## Examples
/// ```zig
/// const Args = struct {
///     name: []const u8,
///     age: ?u32 = null,
///     verbose: bool = false,
/// };
///
/// const args = [_][]const u8{ "Alice", "25", "true" };
/// const parsed = try zcli.parseArgs(Args, &args);
/// // parsed.name = "Alice", parsed.age = 25, parsed.verbose = true
/// ```
///
/// ## Returns
/// Returns ArgsType on success or ZcliError on failure.
/// Common errors include:
/// - `ArgumentMissingRequired`: Missing required argument
/// - `ArgumentInvalidValue`: Invalid argument value (e.g., non-numeric value for integer field)
/// - `ArgumentTooMany`: Too many arguments provided
pub fn parseArgs(comptime ArgsType: type, args: []const []const u8) ZcliError!ArgsType {
    return parseArgsInternal(ArgsType, args);
}

/// Internal implementation of argument parsing
fn parseArgsInternal(comptime ArgsType: type, args: []const []const u8) ZcliError!ArgsType {
    const type_info = @typeInfo(ArgsType);
    if (type_info != .@"struct") {
        @compileError("Args must be a struct type");
    }

    const struct_info = type_info.@"struct";
    var result: ArgsType = undefined;
    var arg_index: usize = 0;

    // First, initialize all fields with defaults where available
    inline for (struct_info.fields) |field| {
        if (comptime hasDefaultValue(ArgsType, field.name)) {
            // Set the default value from the type definition
            if (field.default_value_ptr) |default_ptr| {
                const default_value: *const field.type = @ptrCast(@alignCast(default_ptr));
                @field(result, field.name) = default_value.*;
            }
        }
    }

    // Process each field in the struct
    inline for (struct_info.fields, 0..) |field, field_index| {
        const field_type = field.type;

        if (comptime isVarArgs(field_type)) {
            // This is a varargs field - capture remaining positional arguments
            // The field can be either [][]const u8 or []const []const u8
            const remaining_args = args[arg_index..];

            // Check if we need @constCast based on the field type
            const field_type_info = @typeInfo(field_type);
            if (field_type_info.pointer.is_const) {
                // Field type is []const []const u8 - no cast needed
                @field(result, field.name) = remaining_args;
            } else {
                // Field type is [][]const u8 - need to remove outer const
                // SAFETY: This cast is safe because:
                // 1. We only remove the outer const qualifier from the slice
                // 2. The inner strings remain const and are never modified
                // 3. The slice itself is only used for iteration, not mutation
                @field(result, field.name) = @constCast(remaining_args);
            }
            break;
        } else if (@typeInfo(field_type) == .optional) {
            // Optional field - find next positional argument
            const next_positional = findNextPositional(args, arg_index);
            if (next_positional) |pos| {
                @field(result, field.name) = try parseValue(field_type, args[pos]);
                arg_index = pos + 1;
            } else {
                // Use null for optional
                @field(result, field.name) = null;
            }
        } else if (comptime hasDefaultValue(ArgsType, field.name)) {
            // Field with default value - optional in parsing
            const next_positional = findNextPositional(args, arg_index);
            if (next_positional) |pos| {
                @field(result, field.name) = try parseValue(field_type, args[pos]);
                arg_index = pos + 1;
            }
            // If no argument provided, default value is already set by struct initialization
        } else {
            // Required field - find next positional argument
            const next_positional = findNextPositional(args, arg_index);
            if (next_positional == null) {
                logging.missingRequiredArgument(field.name, field_index + 1);
                return ZcliError.ArgumentMissingRequired;
            }

            const pos = next_positional.?;
            @field(result, field.name) = try parseValue(field_type, args[pos]);
            arg_index = pos + 1;
        }
    }

    // Check if there are too many arguments (only if no varargs field)
    if (!hasVarArgs(ArgsType) and arg_index < args.len) {
        const expected_count = getRequiredArgCount(ArgsType);
        logging.tooManyArguments(expected_count, args.len);
        return ZcliError.ArgumentTooMany;
    }

    return result;
}

/// Parse a single value based on its type
fn parseValue(comptime T: type, value: []const u8) ZcliError!T {
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
                return ZcliError.ArgumentInvalidValue;
            };
        },
        .float => {
            return std.fmt.parseFloat(T, value) catch {
                return ZcliError.ArgumentInvalidValue;
            };
        },
        .bool => {
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
                return true;
            } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
                return false;
            } else {
                return ZcliError.ArgumentInvalidValue;
            }
        },
        .@"enum" => {
            return std.meta.stringToEnum(T, value) orelse {
                return ZcliError.ArgumentInvalidValue;
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

/// Check if a type represents varargs ([][]const u8 or []const []const u8)
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

/// Check if a string looks like a negative number
fn isNegativeNumber(str: []const u8) bool {
    if (str.len < 2 or str[0] != '-') return false;
    // Check if the character after '-' is a digit
    return str[1] >= '0' and str[1] <= '9';
}

/// Find the next positional argument starting from the given index, skipping options
fn findNextPositional(args: []const []const u8, start_index: usize) ?usize {
    var i = start_index;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-") and !isNegativeNumber(arg)) {
            // Skip option (but not negative numbers)
            i += 1;
            // Skip option value if it doesn't start with -
            if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
                i += 1;
            }
        } else {
            // Found positional argument (including negative numbers)
            return i;
        }
    }
    return null;
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
test "isVarArgs function" {
    // Test that normal types are NOT varargs
    try std.testing.expect(!isVarArgs([]const u8));
    try std.testing.expect(!isVarArgs(u32));
    try std.testing.expect(!isVarArgs(?bool));

    // Test that varargs type IS varargs
    try std.testing.expect(isVarArgs([][]const u8));
    try std.testing.expect(isVarArgs([]const []const u8));
}

test "parseArgs basic types" {
    const TestArgs = struct {
        name: []const u8,
        age: u32,
        verbose: ?bool,
    };

    // Test with all arguments
    {
        const args = [_][]const u8{ "John", "25", "true" };
        const parsed = try parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("John", parsed.name);
        try std.testing.expectEqual(@as(u32, 25), parsed.age);
        try std.testing.expect(parsed.verbose.?);
    }

    // Test with default value
    {
        const args = [_][]const u8{ "Jane", "30" };
        const parsed = try parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("Jane", parsed.name);
        try std.testing.expectEqual(@as(u32, 30), parsed.age);
        try std.testing.expect(parsed.verbose == null);
    }
}

test "parseArgs varargs" {
    const TestArgs = struct {
        command: []const u8,
        files: [][]const u8,
    };

    const args = [_][]const u8{ "build", "file1.zig", "file2.zig", "file3.zig" };
    const parsed = try parseArgs(TestArgs, &args);

    try std.testing.expectEqualStrings("build", parsed.command);
    try std.testing.expectEqual(@as(usize, 3), parsed.files.len);
    try std.testing.expectEqualStrings("file1.zig", parsed.files[0]);
    try std.testing.expectEqualStrings("file2.zig", parsed.files[1]);
    try std.testing.expectEqualStrings("file3.zig", parsed.files[2]);
}

test "parseArgs enum" {
    const LogLevel = enum { debug, info, warn, err };
    const TestArgs = struct {
        level: LogLevel,
    };

    const args = [_][]const u8{"info"};
    const parsed = try parseArgs(TestArgs, &args);

    try std.testing.expectEqual(LogLevel.info, parsed.level);
}

test "parseArgs error cases" {
    const TestArgs = struct {
        required: []const u8,
        number: u32,
    };

    // Test missing required argument
    {
        const args = [_][]const u8{};
        try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentMissingRequired, parseArgs(TestArgs, &args));
    }

    // Test invalid number
    {
        const args = [_][]const u8{ "test", "not_a_number" };
        try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentInvalidValue, parseArgs(TestArgs, &args));
    }

    // Test too many arguments (when no varargs)
    {
        const args = [_][]const u8{ "test", "123", "extra" };
        try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentTooMany, parseArgs(TestArgs, &args));
    }
}

test "parseArgs integer types" {
    const TestArgs = struct {
        port: u16,
        timeout: i32,
        size: i64,
    };

    const args = [_][]const u8{ "8080", "-30", "9223372036854775807" };

    const parsed = try parseArgs(TestArgs, &args);

    try std.testing.expectEqual(@as(u16, 8080), parsed.port);
    try std.testing.expectEqual(@as(i32, -30), parsed.timeout);
    try std.testing.expectEqual(@as(i64, 9223372036854775807), parsed.size);
}

test "parseArgs float types" {
    const TestArgs = struct {
        ratio: f32,
        precision: f64,
    };

    const args = [_][]const u8{ "3.14", "2.718281828" };

    const parsed = try parseArgs(TestArgs, &args);

    try std.testing.expectApproxEqAbs(@as(f32, 3.14), parsed.ratio, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.718281828), parsed.precision, 0.000000001);
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
        const parsed = try parseArgs(TestArgs, &args);

        try std.testing.expectEqualStrings("server", parsed.name);
        try std.testing.expectEqual(@as(u16, 8080), parsed.port.?);
        try std.testing.expectEqualStrings("localhost", parsed.host.?);
    }

    // Test with no optionals provided
    {
        const args = [_][]const u8{"client"};
        const parsed = try parseArgs(TestArgs, &args);

        try std.testing.expectEqualStrings("client", parsed.name);
        try std.testing.expectEqual(@as(?u16, null), parsed.port);
        try std.testing.expectEqual(@as(?[]const u8, null), parsed.host);
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
        const parsed = try parseArgs(TestArgs, &args);

        try std.testing.expectEqualStrings("process", parsed.action);
        try std.testing.expect(parsed.verbose);
        try std.testing.expectEqual(@as(usize, 3), parsed.items.len);
    }

    // Test with no varargs
    {
        const args = [_][]const u8{ "clean", "false" };
        const parsed = try parseArgs(TestArgs, &args);

        try std.testing.expectEqualStrings("clean", parsed.action);
        try std.testing.expect(!parsed.verbose);
        try std.testing.expectEqual(@as(usize, 0), parsed.items.len);
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
        .{ "TRUE", diagnostic_errors.ZcliError.ArgumentInvalidValue },
        .{ "yes", diagnostic_errors.ZcliError.ArgumentInvalidValue },
        .{ "on", diagnostic_errors.ZcliError.ArgumentInvalidValue },
    };

    inline for (test_cases) |test_case| {
        const args = [_][]const u8{test_case[0]};

        if (@TypeOf(test_case[1]) == @TypeOf(diagnostic_errors.ZcliError.ArgumentInvalidValue)) {
            try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentInvalidValue, parseArgs(TestArgs, &args));
        } else {
            const parsed = try parseArgs(TestArgs, &args);
            try std.testing.expectEqual(test_case[1], parsed.flag);
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
        const parsed = try parseArgs(TestArgs, &args);
        try std.testing.expectEqual(Color.green, parsed.color);
    }

    // Test invalid enum value
    {
        const args = [_][]const u8{"yellow"};
        try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentInvalidValue, parseArgs(TestArgs, &args));
    }
}

test "parseArgs empty struct" {
    const EmptyArgs = struct {};

    // Test with no arguments
    {
        const args = [_][]const u8{};
        _ = try parseArgs(EmptyArgs, &args);
    }

    // Test with extra arguments
    {
        const args = [_][]const u8{"extra"};
        try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentTooMany, parseArgs(EmptyArgs, &args));
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

    const parsed = try parseArgs(IntArgs, &args);
    try std.testing.expectEqual(@as(i8, -128), parsed.i8_val);
    try std.testing.expectEqual(@as(i16, 32767), parsed.i16_val);
    try std.testing.expectEqual(@as(i32, -2147483648), parsed.i32_val);
    try std.testing.expectEqual(@as(i64, 9223372036854775807), parsed.i64_val);
    try std.testing.expectEqual(@as(u8, 255), parsed.u8_val);
    try std.testing.expectEqual(@as(u16, 65535), parsed.u16_val);
    try std.testing.expectEqual(@as(u32, 4294967295), parsed.u32_val);
    try std.testing.expectEqual(@as(u64, 18446744073709551615), parsed.u64_val);
    try std.testing.expectEqual(@as(isize, -1000), parsed.isize_val);
    try std.testing.expectEqual(@as(usize, 1000), parsed.usize_val);
}

test "parseArgs integer overflow" {
    const TestArgs = struct {
        val: u8,
    };

    // Test overflow
    const args = [_][]const u8{"256"};
    try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentInvalidValue, parseArgs(TestArgs, &args));
}

test "parseArgs negative value for unsigned" {
    const TestArgs = struct {
        val: u32,
    };

    const args = [_][]const u8{"-1"};
    try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentInvalidValue, parseArgs(TestArgs, &args));
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

    const parsed = try parseArgs(FloatArgs, &args);
    try std.testing.expectApproxEqAbs(@as(f16, 1.5), parsed.f16_val, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14159), parsed.f32_val, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.71828), parsed.f64_val, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f80, 123.456), parsed.f80_val, 0.001);
    try std.testing.expectApproxEqAbs(@as(f128, 789.012), parsed.f128_val, 0.001);
}

test "parseArgs skip options" {
    // Test that options are properly skipped during argument parsing
    const TestArgs = struct {
        image: []const u8,
        command: ?[]const u8,
        args: [][]const u8,
    };

    // Mix options with positional arguments
    const args = [_][]const u8{ "--name", "mycontainer", "ubuntu", "-v", "/tmp:/tmp", "bash", "arg1", "arg2" };
    const parsed = try parseArgs(TestArgs, &args);

    // Should extract positional args correctly, skipping options
    try std.testing.expectEqualStrings("ubuntu", parsed.image);
    try std.testing.expectEqualStrings("bash", parsed.command.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.args.len);
    try std.testing.expectEqualStrings("arg1", parsed.args[0]);
    try std.testing.expectEqualStrings("arg2", parsed.args[1]);
}

test "parseArgs varargs empty" {
    const TestArgs = struct {
        files: [][]const u8,
    };

    const args = [_][]const u8{};
    const parsed = try parseArgs(TestArgs, &args);
    try std.testing.expectEqual(@as(usize, 0), parsed.files.len);
}

test "parseArgs varargs with const-safe type" {
    const TestArgs = struct {
        files: []const []const u8, // Using const-safe type
    };

    const args = [_][]const u8{ "file1.txt", "file2.txt", "file3.txt" };
    const parsed = try parseArgs(TestArgs, &args);
    try std.testing.expectEqual(@as(usize, 3), parsed.files.len);
    try std.testing.expectEqualStrings("file1.txt", parsed.files[0]);
    try std.testing.expectEqualStrings("file2.txt", parsed.files[1]);
    try std.testing.expectEqualStrings("file3.txt", parsed.files[2]);
}

test "parseArgs varargs with preceding required args" {
    const TestArgs = struct {
        command: []const u8,
        verbose: bool,
        files: [][]const u8,
    };

    const args = [_][]const u8{ "build", "true", "file1.txt", "file2.txt", "file3.txt" };
    const parsed = try parseArgs(TestArgs, &args);

    try std.testing.expectEqualStrings("build", parsed.command);
    try std.testing.expectEqual(true, parsed.verbose);
    try std.testing.expectEqual(@as(usize, 3), parsed.files.len);
    try std.testing.expectEqualStrings("file1.txt", parsed.files[0]);
    try std.testing.expectEqualStrings("file2.txt", parsed.files[1]);
    try std.testing.expectEqualStrings("file3.txt", parsed.files[2]);
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
        const parsed = try parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("req", parsed.required);
        try std.testing.expectEqualStrings("opt", parsed.optional1.?);
        try std.testing.expectEqual(@as(i32, 42), parsed.optional2.?);
    }

    // Test with partial values
    {
        const args = [_][]const u8{ "req", "opt" };
        const parsed = try parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("req", parsed.required);
        try std.testing.expectEqualStrings("opt", parsed.optional1.?);
        try std.testing.expectEqual(@as(?i32, null), parsed.optional2);
    }

    // Test with minimal values
    {
        const args = [_][]const u8{"req"};
        const parsed = try parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("req", parsed.required);
        try std.testing.expectEqual(@as(?[]const u8, null), parsed.optional1);
        try std.testing.expectEqual(@as(?i32, null), parsed.optional2);
    }
}

test "parseArgs unicode strings" {
    const TestArgs = struct {
        text: []const u8,
        emoji: []const u8,
    };

    const args = [_][]const u8{ "Hello, 世界", "🚀🌟" };
    const parsed = try parseArgs(TestArgs, &args);

    try std.testing.expectEqualStrings("Hello, 世界", parsed.text);
    try std.testing.expectEqualStrings("🚀🌟", parsed.emoji);
}

test "parseArgs structured error context" {
    const TestArgs = struct {
        name: []const u8,
        age: u32,
    };

    // Test that structured error context is captured
    const args = [_][]const u8{}; // Missing both arguments

    try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentMissingRequired, parseArgs(TestArgs, &args));
}

test "parseArgs varargs lifetime and safety" {
    // Test that varargs correctly reference the original args without copying
    const TestArgs = struct {
        command: []const u8,
        files: [][]const u8,
    };

    const args = [_][]const u8{ "test", "file1.txt", "file2.txt" };
    const parsed = try parseArgs(TestArgs, &args);

    // Verify that the varargs slice points to the same memory as the original args
    try std.testing.expectEqual(@as(usize, 2), parsed.files.len);
    try std.testing.expectEqual(@intFromPtr(args[1].ptr), @intFromPtr(parsed.files[0].ptr));
    try std.testing.expectEqual(@intFromPtr(args[2].ptr), @intFromPtr(parsed.files[1].ptr));

    // This demonstrates that we're not copying the strings, just referencing them
    // The @constCast is safe because we maintain the immutability of the strings
}

test "parseArgs default values - no value provided" {
    const TestArgs = struct {
        name: []const u8,
        count: u32 = 42,
        file: ?[]const u8 = null,
    };

    const args = [_][]const u8{"testname"};
    const result = try parseArgs(TestArgs, &args);

    try std.testing.expectEqualStrings("testname", result.name);
    try std.testing.expectEqual(@as(u32, 42), result.count); // Should use default
    try std.testing.expect(result.file == null);
}

test "parseArgs default values - value provided" {
    const TestArgs = struct {
        name: []const u8,
        count: u32 = 42,
        file: ?[]const u8 = null,
    };

    const args = [_][]const u8{ "testname", "123" };
    const result = try parseArgs(TestArgs, &args);

    try std.testing.expectEqualStrings("testname", result.name);
    try std.testing.expectEqual(@as(u32, 123), result.count); // Should use provided value
    try std.testing.expect(result.file == null);
}
