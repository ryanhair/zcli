const std = @import("std");
const diagnostic_errors = @import("diagnostic_errors.zig");
const type_utils = @import("type_utils.zig");

pub const ZcliError = diagnostic_errors.ZcliError;
pub const ZcliDiagnostic = diagnostic_errors.ZcliDiagnostic;

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
/// const parsed = try zcli.parseArgs(Args, &args, null);
/// // parsed.name = "Alice", parsed.age = 25, parsed.verbose = true
/// ```
///
/// ## Contract: positionals only
/// `args` must contain positional arguments only — every token is consumed
/// in order, exactly as given. parseArgs does NOT detect or skip `--flags`:
/// it cannot know the command's Options type, so any guess about whether a
/// flag consumes the next token would be wrong for someone (a boolean flag
/// followed by a real positional used to lose that positional). Splitting a
/// mixed command line is `parseCommandLine`'s job — it classifies with the
/// actual Options type, then hands the positionals here.
///
/// ## Returns
/// Returns ArgsType on success or ZcliError on failure.
/// Common errors include:
/// - `ArgumentMissingRequired`: Missing required argument
/// - `ArgumentInvalidValue`: Invalid argument value (e.g., non-numeric value for integer field)
/// - `ArgumentTooMany`: Too many arguments provided
pub fn parseArgs(comptime ArgsType: type, args: []const []const u8, diag: ?*?ZcliDiagnostic) ZcliError!ArgsType {
    return parseArgsInternal(ArgsType, args, diag);
}

/// Internal implementation of argument parsing
fn parseArgsInternal(comptime ArgsType: type, args: []const []const u8, diag: ?*?ZcliDiagnostic) ZcliError!ArgsType {
    const type_info = @typeInfo(ArgsType);
    if (type_info != .@"struct") {
        @compileError("Args must be a struct type");
    }

    const struct_info = type_info.@"struct";
    var result: ArgsType = undefined;
    var arg_index: usize = 0;

    // First, initialize all fields with defaults where available
    inline for (struct_info.fields) |field| {
        if (comptime type_utils.hasDefaultValue(ArgsType, field.name)) {
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
        } else if (comptime @typeInfo(field_type) == .optional) {
            // Optional field - consume the next argument if present
            const next_positional: ?usize = if (arg_index < args.len) arg_index else null;
            if (next_positional) |pos| {
                @field(result, field.name) = parseValue(field_type, args[pos]) catch |err| {
                    if (err == ZcliError.ArgumentInvalidValue) {
                        if (diag) |d| d.* = .{ .ArgumentInvalidValue = .{
                            .field_name = field.name,
                            .position = field_index,
                            .provided_value = args[pos],
                            .expected_type = @typeName(field_type),
                        } };
                    }
                    return err;
                };
                arg_index = pos + 1;
            } else {
                // Use null for optional
                @field(result, field.name) = null;
            }
        } else if (comptime type_utils.hasDefaultValue(ArgsType, field.name)) {
            // Field with default value - optional in parsing
            const next_positional: ?usize = if (arg_index < args.len) arg_index else null;
            if (next_positional) |pos| {
                @field(result, field.name) = parseValue(field_type, args[pos]) catch |err| {
                    if (err == ZcliError.ArgumentInvalidValue) {
                        if (diag) |d| d.* = .{ .ArgumentInvalidValue = .{
                            .field_name = field.name,
                            .position = field_index,
                            .provided_value = args[pos],
                            .expected_type = @typeName(field_type),
                        } };
                    }
                    return err;
                };
                arg_index = pos + 1;
            }
            // If no argument provided, default value is already set by struct initialization
        } else {
            // Required field - consume the next argument
            const next_positional: ?usize = if (arg_index < args.len) arg_index else null;
            if (next_positional == null) {
                if (diag) |d| d.* = .{ .ArgumentMissingRequired = .{
                    .field_name = field.name,
                    .position = field_index,
                    .expected_type = @typeName(field_type),
                } };
                return ZcliError.ArgumentMissingRequired;
            }

            const pos = next_positional.?;
            @field(result, field.name) = parseValue(field_type, args[pos]) catch |err| {
                if (err == ZcliError.ArgumentInvalidValue) {
                    if (diag) |d| d.* = .{ .ArgumentInvalidValue = .{
                        .field_name = field.name,
                        .position = field_index,
                        .provided_value = args[pos],
                        .expected_type = @typeName(field_type),
                    } };
                }
                return err;
            };
            arg_index = pos + 1;
        }
    }

    // Check if there are too many arguments (only if no varargs field)
    if (!hasVarArgs(ArgsType) and arg_index < args.len) {
        if (diag) |d| d.* = .{ .ArgumentTooMany = .{
            .expected_count = getRequiredArgCount(ArgsType),
            .actual_count = args.len,
        } };
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
        const parsed = try parseArgs(TestArgs, &args, null);
        try std.testing.expectEqualStrings("John", parsed.name);
        try std.testing.expectEqual(@as(u32, 25), parsed.age);
        try std.testing.expect(parsed.verbose.?);
    }

    // Test with default value
    {
        const args = [_][]const u8{ "Jane", "30" };
        const parsed = try parseArgs(TestArgs, &args, null);
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
    const parsed = try parseArgs(TestArgs, &args, null);

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
    const parsed = try parseArgs(TestArgs, &args, null);

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
        try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentMissingRequired, parseArgs(TestArgs, &args, null));
    }

    // Test invalid number
    {
        const args = [_][]const u8{ "test", "not_a_number" };
        try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentInvalidValue, parseArgs(TestArgs, &args, null));
    }

    // Test too many arguments (when no varargs)
    {
        const args = [_][]const u8{ "test", "123", "extra" };
        try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentTooMany, parseArgs(TestArgs, &args, null));
    }
}

