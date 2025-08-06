const std = @import("std");

pub const OptionParseError = error{
    UnknownOption,
    MissingOptionValue,
    InvalidOptionValue,
    DuplicateOption,
    OutOfMemory,
};

pub const ParseResult = struct {
    /// The position where option parsing stopped (first non-option argument)
    next_arg_index: usize,
};

pub fn OptionsResult(comptime OptionsType: type) type {
    return struct { options: OptionsType, result: ParseResult };
}

// Union type to handle different ArrayList types for array accumulation
const ArrayListUnion = union(enum) {
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

    fn deinit(self: *ArrayListUnion) void {
        switch (self.*) {
            inline else => |*list| list.deinit(),
        }
    }
};

/// Parse command-line options based on the provided Options struct type
///
/// ## Memory Management
///
/// Array fields will accumulate values and return owned slices that MUST be freed.
/// The zcli framework generates automatic cleanup in the command registry, but if you're
/// using parseOptions directly, you must free array fields manually.
///
/// ### Supported Array Types:
/// - `[][]const u8` - Array of strings
/// - `[]i32`, `[]u32`, `[]i64`, `[]u64` - Integer arrays
/// - `[]i16`, `[]u16`, `[]i8`, `[]u8` - Small integer arrays
/// - `[]f32`, `[]f64` - Float arrays
///
/// ### Manual Usage Example:
/// ```zig
/// const Options = struct {
///     files: [][]const u8 = &.{},     // Array field - needs cleanup
///     counts: []i32 = &.{},           // Array field - needs cleanup
///     verbose: bool = false,          // Non-array field - no cleanup needed
/// };
///
/// const parsed = try parseOptions(Options, allocator, args);
/// defer allocator.free(parsed.options.files);  // REQUIRED
/// defer allocator.free(parsed.options.counts); // REQUIRED
/// ```
///
/// ### Automatic Cleanup (when using zcli framework):
/// When commands are executed through the zcli framework, array cleanup is automatic.
/// The generated command registry includes cleanup code that frees all array fields.
pub fn parseOptions(
    comptime OptionsType: type,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) OptionParseError!OptionsResult(OptionsType) {
    return parseOptionsWithMeta(OptionsType, null, allocator, args);
}

