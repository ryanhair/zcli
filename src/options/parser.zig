const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");
const array_utils = @import("array_utils.zig");

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
) types.OptionParseError!types.OptionsResult(OptionsType) {
    return parseOptionsWithMeta(OptionsType, null, allocator, args);
}

pub fn parseOptionsWithMeta(
    comptime OptionsType: type,
    comptime meta: anytype,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) types.OptionParseError!types.OptionsResult(OptionsType) {
    const type_info = @typeInfo(OptionsType);

    if (type_info != .@"struct") {
        @compileError("Options must be a struct type");
    }

    const struct_info = type_info.@"struct";
    var result: OptionsType = undefined;

    // Track array accumulation for each field
    var array_lists: [struct_info.fields.len]?array_utils.ArrayListUnion = undefined;
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

        if (comptime utils.isArrayType(field.type)) {
            // Initialize array fields with empty arrays of the correct type
            const element_type = @typeInfo(field.type).pointer.child;
            @field(result, field.name) = @as(field.type, &[_]element_type{});
            // Create ArrayList for accumulation based on element type
            array_lists[i] = array_utils.createArrayListUnion(element_type, allocator);
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
        if (utils.isNegativeNumber(arg)) {
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
        if (comptime utils.isArrayType(field.type)) {
            if (array_lists[i]) |*list_union| {
                @field(result, field.name) = try array_utils.arrayListUnionToOwnedSlice(field.type, list_union);
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
) types.OptionParseError!usize {
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
    const option_field_name = utils.dashesToUnderscores(option_field_name_buf[0..], option_name) catch |err| {
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
            if (comptime utils.isBooleanType(field.type)) {
                if (option_value != null) {
                    std.log.err("Boolean option --{s} does not take a value", .{option_name});
                    return types.OptionParseError.InvalidOptionValue;
                }
                @field(result, field.name) = true;
                return 1;
            }

            // Get the value
            const value = blk: {
                if (option_value) |val| {
                    break :blk val;
                } else if (arg_index + 1 < args.len and (!std.mem.startsWith(u8, args[arg_index + 1], "-") or utils.isNegativeNumber(args[arg_index + 1]))) {
                    break :blk args[arg_index + 1];
                } else {
                    std.log.err("Option --{s} requires a value", .{option_name});
                    return types.OptionParseError.MissingOptionValue;
                }
            };

            // Parse and set the value based on field type
            if (comptime utils.isArrayType(field.type)) {
                // Handle array accumulation
                const element_type = @typeInfo(field.type).pointer.child;
                if (array_lists[i]) |*list_union| {
                    try array_utils.appendToArrayListUnion(element_type, list_union, value, option_name);
                }
            } else {
                // Handle single values
                const parsed_value = utils.parseOptionValue(field.type, value) catch |err| {
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
        return types.OptionParseError.UnknownOption;
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
) types.OptionParseError!usize {
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
) types.OptionParseError!usize {
    _ = allocator; // Currently unused
    const arg = args[arg_index];
    const options_part = arg[1..]; // Skip "-"

    if (options_part.len == 0) {
        std.log.err("Invalid option: -", .{});
        return types.OptionParseError.UnknownOption;
    }

    // Try to parse as bundled boolean flags first
    var all_boolean = true;
    for (options_part) |char| {
        var char_field_found = false;
        var char_is_boolean = false;
        inline for (@typeInfo(OptionsType).@"struct".fields) |field| {
            if (field.name.len > 0 and field.name[0] == char) {
                char_field_found = true;
                char_is_boolean = comptime utils.isBooleanType(field.type);
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
                    if (comptime utils.isBooleanType(field.type)) {
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

                if (comptime utils.isBooleanType(field.type)) {
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
                            return types.OptionParseError.MissingOptionValue;
                        }
                        value = args[arg_index + 1];
                        consumed = 2;
                    }

                    if (comptime utils.isArrayType(field.type)) {
                        // For array types, accumulate values
                        if (array_lists.*[i]) |*list_union| {
                            const element_type = @typeInfo(field.type).pointer.child;
                            try array_utils.appendToArrayListUnionShort(element_type, list_union, value, char);
                        }
                    } else {
                        const parsed_value = utils.parseOptionValue(field.type, value) catch |err| {
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
            return types.OptionParseError.UnknownOption;
        }

        return 0; // Should never reach here
    }
}

/// Helper function to clean up array fields in options
/// This function automatically frees memory allocated for array options (e.g., [][]const u8, []i32, etc.)
/// Individual string elements are not freed as they come from command-line args
///
/// ### Manual Usage Example:
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

        // Check if this is a slice type (array) but NOT a string
        if (field_type_info == .pointer and
            field_type_info.pointer.size == .slice)
        {
            // Only free arrays, not strings ([]const u8)
            if (field_type_info.pointer.child != u8) {
                // Free the slice itself - works for all array types:
                // [][]const u8, []i32, []u32, []f64, etc.
                // We don't free individual elements as they're either:
                // - Strings from args (not owned)
                // - Primitive values (no allocation)
                if (field_value.len > 0) {
                    allocator.free(field_value);
                }
            }
        }
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
        try std.testing.expectError(types.OptionParseError.UnknownOption, parseOptions(TestOptions, allocator, &args));
    }

    // Missing option value
    {
        const args = [_][]const u8{"--name"};
        try std.testing.expectError(types.OptionParseError.MissingOptionValue, parseOptions(TestOptions, allocator, &args));
    }

    // Invalid option value
    {
        const args = [_][]const u8{ "--count", "not_a_number" };
        try std.testing.expectError(types.OptionParseError.InvalidOptionValue, parseOptions(TestOptions, allocator, &args));
    }

    // Boolean option with value
    {
        const BoolOptions = struct {
            verbose: bool = false,
        };
        const args = [_][]const u8{"--verbose=true"};
        try std.testing.expectError(types.OptionParseError.InvalidOptionValue, parseOptions(BoolOptions, allocator, &args));
    }
}

test "parseOptions array accumulation" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--files", "a.txt", "--files", "b.txt", "--numbers", "1", "--numbers", "2", "--verbose" };
    const parsed = try parseOptions(TestOptions, allocator, &args);
    defer cleanupOptions(TestOptions, parsed.options, allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
    try std.testing.expectEqualStrings("a.txt", parsed.options.files[0]);
    try std.testing.expectEqualStrings("b.txt", parsed.options.files[1]);

    try std.testing.expectEqual(@as(usize, 2), parsed.options.numbers.len);
    try std.testing.expectEqual(@as(i32, 1), parsed.options.numbers[0]);
    try std.testing.expectEqual(@as(i32, 2), parsed.options.numbers[1]);

    try std.testing.expect(parsed.options.verbose);
}

test "parseOptions array accumulation with short flags" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "-f", "first.txt", "-f", "second.txt", "-n", "10", "-n", "20" };
    const parsed = try parseOptions(TestOptions, allocator, &args);
    defer cleanupOptions(TestOptions, parsed.options, allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
    try std.testing.expectEqualStrings("first.txt", parsed.options.files[0]);
    try std.testing.expectEqualStrings("second.txt", parsed.options.files[1]);

    try std.testing.expectEqual(@as(usize, 2), parsed.options.numbers.len);
    try std.testing.expectEqual(@as(i32, 10), parsed.options.numbers[0]);
    try std.testing.expectEqual(@as(i32, 20), parsed.options.numbers[1]);
}

test "parseOptionsWithMeta custom name mapping" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        verbose: bool = false,
    };

    const meta = .{
        .options = .{
            .files = .{ .name = "file" },
        },
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--file", "test1.txt", "--file", "test2.txt", "--verbose" };
    const parsed = try parseOptionsWithMeta(TestOptions, meta, allocator, &args);
    defer cleanupOptions(TestOptions, parsed.options, allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
    try std.testing.expectEqualStrings("test1.txt", parsed.options.files[0]);
    try std.testing.expectEqualStrings("test2.txt", parsed.options.files[1]);
    try std.testing.expect(parsed.options.verbose);

    // Should fail with the field name when custom name is specified
    const fail_args = [_][]const u8{ "--files", "should_fail.txt" };
    try std.testing.expectError(types.OptionParseError.UnknownOption, parseOptionsWithMeta(TestOptions, meta, allocator, &fail_args));
}

test "parseOptionsWithMeta custom names are exclusive" {
    const TestOptions = struct {
        output_files: [][]const u8 = &.{},
    };

    // Custom name "file" should be exclusive - can't use both --file and --output-files
    const meta = .{
        .options = .{
            .output_files = .{ .name = "file" },
        },
    };

    const allocator = std.testing.allocator;

    // Should work with custom name
    {
        const args = [_][]const u8{ "--file", "test.txt" };
        const parsed = try parseOptionsWithMeta(TestOptions, meta, allocator, &args);
        defer cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expectEqual(@as(usize, 1), parsed.options.output_files.len);
        try std.testing.expectEqualStrings("test.txt", parsed.options.output_files[0]);
    }

    // Should fail with field name when custom name is provided
    {
        const args = [_][]const u8{ "--output-files", "test.txt" };
        try std.testing.expectError(types.OptionParseError.UnknownOption, parseOptionsWithMeta(TestOptions, meta, allocator, &args));
    }
}

test "cleanupOptions helper function" {
    const TestOptions = struct {
        files: [][]const u8 = &.{},
        counts: []i32 = &.{},
        name: []const u8 = "default",
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--files", "a.txt", "--files", "b.txt", "--counts", "1", "--counts", "2", "--name", "test" };
    const parsed = try parseOptions(TestOptions, allocator, &args);

    // Verify arrays were allocated
    try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.options.counts.len);

    // This should not fail or leak memory
    cleanupOptions(TestOptions, parsed.options, allocator);
}

test "parseOptions negative numbers" {
    const TestOptions = struct {
        value: i32 = 0,
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "--value", "-42", "--verbose" };
    const parsed = try parseOptions(TestOptions, allocator, &args);

    try std.testing.expectEqual(@as(i32, -42), parsed.options.value);
    try std.testing.expect(parsed.options.verbose);
}

test "parseOptions stops at negative number" {
    const TestOptions = struct {
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    // Should stop parsing at negative number
    const args = [_][]const u8{ "--verbose", "-123", "other", "args" };
    const parsed = try parseOptions(TestOptions, allocator, &args);

    try std.testing.expect(parsed.options.verbose);
    try std.testing.expectEqual(@as(usize, 1), parsed.result.next_arg_index);
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

    // Test mixed bundled and separate
    {
        const args = [_][]const u8{ "-vq", "-f", "-a" };
        const parsed = try parseOptions(TestOptions, allocator, &args);
        
        try std.testing.expect(parsed.options.verbose);
        try std.testing.expect(parsed.options.quiet);
        try std.testing.expect(parsed.options.force);
        try std.testing.expect(parsed.options.all);
    }
}