test "parseArgs integer types" {
    const TestArgs = struct {
        port: u16,
        timeout: i32,
        size: i64,
    };

    const args = [_][]const u8{ "8080", "-30", "9223372036854775807" };

    const parsed = try parseArgs(TestArgs, &args, null);

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

    const parsed = try parseArgs(TestArgs, &args, null);

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
        const parsed = try parseArgs(TestArgs, &args, null);

        try std.testing.expectEqualStrings("server", parsed.name);
        try std.testing.expectEqual(@as(u16, 8080), parsed.port.?);
        try std.testing.expectEqualStrings("localhost", parsed.host.?);
    }

    // Test with no optionals provided
    {
        const args = [_][]const u8{"client"};
        const parsed = try parseArgs(TestArgs, &args, null);

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
        const parsed = try parseArgs(TestArgs, &args, null);

        try std.testing.expectEqualStrings("process", parsed.action);
        try std.testing.expect(parsed.verbose);
        try std.testing.expectEqual(@as(usize, 3), parsed.items.len);
    }

    // Test with no varargs
    {
        const args = [_][]const u8{ "clean", "false" };
        const parsed = try parseArgs(TestArgs, &args, null);

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
            try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentInvalidValue, parseArgs(TestArgs, &args, null));
        } else {
            const parsed = try parseArgs(TestArgs, &args, null);
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
        const parsed = try parseArgs(TestArgs, &args, null);
        try std.testing.expectEqual(Color.green, parsed.color);
    }

    // Test invalid enum value
    {
        const args = [_][]const u8{"yellow"};
        try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentInvalidValue, parseArgs(TestArgs, &args, null));
    }
}

test "parseArgs empty struct" {
    const EmptyArgs = struct {};

    // Test with no arguments
    {
        const args = [_][]const u8{};
        _ = try parseArgs(EmptyArgs, &args, null);
    }

    // Test with extra arguments
    {
        const args = [_][]const u8{"extra"};
        try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentTooMany, parseArgs(EmptyArgs, &args, null));
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

    const parsed = try parseArgs(IntArgs, &args, null);
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
    try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentInvalidValue, parseArgs(TestArgs, &args, null));
}

test "parseArgs negative value for unsigned" {
    const TestArgs = struct {
        val: u32,
    };

    const args = [_][]const u8{"-1"};
    try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentInvalidValue, parseArgs(TestArgs, &args, null));
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

    const parsed = try parseArgs(FloatArgs, &args, null);
    try std.testing.expectApproxEqAbs(@as(f16, 1.5), parsed.f16_val, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14159), parsed.f32_val, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.71828), parsed.f64_val, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f80, 123.456), parsed.f80_val, 0.001);
    try std.testing.expectApproxEqAbs(@as(f128, 789.012), parsed.f128_val, 0.001);
}

test "parseArgs consumes tokens in order, no option guessing" {
    // parseArgs' contract is positionals-only: it must NOT try to detect and
    // skip flags. (The old heuristic assumed every flag consumed the next
    // token, so a boolean flag followed by a real positional lost the
    // positional. Classification belongs to parseCommandLine, which knows
    // the Options type.)
    const TestArgs = struct {
        image: []const u8,
        command: ?[]const u8,
        args: [][]const u8,
    };

    const args = [_][]const u8{ "ubuntu", "bash", "arg1", "arg2" };
    const parsed = try parseArgs(TestArgs, &args, null);

    try std.testing.expectEqualStrings("ubuntu", parsed.image);
    try std.testing.expectEqualStrings("bash", parsed.command.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.args.len);
    try std.testing.expectEqualStrings("arg1", parsed.args[0]);
    try std.testing.expectEqualStrings("arg2", parsed.args[1]);

    // A dash token is data, not a flag to skip.
    const DashArgs = struct { first: []const u8, rest: [][]const u8 };
    const dash_args = [_][]const u8{ "--literal", "x" };
    const dashed = try parseArgs(DashArgs, &dash_args, null);
    try std.testing.expectEqualStrings("--literal", dashed.first);
}

