const std = @import("std");
const logging = @import("logging.zig");
const StructuredError = @import("structured_errors.zig").StructuredError;
const ErrorBuilder = @import("structured_errors.zig").ErrorBuilder;

/// Parse result that can be either success or a structured error
pub fn ParseResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: StructuredError,

        pub fn unwrap(self: @This()) T {
            return switch (self) {
                .ok => |value| value,
                .err => @panic("Tried to unwrap error result"),
            };
        }

        pub fn isError(self: @This()) bool {
            return switch (self) {
                .ok => false,
                .err => true,
            };
        }

        pub fn getError(self: @This()) ?StructuredError {
            return switch (self) {
                .ok => null,
                .err => |err| err,
            };
        }
    };
}

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
/// Returns a ParseResult union that contains either:
/// - `.ok`: Successfully parsed arguments of type ArgsType
/// - `.err`: Structured error with rich context information including:
///   - `argument_missing_required`: Missing required argument with field name, position, expected type
///   - `argument_invalid_value`: Invalid argument value with provided value, field name, position, expected type
///   - `argument_too_many`: Too many arguments provided with expected count
///   - `system_out_of_memory`: Out of memory
pub fn parseArgs(comptime ArgsType: type, args: []const []const u8) ParseResult(ArgsType) {
    return parseArgsInternal(ArgsType, args);
}

/// Parse positional arguments with structured error support (internal version)
/// This captures more context about errors for better user experience
fn parseArgsInternal(comptime ArgsType: type, args: []const []const u8) ParseResult(ArgsType) {
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
            // This is a varargs field ([][]const u8) - capture remaining positional arguments
            // We need to create a slice that references the original args but skips options
            // For now, use a simpler approach that works with current memory model
            const remaining_args = args[arg_index..];
            @field(result, field.name) = @constCast(remaining_args);
            break;
        } else if (@typeInfo(field_type) == .optional) {
            // Optional field - find next positional argument
            const next_positional = findNextPositional(args, arg_index);
            if (next_positional) |pos| {
                const parsed_value = parseValueWithContext(field_type, args[pos], field.name, field_index);
                if (parsed_value.isError()) {
                    return ParseResult(ArgsType){ .err = parsed_value.getError().? };
                }
                @field(result, field.name) = parsed_value.unwrap();
                arg_index = pos + 1;
            } else {
                // Use null for optional
                @field(result, field.name) = null;
            }
        } else {
            // Required field - find next positional argument
            const next_positional = findNextPositional(args, arg_index);
            if (next_positional == null) {
                logging.missingRequiredArgument(field.name, field_index + 1);
                return ParseResult(ArgsType){ .err = ErrorBuilder.missingRequiredArgument(field.name, field_index, @typeName(field_type)) };
            }
            
            const pos = next_positional.?;
            const parsed_value = parseValueWithContext(field_type, args[pos], field.name, field_index);
            if (parsed_value.isError()) {
                return ParseResult(ArgsType){ .err = parsed_value.getError().? };
            }
            @field(result, field.name) = parsed_value.unwrap();
            arg_index = pos + 1;
        }
    }

    // Check if there are too many arguments (only if no varargs field)
    if (!hasVarArgs(ArgsType) and arg_index < args.len) {
        const expected_count = getRequiredArgCount(ArgsType);
        logging.tooManyArguments(expected_count, args.len);
        return ParseResult(ArgsType){ .err = StructuredError{ .argument_too_many = @import("structured_errors.zig").ArgumentErrorContext.tooMany(expected_count, args.len) } };
    }

    return ParseResult(ArgsType){ .ok = result };
}

/// Parse a single value with structured error context
fn parseValueWithContext(comptime T: type, value: []const u8, field_name: []const u8, field_index: usize) ParseResult(T) {
    const parsed = parseValue(T, value) catch {
        return ParseResult(T){ .err = ErrorBuilder.invalidArgumentValue(field_name, field_index, value, @typeName(T)) };
    };
    return ParseResult(T){ .ok = parsed };
}

/// Simple error type for basic parsing without context
const SimpleParseError = error{
    InvalidArgumentType,
    OutOfMemory,
};

/// Public error type for backwards compatibility
/// Note: New code should use ParseResult which provides structured errors with rich context
pub const ParseError = SimpleParseError;

/// Parse a single value based on its type
fn parseValue(comptime T: type, value: []const u8) SimpleParseError!T {
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
                return SimpleParseError.InvalidArgumentType;
            };
        },
        .float => {
            return std.fmt.parseFloat(T, value) catch {
                return SimpleParseError.InvalidArgumentType;
            };
        },
        .bool => {
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
                return true;
            } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
                return false;
            } else {
                return SimpleParseError.InvalidArgumentType;
            }
        },
        .@"enum" => {
            return std.meta.stringToEnum(T, value) orelse {
                return SimpleParseError.InvalidArgumentType;
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
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();
        try std.testing.expectEqualStrings("John", parsed.name);
        try std.testing.expectEqual(@as(u32, 25), parsed.age);
        try std.testing.expect(parsed.verbose.?);
    }

    // Test with default value
    {
        const args = [_][]const u8{ "Jane", "30" };
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();
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
    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

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
    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

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
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(result.isError());
        const err = result.getError().?;
        try std.testing.expect(err == .argument_missing_required);
    }

    // Test invalid number
    {
        const args = [_][]const u8{ "test", "not_a_number" };
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(result.isError());
        const err = result.getError().?;
        try std.testing.expect(err == .argument_invalid_value);
    }

    // Test too many arguments (when no varargs)
    {
        const args = [_][]const u8{ "test", "123", "extra" };
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(result.isError());
        const err = result.getError().?;
        try std.testing.expect(err == .argument_too_many);
    }
}