pub fn parseOptionsWithMeta(
    comptime OptionsType: type,
    comptime meta: anytype,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) OptionParseError!OptionsResult(OptionsType) {
    const type_info = @typeInfo(OptionsType);

    if (type_info != .@"struct") {
        @compileError("Options must be a struct type");
    }

    const struct_info = type_info.@"struct";
    var result: OptionsType = undefined;

    // Track array accumulation for each field
    var array_lists: [struct_info.fields.len]?ArrayListUnion = undefined;
    defer {
        for (&array_lists) |*list| {
            if (list.*) |*l| {
                l.deinit();
            }
        }
    }

    // Initialize with default values
    inline for (struct_info.fields, 0..) |field, i| {
        array_lists[i] = null;

        if (comptime isArrayType(field.type)) {
            // Initialize array fields with empty arrays of the correct type
            const element_type = @typeInfo(field.type).pointer.child;
            @field(result, field.name) = @as(field.type, &[_]element_type{});
            // Create ArrayList for accumulation based on element type
            array_lists[i] = switch (element_type) {
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
                else => @compileError("Unsupported array element type: " ++ @typeName(element_type)),
            };
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else if (field.type == bool) {
            @field(result, field.name) = false;
        } else {
            // Required field without default - initialize to undefined for now
            @field(result, field.name) = undefined;
        }
    }

    var arg_index: usize = 0;
    var option_counts = std.StringHashMap(u32).init(allocator);
    defer option_counts.deinit();

    while (arg_index < args.len) {
        const arg = args[arg_index];

        // Stop parsing options at "--"
        if (std.mem.eql(u8, arg, "--")) {
            arg_index += 1;
            break;
        }

        // Not an option, stop parsing
        if (!std.mem.startsWith(u8, arg, "-")) {
            break;
        }

        // Check if this is a negative number - if so, stop parsing options
        if (isNegativeNumber(arg)) {
            break;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            // Long option
            const consumed = try parseLongOptions(OptionsType, meta, &result, &option_counts, args, arg_index, &array_lists, allocator);
            arg_index += consumed;
        } else {
            // Short option(s)
            const consumed = try parseShortOptionsWithMeta(OptionsType, meta, &result, &option_counts, args, arg_index, &array_lists, allocator);
            arg_index += consumed;
        }
    }

    // Finalize array fields by converting ArrayLists to slices
    inline for (struct_info.fields, 0..) |field, i| {
        if (comptime isArrayType(field.type)) {
            if (array_lists[i]) |*list_union| {
                const element_type = @typeInfo(field.type).pointer.child;
                switch (element_type) {
                    []const u8 => @field(result, field.name) = try list_union.strings.toOwnedSlice(),
                    i32 => @field(result, field.name) = try list_union.i32s.toOwnedSlice(),
                    u32 => @field(result, field.name) = try list_union.u32s.toOwnedSlice(),
                    i16 => @field(result, field.name) = try list_union.i16s.toOwnedSlice(),
                    u16 => @field(result, field.name) = try list_union.u16s.toOwnedSlice(),
                    i8 => @field(result, field.name) = try list_union.i8s.toOwnedSlice(),
                    u8 => @field(result, field.name) = try list_union.u8s.toOwnedSlice(),
                    i64 => @field(result, field.name) = try list_union.i64s.toOwnedSlice(),
                    u64 => @field(result, field.name) = try list_union.u64s.toOwnedSlice(),
                    f32 => @field(result, field.name) = try list_union.f32s.toOwnedSlice(),
                    f64 => @field(result, field.name) = try list_union.f64s.toOwnedSlice(),
                    else => @compileError("Unsupported array element type: " ++ @typeName(element_type)),
                }
            }
        }
    }

    return .{
        .options = result,
        .result = .{ .next_arg_index = arg_index },
    };
}

/// Parse a long option with metadata support (--option or --option=value)
fn parseLongOptions(
    comptime OptionsType: type,
    comptime meta: anytype,
    result: *OptionsType,
    option_counts: *std.StringHashMap(u32),
    args: []const []const u8,
    arg_index: usize,
    array_lists: anytype,
    allocator: std.mem.Allocator,
) OptionParseError!usize {
    _ = allocator; // Currently unused
    const arg = args[arg_index];
    const option_part = arg[2..]; // Skip "--"

    var option_name: []const u8 = undefined;
    var option_value: ?[]const u8 = null;

    // Check for --option=value syntax
    if (std.mem.indexOf(u8, option_part, "=")) |eq_index| {
        option_name = option_part[0..eq_index];
        option_value = option_part[eq_index + 1 ..];
    } else {
        option_name = option_part;
    }

    // Convert dashes to underscores for field name
    var option_field_name_buf: [64]u8 = undefined;
    const option_field_name = dashesToUnderscores(option_field_name_buf[0..], option_name) catch |err| {
        return err;
    };

    // Generate field matching code at comptime
    var found = false;
    inline for (@typeInfo(OptionsType).@"struct".fields, 0..) |field, i| {
        // Check if this field matches the option name, either by field name or custom name
        const matches = blk: {
            // Check if this field has a custom name in metadata
            if (comptime @TypeOf(meta) != @TypeOf(null)) {
                if (comptime @hasField(@TypeOf(meta), "options")) {
                    const options_meta = meta.options;
                    if (comptime @hasField(@TypeOf(options_meta), field.name)) {
                        const field_meta = @field(options_meta, field.name);
                        if (comptime @hasField(@TypeOf(field_meta), "name")) {
                            // Custom name is specified - only match on custom name, not field name
                            break :blk std.mem.eql(u8, field_meta.name, option_name);
                        }
                    }
                }
            }
            // No custom name specified - fall back to standard field name matching
            break :blk std.mem.eql(u8, field.name, option_field_name) or std.mem.eql(u8, field.name, option_name);
        };

        if (matches) {
            found = true;

            // Track usage count for duplicate detection (use field name for tracking)
            const count = option_counts.get(field.name) orelse 0;
            try option_counts.put(field.name, count + 1);

            // Handle boolean flags
            if (comptime isBooleanType(field.type)) {
                if (option_value != null) {
                    std.log.err("Boolean option --{s} does not take a value", .{option_name});
                    return OptionParseError.InvalidOptionValue;
                }
                @field(result, field.name) = true;
                return 1;
            }

            // Get the value
            const value = blk: {
                if (option_value) |val| {
                    break :blk val;
                } else if (arg_index + 1 < args.len and (!std.mem.startsWith(u8, args[arg_index + 1], "-") or isNegativeNumber(args[arg_index + 1]))) {
                    break :blk args[arg_index + 1];
                } else {
                    std.log.err("Option --{s} requires a value", .{option_name});
                    return OptionParseError.MissingOptionValue;
                }
            };

            // Parse and set the value based on field type
            if (comptime isArrayType(field.type)) {
                // Handle array accumulation
                const element_type = @typeInfo(field.type).pointer.child;
                if (array_lists[i]) |*list_union| {
                    switch (element_type) {
                        []const u8 => try list_union.strings.append(value),
                        i32 => {
                            const parsed_value = parseOptionValue(i32, value) catch |err| {
                                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                                return err;
                            };
                            try list_union.i32s.append(parsed_value);
                        },
                        u32 => {
                            const parsed_value = parseOptionValue(u32, value) catch |err| {
                                std.log.err("Invalid value for option --{s}: {s}", .{ option_name, value });
                                return err;
                            };
                            try list_union.u32s.append(parsed_value);
                        },
                        // Add other types as needed...
                        else => @compileError("Unsupported array element type: " ++ @typeName(element_type)),
                    }
                }
            } else {
                // Handle single values
                const parsed_value = parseOptionValue(field.type, value) catch |err| {
                    return err;
                };
                @field(result, field.name) = parsed_value;
            }

            // Return number of arguments consumed
            return if (option_value != null) 1 else 2;
        }
    }

    if (!found) {
        std.log.err("Unknown option: --{s}", .{option_name});
        return OptionParseError.UnknownOption;
    }

    return 1;
}

/// Parse short options with metadata support (-o or -ovalue or -abc)
fn parseShortOptionsWithMeta(
    comptime OptionsType: type,
    comptime meta: anytype,
    result: *OptionsType,
    option_counts: *std.StringHashMap(u32),
    args: []const []const u8,
    arg_index: usize,
    array_lists: anytype,
    allocator: std.mem.Allocator,
) OptionParseError!usize {
    // For now, just delegate to the original function
    // TODO: Implement metadata support for short options if needed
    _ = meta;
    return parseShortOptions(OptionsType, result, option_counts, args, arg_index, array_lists, allocator);
}

/// Parse short option(s) (-o or -ovalue or -abc)
fn parseShortOptions(
    comptime OptionsType: type,
    result: *OptionsType,
    option_counts: *std.StringHashMap(u32),
    args: []const []const u8,
    arg_index: usize,
    array_lists: anytype,
    allocator: std.mem.Allocator,
) OptionParseError!usize {
    _ = allocator; // Currently unused
    const arg = args[arg_index];
    const options_part = arg[1..]; // Skip "-"

    if (options_part.len == 0) {
        std.log.err("Invalid option: -", .{});
        return OptionParseError.UnknownOption;
    }

    // Try to parse as bundled boolean flags first
    var all_boolean = true;
    for (options_part) |char| {
        var char_field_found = false;
        var char_is_boolean = false;
        inline for (@typeInfo(OptionsType).@"struct".fields) |field| {
            if (field.name.len > 0 and field.name[0] == char) {
                char_field_found = true;
                char_is_boolean = comptime isBooleanType(field.type);
                break;
            }
        }
        if (!char_field_found or !char_is_boolean) {
            all_boolean = false;
            break;
        }
    }

    if (all_boolean and options_part.len > 1) {
        // Parse as bundled boolean flags
        for (options_part) |char| {
            inline for (@typeInfo(OptionsType).@"struct".fields, 0..) |field, i| {
                _ = i; // Unused for boolean flags
                if (field.name.len > 0 and field.name[0] == char) {
                    if (comptime isBooleanType(field.type)) {
                        // Track usage count
                        const count = option_counts.get(field.name) orelse 0;
                        try option_counts.put(field.name, count + 1);
                        @field(result, field.name) = true;
                    }
                    break;
                }
            }
        }
        return 1;
    } else {
        // Parse as single option, possibly with value
        const char = options_part[0];

        var char_found = false;
        inline for (@typeInfo(OptionsType).@"struct".fields, 0..) |field, i| {
            if (field.name.len > 0 and field.name[0] == char) {
                char_found = true;

                // Track usage count for duplicate detection
                const count = option_counts.get(field.name) orelse 0;
                try option_counts.put(field.name, count + 1);

                if (comptime isBooleanType(field.type)) {
                    @field(result, field.name) = true;
                    return 1;
                } else {
                    // Value-taking option
                    var value: []const u8 = undefined;
                    var consumed: usize = 1;

                    if (options_part.len > 1) {
                        // Value attached: -ovalue
                        value = options_part[1..];
                    } else {
                        // Value in next argument
                        if (arg_index + 1 >= args.len) {
                            std.log.err("Option -{c} requires a value", .{char});
                            return OptionParseError.MissingOptionValue;
                        }
                        value = args[arg_index + 1];
                        consumed = 2;
                    }

                    if (comptime isArrayType(field.type)) {
                        // For array types, accumulate values
                        if (array_lists.*[i]) |*list_union| {
                            const element_type = @typeInfo(field.type).pointer.child;
                            switch (element_type) {
                                []const u8 => try list_union.strings.append(value),
                                i32 => {
                                    const element_value = parseOptionValue(element_type, value) catch |err| {
                                        std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                                        return err;
                                    };
                                    try list_union.i32s.append(element_value);
                                },
                                u32 => {
                                    const element_value = parseOptionValue(element_type, value) catch |err| {
                                        std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                                        return err;
                                    };
                                    try list_union.u32s.append(element_value);
                                },
                                i16 => {
                                    const element_value = parseOptionValue(element_type, value) catch |err| {
                                        std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                                        return err;
                                    };
                                    try list_union.i16s.append(element_value);
                                },
                                u16 => {
                                    const element_value = parseOptionValue(element_type, value) catch |err| {
                                        std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                                        return err;
                                    };
                                    try list_union.u16s.append(element_value);
                                },
                                i8 => {
                                    const element_value = parseOptionValue(element_type, value) catch |err| {
                                        std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                                        return err;
                                    };
                                    try list_union.i8s.append(element_value);
                                },
                                u8 => {
                                    const element_value = parseOptionValue(element_type, value) catch |err| {
                                        std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                                        return err;
                                    };
                                    try list_union.u8s.append(element_value);
                                },
                                i64 => {
                                    const element_value = parseOptionValue(element_type, value) catch |err| {
                                        std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                                        return err;
                                    };
                                    try list_union.i64s.append(element_value);
                                },
                                u64 => {
                                    const element_value = parseOptionValue(element_type, value) catch |err| {
                                        std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                                        return err;
                                    };
                                    try list_union.u64s.append(element_value);
                                },
                                f32 => {
                                    const element_value = parseOptionValue(element_type, value) catch |err| {
                                        std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                                        return err;
                                    };
                                    try list_union.f32s.append(element_value);
                                },
                                f64 => {
                                    const element_value = parseOptionValue(element_type, value) catch |err| {
                                        std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                                        return err;
                                    };
                                    try list_union.f64s.append(element_value);
                                },
                                else => @compileError("Unsupported array element type: " ++ @typeName(element_type)),
                            }
                        }
                    } else {
                        const parsed_value = parseOptionValue(field.type, value) catch |err| {
                            std.log.err("Invalid value for option -{c}: {s}", .{ char, value });
                            return err;
                        };
                        @field(result, field.name) = parsed_value;
                    }
                    return consumed;
                }
            }
        }

        if (!char_found) {
            std.log.err("Unknown option: -{c}", .{char});
            return OptionParseError.UnknownOption;
        }

        return 0; // Should never reach here
    }
}

/// Convert dashes to underscores in option names
fn dashesToUnderscores(buf: []u8, input: []const u8) OptionParseError![]const u8 {
    if (input.len > buf.len) {
        std.log.err("Option name too long (max 64 characters): --{s}", .{input});
        return OptionParseError.UnknownOption;
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
fn isBooleanType(comptime T: type) bool {
    return T == bool;
}

/// Check if a type is an array type (for accumulating values)
/// Returns true for arrays like [][]const u8, []i32, etc.
/// Returns false for strings like []const u8
fn isArrayType(comptime T: type) bool {
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
fn parseOptionValue(comptime T: type, value: []const u8) OptionParseError!T {
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
            return std.fmt.parseInt(T, value, 0) catch {
                return OptionParseError.InvalidOptionValue;
            };
        },
        .float => {
            return std.fmt.parseFloat(T, value) catch {
                return OptionParseError.InvalidOptionValue;
            };
        },
        .@"enum" => {
            return std.meta.stringToEnum(T, value) orelse {
                return OptionParseError.InvalidOptionValue;
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
test "parseOptions basic" {
    const TestOptions = struct {
        verbose: bool = false,
        name: []const u8 = "default",
        count: u32 = 1,
    };

    const allocator = std.testing.allocator;

    {
        const args = [_][]const u8{ "--verbose", "--name", "test", "--count", "42" };
        const parsed = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(parsed.options.verbose);
        try std.testing.expectEqualStrings("test", parsed.options.name);
        try std.testing.expectEqual(@as(u32, 42), parsed.options.count);
        try std.testing.expectEqual(@as(usize, 5), parsed.result.next_arg_index);
    }
}

test "parseOptions short flags" {
    const TestOptions = struct {
        verbose: bool = false,
        quiet: bool = false,
    };

    const allocator = std.testing.allocator;

    {
        const args = [_][]const u8{"-vq"};
        const parsed = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(parsed.options.verbose);
        try std.testing.expect(parsed.options.quiet);
    }
}

test "parseOptions long option with equals" {
    const TestOptions = struct {
        name: []const u8 = "default",
        port: u16 = 8080,
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--name=myapp", "--port=3000", "--verbose" };
    const parsed = try parseOptions(TestOptions, allocator, &args);

    try std.testing.expectEqualStrings("myapp", parsed.options.name);
    try std.testing.expectEqual(@as(u16, 3000), parsed.options.port);
    try std.testing.expect(parsed.options.verbose);
}

test "parseOptions short option with value" {
    const TestOptions = struct {
        name: []const u8 = "default",
        port: u16 = 8080,
    };

    const allocator = std.testing.allocator;

    // Test with space
    {
        const args = [_][]const u8{ "-n", "test", "-p", "9000" };
        const parsed = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expectEqualStrings("test", parsed.options.name);
        try std.testing.expectEqual(@as(u16, 9000), parsed.options.port);
    }

    // Test without space
    {
        const args = [_][]const u8{ "-ntest2", "-p9001" };
        const parsed = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expectEqualStrings("test2", parsed.options.name);
        try std.testing.expectEqual(@as(u16, 9001), parsed.options.port);
    }
}

test "parseOptions double dash stops parsing" {
    const TestOptions = struct {
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--verbose", "--", "--not-an-option" };
    const parsed = try parseOptions(TestOptions, allocator, &args);

    try std.testing.expect(parsed.options.verbose);
    try std.testing.expectEqual(@as(usize, 2), parsed.result.next_arg_index);
}

test "parseOptions enum types" {
    const LogLevel = enum { debug, info, warn, err };
    const TestOptions = struct {
        level: LogLevel = .info,
        format: enum { json, text } = .text,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--level", "debug", "--format", "json" };
    const parsed = try parseOptions(TestOptions, allocator, &args);

    try std.testing.expectEqual(LogLevel.debug, parsed.options.level);
    try std.testing.expectEqual(@as(@TypeOf(parsed.options.format), .json), parsed.options.format);
}

test "parseOptions optional types" {
    const TestOptions = struct {
        config: ?[]const u8 = null,
        port: ?u16 = null,
    };

    const allocator = std.testing.allocator;

    // Test with values provided
    {
        const args = [_][]const u8{ "--config", "app.conf", "--port", "8080" };
        const parsed = try parseOptions(TestOptions, allocator, &args);

        try std.testing.expectEqualStrings("app.conf", parsed.options.config.?);
        try std.testing.expectEqual(@as(u16, 8080), parsed.options.port.?);
    }

    // Test with defaults
    {
        const args = [_][]const u8{};
        const parsed = try parseOptions(TestOptions, allocator, &args);

        try std.testing.expectEqual(@as(?[]const u8, null), parsed.options.config);
        try std.testing.expectEqual(@as(?u16, null), parsed.options.port);
    }
}

test "parseOptions dash to underscore conversion" {
    const TestOptions = struct {
        no_color: bool = false,
        log_level: []const u8 = "info",
        max_retries: u32 = 3,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--no-color", "--log-level", "debug", "--max-retries", "5" };
    const parsed = try parseOptions(TestOptions, allocator, &args);

    try std.testing.expect(parsed.options.no_color);
    try std.testing.expectEqualStrings("debug", parsed.options.log_level);
    try std.testing.expectEqual(@as(u32, 5), parsed.options.max_retries);
}

test "parseOptions error cases" {
    const TestOptions = struct {
        name: []const u8 = "default",
        count: u32 = 1,
    };

    const allocator = std.testing.allocator;

    // Unknown option
    {
        const args = [_][]const u8{"--unknown"};
        try std.testing.expectError(OptionParseError.UnknownOption, parseOptions(TestOptions, allocator, &args));
    }

    // Missing option value
    {
        const args = [_][]const u8{"--name"};
        try std.testing.expectError(OptionParseError.MissingOptionValue, parseOptions(TestOptions, allocator, &args));
    }

    // Invalid option value
    {
        const args = [_][]const u8{ "--count", "not_a_number" };
        try std.testing.expectError(OptionParseError.InvalidOptionValue, parseOptions(TestOptions, allocator, &args));
    }

    // Boolean option with value
    {
        const BoolOptions = struct {
            verbose: bool = false,
        };
        const args = [_][]const u8{"--verbose=true"};
        try std.testing.expectError(OptionParseError.InvalidOptionValue, parseOptions(BoolOptions, allocator, &args));
    }
}

test "parseOptions bundled short options" {
    const TestOptions = struct {
        verbose: bool = false,
        quiet: bool = false,
        force: bool = false,
        all: bool = false,
    };

    const allocator = std.testing.allocator;

    // Test various bundled combinations
    {
        const args = [_][]const u8{"-vqf"};
        const parsed = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(parsed.options.verbose);
        try std.testing.expect(parsed.options.quiet);
        try std.testing.expect(parsed.options.force);
        try std.testing.expect(!parsed.options.all);
    }

    {
        const args = [_][]const u8{"-afvq"};
        const parsed = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(parsed.options.all);
        try std.testing.expect(parsed.options.force);
        try std.testing.expect(parsed.options.verbose);
        try std.testing.expect(parsed.options.quiet);
    }
}

test "parseOptions integer types" {
    const TestOptions = struct {
        port: u16 = 8080,
        timeout: i32 = 30,
        size: u64 = 1024,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--port", "9000", "--timeout", "-5", "--size", "1048576" };
    const parsed = try parseOptions(TestOptions, allocator, &args);

    try std.testing.expectEqual(@as(u16, 9000), parsed.options.port);
    try std.testing.expectEqual(@as(i32, -5), parsed.options.timeout);
    try std.testing.expectEqual(@as(u64, 1048576), parsed.options.size);
}

test "parseOptions float types" {
    const TestOptions = struct {
        ratio: f32 = 1.0,
        threshold: f64 = 0.5,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--ratio", "3.14159", "--threshold", "0.001" };
    const parsed = try parseOptions(TestOptions, allocator, &args);

    try std.testing.expectApproxEqAbs(@as(f32, 3.14159), parsed.options.ratio, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001), parsed.options.threshold, 0.000001);
}

test "parseOptions repeated options" {
    const TestOptions = struct {
        verbose: bool,
        level: i32,
    };

    const allocator = std.testing.allocator;

    // Test repeated boolean flag
    {
        const args = [_][]const u8{ "--verbose", "--verbose" };
        _ = try parseOptions(TestOptions, allocator, &args);
        // Should not error - just sets to true
    }

    // Test repeated value option
    {
        const args = [_][]const u8{ "--level", "1", "--level", "2" };
        const result = try parseOptions(TestOptions, allocator, &args);
        // Should use the last value
        try std.testing.expectEqual(@as(i32, 2), result.options.level);
    }
}

test "parseOptions option at end without value" {
    const TestOptions = struct {
        name: []const u8,
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{"--name"};

    try std.testing.expectError(OptionParseError.MissingOptionValue, parseOptions(TestOptions, allocator, &args));
}

test "parseOptions all integer types" {
    const TestOptions = struct {
        i8_val: i8,
        i16_val: i16,
        i32_val: i32,
        i64_val: i64,
        u8_val: u8,
        u16_val: u16,
        u32_val: u32,
        u64_val: u64,
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{
        "--i8-val",  "-128",
        "--i16-val", "32767",
        "--i32-val", "-2147483648",
        "--i64-val", "9223372036854775807",
        "--u8-val",  "255",
        "--u16-val", "65535",
        "--u32-val", "4294967295",
        "--u64-val", "18446744073709551615",
    };

    const result = try parseOptions(TestOptions, allocator, &args);
    try std.testing.expectEqual(@as(i8, -128), result.options.i8_val);
    try std.testing.expectEqual(@as(i16, 32767), result.options.i16_val);
    try std.testing.expectEqual(@as(i32, -2147483648), result.options.i32_val);
    try std.testing.expectEqual(@as(i64, 9223372036854775807), result.options.i64_val);
    try std.testing.expectEqual(@as(u8, 255), result.options.u8_val);
    try std.testing.expectEqual(@as(u16, 65535), result.options.u16_val);
    try std.testing.expectEqual(@as(u32, 4294967295), result.options.u32_val);
    try std.testing.expectEqual(@as(u64, 18446744073709551615), result.options.u64_val);
}

test "parseOptions multiple boolean flags combined" {
    const TestOptions = struct {
        verbose: bool,
        debug: bool,
        quiet: bool,
        force: bool,
    };

    const allocator = std.testing.allocator;

    // Test various combinations
    {
        const args = [_][]const u8{ "-v", "-d", "-q", "-f" };
        const result = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expectEqual(true, result.options.verbose);
        try std.testing.expectEqual(true, result.options.debug);
        try std.testing.expectEqual(true, result.options.quiet);
        try std.testing.expectEqual(true, result.options.force);
    }

    // Test partial flags
    {
        const args = [_][]const u8{ "-v", "-f" };
        const result = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expectEqual(true, result.options.verbose);
        try std.testing.expectEqual(false, result.options.debug);
        try std.testing.expectEqual(false, result.options.quiet);
        try std.testing.expectEqual(true, result.options.force);
    }
}

test "parseOptions special characters in values" {
    const TestOptions = struct {
        path: []const u8,
        pattern: []const u8,
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--path", "/home/user/my-files/test file.txt", "--pattern", "^[a-z]+@example\\.com$" };

    const result = try parseOptions(TestOptions, allocator, &args);
    try std.testing.expectEqualStrings("/home/user/my-files/test file.txt", result.options.path);
    try std.testing.expectEqualStrings("^[a-z]+@example\\.com$", result.options.pattern);
}

test "parseOptions empty string values" {
    const TestOptions = struct {
        message: []const u8,
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--message", "" };

    const result = try parseOptions(TestOptions, allocator, &args);
    try std.testing.expectEqualStrings("", result.options.message);
}

test "parseOptions equals syntax variations" {
    const TestOptions = struct {
        key: []const u8,
        value: i32,
    };

    const allocator = std.testing.allocator;

    // Test with spaces around equals
    {
        const args = [_][]const u8{ "--key=test", "--value=42" };
        const result = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expectEqualStrings("test", result.options.key);
        try std.testing.expectEqual(@as(i32, 42), result.options.value);
    }

    // Test equals with empty value
    {
        const args = [_][]const u8{ "--key=", "--value=0" };
        const result = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expectEqualStrings("", result.options.key);
        try std.testing.expectEqual(@as(i32, 0), result.options.value);
    }
}

test "parseOptions numeric edge cases" {
    const TestOptions = struct {
        int_val: i32,
        float_val: f64,
    };

    const allocator = std.testing.allocator;

    // Test scientific notation
    {
        const args = [_][]const u8{ "--float-val", "1.23e-4", "--int-val", "42" };
        const result = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expectApproxEqAbs(@as(f64, 0.000123), result.options.float_val, 0.000001);
    }

    // Test hex integers
    {
        const args = [_][]const u8{ "--int-val", "0xFF", "--float-val", "1.0" };
        const result = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expectEqual(@as(i32, 255), result.options.int_val);
    }

    // Test binary integers
    {
        const args = [_][]const u8{ "--int-val", "0b1010", "--float-val", "1.0" };
        const result = try parseOptions(TestOptions, allocator, &args);
        try std.testing.expectEqual(@as(i32, 10), result.options.int_val);
    }
}

test "parseOptions field name conversion edge cases" {
    const TestOptions = struct {
        my_long_option_name: bool,
        @"with-dashes": bool,
        camelCase: bool,
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--my-long-option-name", "--with-dashes", "--camelCase" };

    const result = try parseOptions(TestOptions, allocator, &args);
    try std.testing.expectEqual(true, result.options.my_long_option_name);
    try std.testing.expectEqual(true, result.options.@"with-dashes");
    try std.testing.expectEqual(true, result.options.camelCase);
}

test "parseOptions array accumulation" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
        single: []const u8 = "default",
    };

    const allocator = std.testing.allocator;

    // Test repeated array options
    {
        const args = [_][]const u8{ "--files", "file1.txt", "--files", "file2.txt", "--files", "file3.txt" };
        const parsed = try parseOptions(TestOptions, allocator, &args);
        defer allocator.free(parsed.options.files);

        try std.testing.expectEqual(@as(usize, 3), parsed.options.files.len);
        try std.testing.expectEqualStrings("file1.txt", parsed.options.files[0]);
        try std.testing.expectEqualStrings("file2.txt", parsed.options.files[1]);
        try std.testing.expectEqualStrings("file3.txt", parsed.options.files[2]);
    }

    // Test single array option (should become array of one)
    {
        const args = [_][]const u8{ "--files", "single.txt" };
        const parsed = try parseOptions(TestOptions, allocator, &args);
        defer allocator.free(parsed.options.files);

        try std.testing.expectEqual(@as(usize, 1), parsed.options.files.len);
        try std.testing.expectEqualStrings("single.txt", parsed.options.files[0]);
    }

    // Test numeric array accumulation
    {
        const args = [_][]const u8{ "--numbers", "1", "--numbers", "42", "--numbers", "-5" };
        const parsed = try parseOptions(TestOptions, allocator, &args);
        defer allocator.free(parsed.options.numbers);

        try std.testing.expectEqual(@as(usize, 3), parsed.options.numbers.len);
        try std.testing.expectEqual(@as(i32, 1), parsed.options.numbers[0]);
        try std.testing.expectEqual(@as(i32, 42), parsed.options.numbers[1]);
        try std.testing.expectEqual(@as(i32, -5), parsed.options.numbers[2]);
    }

    // Test mixing array and non-array options
    {
        const args = [_][]const u8{ "--single", "test", "--files", "a.txt", "--files", "b.txt" };
        const parsed = try parseOptions(TestOptions, allocator, &args);
        defer allocator.free(parsed.options.files);

        try std.testing.expectEqualStrings("test", parsed.options.single);
        try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
        try std.testing.expectEqualStrings("a.txt", parsed.options.files[0]);
        try std.testing.expectEqualStrings("b.txt", parsed.options.files[1]);
    }
}

test "parseOptions array accumulation with short flags" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
    };

    const allocator = std.testing.allocator;

    // Test short flags with arrays
    {
        const args = [_][]const u8{ "-f", "file1.txt", "-f", "file2.txt", "-n", "1", "-n", "2" };
        const parsed = try parseOptions(TestOptions, allocator, &args);
        defer allocator.free(parsed.options.files);
        defer allocator.free(parsed.options.numbers);

        try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
        try std.testing.expectEqualStrings("file1.txt", parsed.options.files[0]);
        try std.testing.expectEqualStrings("file2.txt", parsed.options.files[1]);

        try std.testing.expectEqual(@as(usize, 2), parsed.options.numbers.len);
        try std.testing.expectEqual(@as(i32, 1), parsed.options.numbers[0]);
        try std.testing.expectEqual(@as(i32, 2), parsed.options.numbers[1]);
    }

    // Test short flags with attached values
    {
        const args = [_][]const u8{ "-ffile1.txt", "-ffile2.txt" };
        const parsed = try parseOptions(TestOptions, allocator, &args);
        defer allocator.free(parsed.options.files);

        try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
        try std.testing.expectEqualStrings("file1.txt", parsed.options.files[0]);
        try std.testing.expectEqualStrings("file2.txt", parsed.options.files[1]);
    }
}

test "parseOptions empty arrays" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    // Test with no array options specified
    {
        const args = [_][]const u8{"--verbose"};
        const parsed = try parseOptions(TestOptions, allocator, &args);
        defer allocator.free(parsed.options.files);
        defer allocator.free(parsed.options.numbers);

        try std.testing.expectEqual(@as(usize, 0), parsed.options.files.len);
        try std.testing.expectEqual(@as(usize, 0), parsed.options.numbers.len);
        try std.testing.expectEqual(true, parsed.options.verbose);
    }
}

test "parseOptions positional args after options" {
    const TestOptions = struct {
        verbose: bool,
        output: []const u8,
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--verbose", "--output", "file.txt", "arg1", "arg2" };

    const result = try parseOptions(TestOptions, allocator, &args);
    try std.testing.expectEqual(true, result.options.verbose);
    try std.testing.expectEqualStrings("file.txt", result.options.output);
    try std.testing.expectEqual(@as(usize, 3), result.result.next_arg_index);
}

test "parseOptionsWithMeta basic custom name mapping" {
    const TestOptions = struct {
        files: [][]const u8,
        verbose: bool,
        output_file: []const u8,
    };

    const meta = .{
        .options = .{
            .files = .{ .name = "file" },
            .output_file = .{ .name = "output" },
        },
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--file", "file1.txt", "--file", "file2.txt", "--verbose", "--output", "result.txt" };

    const result = try parseOptionsWithMeta(TestOptions, meta, allocator, &args);
    defer {
        allocator.free(result.options.files);
    }

    try std.testing.expectEqual(@as(usize, 2), result.options.files.len);
    try std.testing.expectEqualStrings("file1.txt", result.options.files[0]);
    try std.testing.expectEqualStrings("file2.txt", result.options.files[1]);
    try std.testing.expectEqual(true, result.options.verbose);
    try std.testing.expectEqualStrings("result.txt", result.options.output_file);
}

test "parseOptionsWithMeta fallback to field names" {
    const TestOptions = struct {
        verbose: bool,
        output: []const u8,
        files: [][]const u8,
    };

    const meta = .{
        .options = .{
            .files = .{ .name = "file" },
            // verbose and output have no custom names, should use field names
        },
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--file", "test.txt", "--verbose", "--output", "out.txt" };

    const result = try parseOptionsWithMeta(TestOptions, meta, allocator, &args);
    defer {
        allocator.free(result.options.files);
    }

    try std.testing.expectEqual(@as(usize, 1), result.options.files.len);
    try std.testing.expectEqualStrings("test.txt", result.options.files[0]);
    try std.testing.expectEqual(true, result.options.verbose);
    try std.testing.expectEqualStrings("out.txt", result.options.output);
}

test "parseOptionsWithMeta custom name works when specified" {
    const TestOptions = struct {
        files: [][]const u8,
        verbose: bool,
    };

    const meta = .{
        .options = .{
            .files = .{ .name = "file" },
            // verbose has no custom name
        },
    };

    const allocator = std.testing.allocator;

    // Test custom name --file works
    {
        const args = [_][]const u8{ "--file", "test1.txt", "--file", "test2.txt", "--verbose" };
        const result = try parseOptionsWithMeta(TestOptions, meta, allocator, &args);
        defer allocator.free(result.options.files);

        try std.testing.expectEqual(@as(usize, 2), result.options.files.len);
        try std.testing.expectEqualStrings("test1.txt", result.options.files[0]);
        try std.testing.expectEqualStrings("test2.txt", result.options.files[1]);
        try std.testing.expectEqual(true, result.options.verbose);
    }

    // Test field without custom name still uses field name
    {
        const args = [_][]const u8{"--verbose"};
        const result = try parseOptionsWithMeta(TestOptions, meta, allocator, &args);
        try std.testing.expectEqual(true, result.options.verbose);
        try std.testing.expectEqual(@as(usize, 0), result.options.files.len);
    }
}

test "parseOptionsWithMeta null metadata" {
    const TestOptions = struct {
        verbose: bool,
        output: []const u8,
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--verbose", "--output", "test.txt" };

    // Pass null metadata - should fall back to field names
    const result = try parseOptionsWithMeta(TestOptions, null, allocator, &args);

    try std.testing.expectEqual(true, result.options.verbose);
    try std.testing.expectEqualStrings("test.txt", result.options.output);
}

test "parseOptionsWithMeta empty metadata" {
    const TestOptions = struct {
        verbose: bool,
        count: i32,
    };

    const meta = .{}; // Empty metadata

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--verbose", "--count", "42" };

    const result = try parseOptionsWithMeta(TestOptions, meta, allocator, &args);

    try std.testing.expectEqual(true, result.options.verbose);
    try std.testing.expectEqual(@as(i32, 42), result.options.count);
}

test "parseOptionsWithMeta error cases" {
    const TestOptions = struct {
        files: [][]const u8,
        count: i32,
    };

    const meta = .{
        .options = .{
            .files = .{ .name = "file" },
        },
    };

    const allocator = std.testing.allocator;

    // Test unknown option
    {
        const args = [_][]const u8{ "--unknown", "value" };
        const result = parseOptionsWithMeta(TestOptions, meta, allocator, &args);
        try std.testing.expectError(OptionParseError.UnknownOption, result);
    }

    // Test missing value
    {
        const args = [_][]const u8{"--count"};
        const result = parseOptionsWithMeta(TestOptions, meta, allocator, &args);
        try std.testing.expectError(OptionParseError.MissingOptionValue, result);
    }

    // Test invalid value type
    {
        const args = [_][]const u8{ "--count", "not-a-number" };
        const result = parseOptionsWithMeta(TestOptions, meta, allocator, &args);
        try std.testing.expectError(OptionParseError.InvalidOptionValue, result);
    }
}

test "parseOptionsWithMeta complex metadata structure" {
    const TestOptions = struct {
        input_files: [][]const u8,
        output_directory: []const u8,
        max_threads: i32,
        enable_logging: bool,
        log_level: []const u8,
    };

    const meta = .{
        .description = "Complex command with custom option names",
        .options = .{
            .input_files = .{ .name = "input" },
            .output_directory = .{ .name = "output-dir" },
            .max_threads = .{ .name = "threads" },
            .enable_logging = .{ .name = "log" },
            // log_level uses field name (no custom name)
        },
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--input", "file1.txt", "--input", "file2.txt", "--output-dir", "/tmp/output", "--threads", "8", "--log", "--log-level", "debug" };

    const result = try parseOptionsWithMeta(TestOptions, meta, allocator, &args);
    defer allocator.free(result.options.input_files);

    try std.testing.expectEqual(@as(usize, 2), result.options.input_files.len);
    try std.testing.expectEqualStrings("file1.txt", result.options.input_files[0]);
    try std.testing.expectEqualStrings("file2.txt", result.options.input_files[1]);
    try std.testing.expectEqualStrings("/tmp/output", result.options.output_directory);
    try std.testing.expectEqual(@as(i32, 8), result.options.max_threads);
    try std.testing.expectEqual(true, result.options.enable_logging);
    try std.testing.expectEqualStrings("debug", result.options.log_level);
}

test "parseOptionsWithMeta short flags still work" {
    const TestOptions = struct {
        verbose: bool,
        files: [][]const u8,
        count: i32,
    };

    const meta = .{
        .options = .{
            .files = .{ .name = "file" },
        },
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "-v", "--file", "test.txt", "-c", "5" };

    const result = try parseOptionsWithMeta(TestOptions, meta, allocator, &args);
    defer allocator.free(result.options.files);

    try std.testing.expectEqual(true, result.options.verbose);
    try std.testing.expectEqual(@as(usize, 1), result.options.files.len);
    try std.testing.expectEqualStrings("test.txt", result.options.files[0]);
    try std.testing.expectEqual(@as(i32, 5), result.options.count);
}

test "parseOptionsWithMeta custom names are exclusive" {
    const TestOptions = struct {
        files: [][]const u8,
        verbose: bool,
    };

    const meta = .{
        .options = .{
            .files = .{ .name = "file" },
        },
    };

    const allocator = std.testing.allocator;

    // Test that custom name works
    {
        const args = [_][]const u8{ "--file", "test1.txt", "--verbose" };
        const result = try parseOptionsWithMeta(TestOptions, meta, allocator, &args);
        defer allocator.free(result.options.files);

        try std.testing.expectEqual(@as(usize, 1), result.options.files.len);
        try std.testing.expectEqualStrings("test1.txt", result.options.files[0]);
        try std.testing.expectEqual(true, result.options.verbose);
    }

    // Test that original field name does NOT work when custom name is specified
    {
        const args = [_][]const u8{ "--files", "test2.txt" };
        const result = parseOptionsWithMeta(TestOptions, meta, allocator, &args);
        try std.testing.expectError(OptionParseError.UnknownOption, result);
    }

    // Test that field without custom name still uses original name
    {
        const args = [_][]const u8{"--verbose"};
        const result = try parseOptionsWithMeta(TestOptions, meta, allocator, &args);
        try std.testing.expectEqual(true, result.options.verbose);
        try std.testing.expectEqual(@as(usize, 0), result.options.files.len);
    }
}

test "cleanupOptions helper function" {
    const TestOptions = struct {
        files: [][]const u8,
        counts: []i32,
        verbose: bool,
        name: ?[]const u8,
    };

    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "--files", "test1.txt", "--files", "test2.txt", "--counts", "5", "--counts", "10", "--verbose", "--name", "test" };

    const result = try parseOptions(TestOptions, allocator, &args);

    // Test that arrays were populated correctly
    try std.testing.expectEqual(@as(usize, 2), result.options.files.len);
    try std.testing.expectEqual(@as(usize, 2), result.options.counts.len);

    // Use cleanup helper instead of manual cleanup
    defer cleanupOptions(TestOptions, result.options, allocator);

    // Verify values are correct
    try std.testing.expectEqualStrings("test1.txt", result.options.files[0]);
    try std.testing.expectEqualStrings("test2.txt", result.options.files[1]);
    try std.testing.expectEqual(@as(i32, 5), result.options.counts[0]);
    try std.testing.expectEqual(@as(i32, 10), result.options.counts[1]);
    try std.testing.expectEqual(true, result.options.verbose);
    try std.testing.expectEqualStrings("test", result.options.name.?);
}

/// Cleanup helper function for array fields in options
///
/// This function automatically frees all array fields in an options struct.
/// Use this when manually parsing options (not through the zcli framework).
///
/// Example:
/// ```zig
/// const parsed = try parseOptions(Options, allocator, args);
/// defer cleanupOptions(Options, parsed.options, allocator);
/// ```
pub fn cleanupOptions(comptime OptionsType: type, options: OptionsType, allocator: std.mem.Allocator) void {
    const type_info = @typeInfo(OptionsType);
    if (type_info != .@"struct") return;

    inline for (type_info.@"struct".fields) |field| {
        const field_value = @field(options, field.name);
        const field_type_info = @typeInfo(field.type);

        // Check if this is a slice type (array)
        if (field_type_info == .pointer and
            field_type_info.pointer.size == .slice)
        {
            // Free the slice itself - works for all array types
            allocator.free(field_value);
        }
    }
}