test "parseArgs varargs empty" {
    const TestArgs = struct {
        files: [][]const u8,
    };

    const args = [_][]const u8{};
    const parsed = try parseArgs(TestArgs, &args, null);
    try std.testing.expectEqual(@as(usize, 0), parsed.files.len);
}

test "parseArgs varargs with const-safe type" {
    const TestArgs = struct {
        files: []const []const u8, // Using const-safe type
    };

    const args = [_][]const u8{ "file1.txt", "file2.txt", "file3.txt" };
    const parsed = try parseArgs(TestArgs, &args, null);
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
    const parsed = try parseArgs(TestArgs, &args, null);

    try std.testing.expectEqualStrings("build", parsed.command);
    try std.testing.expectEqual(true, parsed.verbose);
    try std.testing.expectEqual(@as(usize, 3), parsed.files.len);
    try std.testing.expectEqualStrings("file1.txt", parsed.files[0]);
    try std.testing.expectEqualStrings("file2.txt", parsed.files[1]);
    try std.testing.expectEqualStrings("file3.txt", parsed.files[2]);
}

test "parseArgs single optional argument" {
    const TestArgs = struct {
        shell: ?[]const u8 = null,
    };

    // Test with no args - should succeed with null
    {
        const args = [_][]const u8{};
        const parsed = try parseArgs(TestArgs, &args, null);
        try std.testing.expectEqual(@as(?[]const u8, null), parsed.shell);
    }

    // Test with one arg - should succeed with value
    {
        const args = [_][]const u8{"bash"};
        const parsed = try parseArgs(TestArgs, &args, null);
        try std.testing.expectEqualStrings("bash", parsed.shell.?);
    }
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
        const parsed = try parseArgs(TestArgs, &args, null);
        try std.testing.expectEqualStrings("req", parsed.required);
        try std.testing.expectEqualStrings("opt", parsed.optional1.?);
        try std.testing.expectEqual(@as(i32, 42), parsed.optional2.?);
    }

    // Test with partial values
    {
        const args = [_][]const u8{ "req", "opt" };
        const parsed = try parseArgs(TestArgs, &args, null);
        try std.testing.expectEqualStrings("req", parsed.required);
        try std.testing.expectEqualStrings("opt", parsed.optional1.?);
        try std.testing.expectEqual(@as(?i32, null), parsed.optional2);
    }

    // Test with minimal values
    {
        const args = [_][]const u8{"req"};
        const parsed = try parseArgs(TestArgs, &args, null);
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
    const parsed = try parseArgs(TestArgs, &args, null);

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

    try std.testing.expectError(diagnostic_errors.ZcliError.ArgumentMissingRequired, parseArgs(TestArgs, &args, null));
}

test "parseArgs varargs lifetime and safety" {
    // Test that varargs correctly reference the original args without copying
    const TestArgs = struct {
        command: []const u8,
        files: [][]const u8,
    };

    const args = [_][]const u8{ "test", "file1.txt", "file2.txt" };
    const parsed = try parseArgs(TestArgs, &args, null);

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
    const result = try parseArgs(TestArgs, &args, null);

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
    const result = try parseArgs(TestArgs, &args, null);

    try std.testing.expectEqualStrings("testname", result.name);
    try std.testing.expectEqual(@as(u32, 123), result.count); // Should use provided value
    try std.testing.expect(result.file == null);
}

// Edge case tests migrated from error_edge_cases_test.zig

test "parseArgs with multiple primitive types" {
    const Args = struct {
        count: u32,
        name: []const u8,
        flag: bool,
    };

    const args = [_][]const u8{ "42", "test", "true" };
    const parsed = try parseArgs(Args, &args, null);

    try std.testing.expectEqual(@as(u32, 42), parsed.count);
    try std.testing.expectEqualStrings("test", parsed.name);
    try std.testing.expectEqual(true, parsed.flag);
}

test "parseArgs with Unicode characters comprehensive" {
    const Args = struct {
        message: []const u8,
    };

    // Test various Unicode strings
    const unicode_tests = [_][]const u8{
        "Hello, 世界!", // Chinese
        "مرحبا بالعالم", // Arabic
        "🚀 Rocket", // Emoji
        "Ñoño niño", // Spanish with tildes
        "Здравствуй мир", // Russian
    };

    for (unicode_tests) |unicode_str| {
        const args = [_][]const u8{unicode_str};
        const parsed = try parseArgs(Args, &args, null);
        try std.testing.expectEqualStrings(unicode_str, parsed.message);
    }
}