test "parseArgs integer types" {
    const TestArgs = struct {
        port: u16,
        timeout: i32,
        size: i64,
    };

    const args = [_][]const u8{ "8080", "-30", "9223372036854775807" };

    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

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

    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

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
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();

        try std.testing.expectEqualStrings("server", parsed.name);
        try std.testing.expectEqual(@as(u16, 8080), parsed.port.?);
        try std.testing.expectEqualStrings("localhost", parsed.host.?);
    }

    // Test with no optionals provided
    {
        const args = [_][]const u8{"client"};
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();

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
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();

        try std.testing.expectEqualStrings("process", parsed.action);
        try std.testing.expect(parsed.verbose);
        try std.testing.expectEqual(@as(usize, 3), parsed.items.len);
    }

    // Test with no varargs
    {
        const args = [_][]const u8{ "clean", "false" };
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();

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
        .{ "TRUE", error.argument_invalid_value },
        .{ "yes", error.argument_invalid_value },
        .{ "on", error.argument_invalid_value },
    };

    inline for (test_cases) |test_case| {
        const args = [_][]const u8{test_case[0]};

        if (@TypeOf(test_case[1]) == @TypeOf(error.argument_invalid_value)) {
            const result = parseArgs(TestArgs, &args);
            try std.testing.expect(result.isError());
            const err = result.getError().?;
            try std.testing.expect(err == .argument_invalid_value);
        } else {
            const result = parseArgs(TestArgs, &args);
            try std.testing.expect(!result.isError());
            const parsed = result.unwrap();
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
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();
        try std.testing.expectEqual(Color.green, parsed.color);
    }

    // Test invalid enum value
    {
        const args = [_][]const u8{"yellow"};
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(result.isError());
        const err = result.getError().?;
        try std.testing.expect(err == .argument_invalid_value);
    }
}

test "parseArgs empty struct" {
    const EmptyArgs = struct {};

    // Test with no arguments
    {
        const args = [_][]const u8{};
        const result = parseArgs(EmptyArgs, &args);
        try std.testing.expect(!result.isError());
        _ = result.unwrap();
    }

    // Test with extra arguments
    {
        const args = [_][]const u8{"extra"};
        const result = parseArgs(EmptyArgs, &args);
        try std.testing.expect(result.isError());
        const err = result.getError().?;
        try std.testing.expect(err == .argument_too_many);
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

    const result = parseArgs(IntArgs, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();
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
    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(result.isError());
    const err = result.getError().?;
    try std.testing.expect(err == .argument_invalid_value);
}

test "parseArgs negative value for unsigned" {
    const TestArgs = struct {
        val: u32,
    };

    const args = [_][]const u8{"-1"};
    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(result.isError());
    const err = result.getError().?;
    try std.testing.expect(err == .argument_invalid_value);
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

    const result = parseArgs(FloatArgs, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();
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
    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

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
    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();
    try std.testing.expectEqual(@as(usize, 0), parsed.files.len);
}

test "parseArgs varargs with preceding required args" {
    const TestArgs = struct {
        command: []const u8,
        verbose: bool,
        files: [][]const u8,
    };

    const args = [_][]const u8{ "build", "true", "file1.txt", "file2.txt", "file3.txt" };
    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

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
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();
        try std.testing.expectEqualStrings("req", parsed.required);
        try std.testing.expectEqualStrings("opt", parsed.optional1.?);
        try std.testing.expectEqual(@as(i32, 42), parsed.optional2.?);
    }

    // Test with partial values
    {
        const args = [_][]const u8{ "req", "opt" };
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();
        try std.testing.expectEqualStrings("req", parsed.required);
        try std.testing.expectEqualStrings("opt", parsed.optional1.?);
        try std.testing.expectEqual(@as(?i32, null), parsed.optional2);
    }

    // Test with minimal values
    {
        const args = [_][]const u8{"req"};
        const result = parseArgs(TestArgs, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();
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
    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

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

    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(result.isError());

    // Get the structured error directly
    const structured_error = result.getError().?;

    switch (structured_error) {
        .argument_missing_required => |ctx| {
            try std.testing.expectEqualStrings("name", ctx.field_name);
            try std.testing.expectEqual(@as(usize, 0), ctx.position);
            try std.testing.expectEqualStrings("[]const u8", ctx.expected_type);
        },
        else => try std.testing.expect(false),
    }
}

test "parseArgs varargs lifetime and safety" {
    // Test that varargs correctly reference the original args without copying
    const TestArgs = struct {
        command: []const u8,
        files: [][]const u8,
    };

    const args = [_][]const u8{ "test", "file1.txt", "file2.txt" };
    const result = parseArgs(TestArgs, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

    // Verify that the varargs slice points to the same memory as the original args
    try std.testing.expectEqual(@as(usize, 2), parsed.files.len);
    try std.testing.expectEqual(@intFromPtr(args[1].ptr), @intFromPtr(parsed.files[0].ptr));
    try std.testing.expectEqual(@intFromPtr(args[2].ptr), @intFromPtr(parsed.files[1].ptr));

    // This demonstrates that we're not copying the strings, just referencing them
    // The @constCast is safe because we maintain the immutability of the strings
}