test "parseArgs with maximum integer values" {
    const Args = struct {
        max_i64: i64,
        max_u64: u64,
        max_i32: i32,
        max_u32: u32,
    };

    // Test maximum values for different integer types
    const args = [_][]const u8{
        "9223372036854775807", // i64 max
        "18446744073709551615", // u64 max
        "2147483647", // i32 max
        "4294967295", // u32 max
    };

    const parsed = try parseArgs(Args, &args, null);

    try std.testing.expectEqual(@as(i64, 9223372036854775807), parsed.max_i64);
    try std.testing.expectEqual(@as(u64, 18446744073709551615), parsed.max_u64);
    try std.testing.expectEqual(@as(i32, 2147483647), parsed.max_i32);
    try std.testing.expectEqual(@as(u32, 4294967295), parsed.max_u32);
}

test "parseArgs with minimum integer values" {
    const Args = struct {
        min_i64: i64,
        min_i32: i32,
        min_i16: i16,
        min_i8: i8,
    };

    const args = [_][]const u8{
        "-9223372036854775808", // i64 min
        "-2147483648", // i32 min
        "-32768", // i16 min
        "-128", // i8 min
    };

    const parsed = try parseArgs(Args, &args, null);

    try std.testing.expectEqual(@as(i64, -9223372036854775808), parsed.min_i64);
    try std.testing.expectEqual(@as(i32, -2147483648), parsed.min_i32);
    try std.testing.expectEqual(@as(i16, -32768), parsed.min_i16);
    try std.testing.expectEqual(@as(i8, -128), parsed.min_i8);
}

test "parseArgs integer overflow edge cases comprehensive" {
    const Args = struct {
        val: u8,
    };

    // Test values that would overflow u8
    const overflow_cases = [_][]const u8{
        "256", // Just over max
        "1000", // Way over max
        "99999", // Very large
        "-1", // Negative for unsigned
        "-128", // Negative
    };

    for (overflow_cases) |case| {
        const args = [_][]const u8{case};
        try std.testing.expectError(ZcliError.ArgumentInvalidValue, parseArgs(Args, &args, null));
    }
}

test "parseArgs with malformed float values" {
    const Args = struct {
        val: f32,
    };

    const invalid_floats = [_][]const u8{
        "not_a_number",
        "1.2.3", // Multiple decimal points
        "1e", // Incomplete scientific notation
        "1e++5", // Invalid exponent
        "", // Empty string
        " ", // Whitespace
        "1.0extra", // Extra characters
    };

    for (invalid_floats) |invalid| {
        const args = [_][]const u8{invalid};
        // We expect ArgumentInvalidValue for malformed float values
        _ = parseArgs(Args, &args, null) catch |err| {
            try std.testing.expect(err == ZcliError.ArgumentInvalidValue or err == ZcliError.ArgumentMissingRequired);
            continue;
        };
        return error.TestFailed; // Should not reach here
    }
}

test "diagnostics: argument error sites fill precise context" {
    const Args = struct {
        name: []const u8,
        age: u32 = 0,
    };

    // Missing required argument.
    {
        var diag: ?ZcliDiagnostic = null;
        try std.testing.expectError(ZcliError.ArgumentMissingRequired, parseArgs(Args, &.{}, &diag));
        try std.testing.expectEqualStrings("name", diag.?.ArgumentMissingRequired.field_name);
        try std.testing.expectEqual(@as(usize, 0), diag.?.ArgumentMissingRequired.position);
    }

    // Invalid value for a typed argument.
    {
        var diag: ?ZcliDiagnostic = null;
        const args = [_][]const u8{ "alice", "young" };
        try std.testing.expectError(ZcliError.ArgumentInvalidValue, parseArgs(Args, &args, &diag));
        try std.testing.expectEqualStrings("age", diag.?.ArgumentInvalidValue.field_name);
        try std.testing.expectEqualStrings("young", diag.?.ArgumentInvalidValue.provided_value);
    }

    // Too many arguments.
    {
        const Exact = struct { only: []const u8 };
        var diag: ?ZcliDiagnostic = null;
        const args = [_][]const u8{ "one", "two" };
        try std.testing.expectError(ZcliError.ArgumentTooMany, parseArgs(Exact, &args, &diag));
        try std.testing.expectEqual(@as(usize, 2), diag.?.ArgumentTooMany.actual_count);
    }
}
