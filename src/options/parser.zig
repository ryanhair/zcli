const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");
const array_utils = @import("array_utils.zig");
const logging = @import("../logging.zig");
const args_parser = @import("../args.zig");
const StructuredError = @import("../structured_errors.zig").StructuredError;
const ErrorBuilder = @import("../structured_errors.zig").ErrorBuilder;

/// Result type for option parsing operations
pub fn OptionsParseResult(comptime OptionsType: type) type {
    return args_parser.ParseResult(types.OptionsResult(OptionsType));
}

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
/// Parse command-line options into a struct using default field names.
///
/// This function parses command-line flags and options (e.g., --verbose, --output file.txt)
/// into a struct. Option names are derived from struct field names by converting
/// underscores to dashes (e.g., `output_file` becomes `--output-file`).
///
/// ## Parameters
/// - `OptionsType`: Struct type defining expected options with default values
/// - `allocator`: Memory allocator for array options (must call cleanupOptions after use)
/// - `args`: Command-line arguments to parse
///
/// ## Returns
/// `OptionsResult(OptionsType)` containing parsed options and parsing metadata.
///
/// ## Supported Option Types
/// - Boolean flags: `bool` (--flag sets to true)
/// - String options: `[]const u8` (--name value)
/// - Numeric options: `i32`, `u32`, `f64`, etc. (--count 42)
/// - Array options: `[][]const u8`, `[]i32` (--files a.txt b.txt)
/// - Optional options: `?T` for any supported type T
///
/// ## Examples
/// ```zig
/// const Options = struct {
///     verbose: bool = false,        // --verbose
///     output_file: ?[]const u8 = null,  // --output-file path
///     count: u32 = 10,             // --count 42
///     files: [][]const u8 = &.{}, // --files a.txt b.txt
/// };
///
/// const result = try zcli.parseOptions(Options, allocator, args);
/// defer zcli.cleanupOptions(Options, result.options, allocator);
/// ```
///
/// ## Memory Management
/// **IMPORTANT**: Array options allocate memory. Always call `cleanupOptions` when done:
/// ```zig
/// const result = try parseOptions(Options, allocator, args);
/// defer cleanupOptions(Options, result.options, allocator);
/// ```
pub fn parseOptions(
    comptime OptionsType: type,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) OptionsParseResult(OptionsType) {
    return parseOptionsWithMeta(OptionsType, null, allocator, args);
}

/// Parse command-line options with custom metadata for option names and descriptions.
///
/// This function is like `parseOptions` but allows customizing option names and behavior
/// through metadata. This is typically used internally by the zcli framework when
/// commands define custom option metadata.
///
/// ## Parameters
/// - `OptionsType`: Struct type defining expected options
/// - `meta`: Optional metadata struct with custom option configurations
/// - `allocator`: Memory allocator for array options
/// - `args`: Command-line arguments to parse
///
/// ## Metadata Format
/// The meta parameter can contain option-specific configurations:
/// ```zig
/// const meta = .{
///     .options = .{
///         .output_file = .{ .name = "out", .short = 'o' },
///         .verbose = .{ .short = 'v' },
///     },
/// };
/// ```
///
/// ## Examples
/// ```zig
/// const Options = struct { output_file: ?[]const u8 = null };
/// const meta = .{ .options = .{ .output_file = .{ .name = "out" } } };
///
/// const result = try parseOptionsWithMeta(Options, meta, allocator, args);
/// // Now accepts --out instead of --output-file
/// defer cleanupOptions(Options, result.options, allocator);
/// ```
///
/// ## Usage
/// Most users should use `parseOptions` instead. This function is primarily for
/// internal framework use and advanced customization scenarios.
pub fn parseOptionsWithMeta(
    comptime OptionsType: type,
    comptime meta: anytype,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) OptionsParseResult(OptionsType) {
    const type_info = @typeInfo(OptionsType);

    if (type_info != .@"struct") {
        @compileError("Options must be a struct type");
    }

    const struct_info = type_info.@"struct";
    var result: OptionsType = undefined;

    // Track array accumulation for each field
    var array_lists: [struct_info.fields.len]?array_utils.ArrayListUnion = [_]?array_utils.ArrayListUnion{null} ** struct_info.fields.len;
    defer {
        for (&array_lists) |*list| {
            if (list.*) |*l| {
                l.deinit();
            }
        }
    }

    // Initialize with default values
    inline for (struct_info.fields, 0..) |field, i| {
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

    // Parse options, converting any errors to structured errors
    const parsing_result = blk: {
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

            // Not an option, skip to next argument (GNU-style parsing)
            if (!std.mem.startsWith(u8, arg, "-")) {
                arg_index += 1;
                continue;
            }

            // Check if this is a negative number - if so, skip it (GNU-style parsing)
            if (utils.isNegativeNumber(arg)) {
                arg_index += 1;
                continue;
            }

            if (std.mem.startsWith(u8, arg, "--")) {
                // Long option
                const consumed = parseLongOptions(OptionsType, meta, &result, &option_counts, args, arg_index, &array_lists, allocator) catch |err| {
                    // Convert error to structured error with context
                    const option_name = if (std.mem.indexOf(u8, arg[2..], "=")) |eq_pos|
                        arg[2 .. 2 + eq_pos]
                    else
                        arg[2..];
                    const option_value = if (std.mem.indexOf(u8, arg[2..], "=")) |eq_pos|
                        arg[2 + eq_pos + 1 ..]
                    else if (arg_index + 1 < args.len) args[arg_index + 1] else null;

                    break :blk args_parser.ParseResult(types.OptionsResult(OptionsType)){ .err = convertLongOptionError(err, option_name, option_value) };
                };
                arg_index += consumed;
            } else {
                // Short option(s)
                const consumed = parseShortOptionsWithMeta(OptionsType, meta, &result, &option_counts, args, arg_index, &array_lists, allocator) catch |err| {
                    // Convert error to structured error with context
                    const option_char = if (arg.len > 1) arg[1] else 0;
                    const option_name = if (arg.len > 1) arg[1..2] else "";
                    const option_value = if (arg.len > 2) arg[2..] else if (arg_index + 1 < args.len) args[arg_index + 1] else null;

                    break :blk args_parser.ParseResult(types.OptionsResult(OptionsType)){ .err = convertShortOptionError(err, option_char, option_name, option_value) };
                };
                arg_index += consumed;
            }
        }

        // Finalize array fields by converting ArrayLists to slices
        inline for (struct_info.fields, 0..) |field, i| {
            if (comptime utils.isArrayType(field.type)) {
                if (array_lists[i]) |*list_union| {
                    @field(result, field.name) = array_utils.arrayListUnionToOwnedSlice(field.type, list_union) catch {
                        break :blk args_parser.ParseResult(types.OptionsResult(OptionsType)){ .err = StructuredError{ .system_out_of_memory = {} } };
                    };
                }
            }
        }

        break :blk args_parser.ParseResult(types.OptionsResult(OptionsType)){ .ok = .{
            .options = result,
            .result = .{ .next_arg_index = arg_index },
        } };
    };

    return parsing_result;
}

/// Convert long option parsing errors to structured errors
fn convertLongOptionError(err: anyerror, option_name: []const u8, option_value: ?[]const u8) StructuredError {
    return switch (err) {
        error.UnknownOption => ErrorBuilder.unknownOption(option_name, false),
        error.MissingOptionValue => StructuredError{ .option_missing_value = .{
            .option_name = option_name,
            .is_short = false,
            .provided_value = null,
            .expected_type = "value",
        } },
        error.InvalidOptionValue => StructuredError{ .option_invalid_value = .{
            .option_name = option_name,
            .is_short = false,
            .provided_value = option_value,
            .expected_type = "valid value",
        } },
        error.OutOfMemory => StructuredError{ .system_out_of_memory = {} },
        else => StructuredError{ .option_invalid_value = .{
            .option_name = option_name,
            .is_short = false,
            .provided_value = option_value,
            .expected_type = "valid value",
        } },
    };
}

/// Convert short option parsing errors to structured errors
fn convertShortOptionError(err: anyerror, option_char: u8, option_name: []const u8, option_value: ?[]const u8) StructuredError {
    _ = option_char; // Unused parameter
    return switch (err) {
        error.UnknownOption => ErrorBuilder.unknownOption(option_name, true),
        error.MissingOptionValue => StructuredError{ .option_missing_value = .{
            .option_name = option_name,
            .is_short = true,
            .provided_value = null,
            .expected_type = "value",
        } },
        error.InvalidOptionValue => StructuredError{ .option_invalid_value = .{
            .option_name = option_name,
            .is_short = true,
            .provided_value = option_value,
            .expected_type = "valid value",
        } },
        error.OutOfMemory => StructuredError{ .system_out_of_memory = {} },
        else => StructuredError{ .option_invalid_value = .{
            .option_name = option_name,
            .is_short = true,
            .provided_value = option_value,
            .expected_type = "valid value",
        } },
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
) !usize {
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
    const option_field_name_buf = try allocator.alloc(u8, option_name.len);
    defer allocator.free(option_field_name_buf);
    const option_field_name = utils.dashesToUnderscores(option_field_name_buf, option_name) catch |err| {
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
                    logging.booleanOptionWithValue(option_name);
                    return error.InvalidOptionValue;
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
                    logging.missingOptionValue(option_name);
                    return error.MissingOptionValue;
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
        return error.UnknownOption;
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
) !usize {
    _ = allocator; // Currently unused
    const arg = args[arg_index];
    const options_part = arg[1..]; // Skip "-"

    if (options_part.len == 0) {
        return error.UnknownOption;
    }

    // Try to parse as bundled boolean flags first
    var all_boolean = true;
    for (options_part) |char| {
        var char_field_found = false;
        var char_is_boolean = false;
        inline for (@typeInfo(OptionsType).@"struct".fields) |field| {
            // Get the expected short option character for this field (comptime)
            const expected_char = comptime blk: {
                if (@TypeOf(meta) != @TypeOf(null) and @hasField(@TypeOf(meta), "options")) {
                    const options_meta = meta.options;
                    if (@hasField(@TypeOf(options_meta), field.name)) {
                        const field_meta = @field(options_meta, field.name);
                        if (@TypeOf(field_meta) != []const u8 and @hasField(@TypeOf(field_meta), "short")) {
                            // Custom short option is specified
                            break :blk field_meta.short;
                        }
                    }
                }
                // Fall back to first character of field name
                break :blk if (field.name.len > 0) field.name[0] else 0;
            };

            const matches = expected_char == char;

            if (matches) {
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
                // Get the expected short option character for this field (comptime)
                const expected_char = comptime blk: {
                    if (@TypeOf(meta) != @TypeOf(null) and @hasField(@TypeOf(meta), "options")) {
                        const options_meta = meta.options;
                        if (@hasField(@TypeOf(options_meta), field.name)) {
                            const field_meta = @field(options_meta, field.name);
                            if (@TypeOf(field_meta) != []const u8 and @hasField(@TypeOf(field_meta), "short")) {
                                // Custom short option is specified
                                break :blk field_meta.short;
                            }
                        }
                    }
                    // Fall back to first character of field name
                    break :blk if (field.name.len > 0) field.name[0] else 0;
                };

                const matches = expected_char == char;

                if (matches) {
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
            // Get the expected short option character for this field (comptime)
            const expected_char = comptime blk: {
                if (@TypeOf(meta) != @TypeOf(null) and @hasField(@TypeOf(meta), "options")) {
                    const options_meta = meta.options;
                    if (@hasField(@TypeOf(options_meta), field.name)) {
                        const field_meta = @field(options_meta, field.name);
                        if (@TypeOf(field_meta) != []const u8 and @hasField(@TypeOf(field_meta), "short")) {
                            // Custom short option is specified
                            break :blk field_meta.short;
                        }
                    }
                }
                // Fall back to first character of field name
                break :blk if (field.name.len > 0) field.name[0] else 0;
            };

            const matches = expected_char == char;

            if (matches) {
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
                            logging.missingOptionValue(&[_]u8{char});
                            return error.MissingOptionValue;
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
                            // This error will be logged by the parsing utility, no need to duplicate
                            return err;
                        };
                        @field(result, field.name) = parsed_value;
                    }

                    return consumed;
                }
            }
        }

        if (!char_found) {
            return error.UnknownOption;
        }

        return 1;
    }
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
) !usize {
    _ = allocator; // Currently unused
    const arg = args[arg_index];
    const options_part = arg[1..]; // Skip "-"

    if (options_part.len == 0) {
        return error.UnknownOption;
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
                            logging.missingOptionValue(&[_]u8{char});
                            return error.MissingOptionValue;
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
                            // This error will be logged by the parsing utility, no need to duplicate
                            return err;
                        };
                        @field(result, field.name) = parsed_value;
                    }
                    return consumed;
                }
            }
        }

        if (!char_found) {
            return error.UnknownOption;
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
/// Clean up memory allocated for array options by parseOptions/parseOptionsWithMeta.
///
/// This function frees memory allocated for array fields in option structs. It should
/// be called after parsing options when the parsed struct is no longer needed.
/// Individual strings within arrays are not freed as they reference command-line arguments.
///
/// ## Parameters
/// - `OptionsType`: The same struct type used for parsing
/// - `options`: The parsed options struct returned from parseOptions
/// - `allocator`: The same allocator used for parsing
///
/// ## Memory Safety
/// - Only frees array slices (e.g., `[]i32`, `[][]const u8`), not individual elements
/// - String fields (`[]const u8`) are never freed as they reference args
/// - Individual string elements in string arrays are not freed
/// - Safe to call on structs without array fields
///
/// ## Examples
/// ```zig
/// const result = try zcli.parseOptions(Options, allocator, args);
/// defer zcli.cleanupOptions(Options, result.options, allocator);
///
/// // Use result.options safely here
/// for (result.options.files) |file| {
///     std.debug.print("File: {s}\n", .{file});
/// }
/// // Cleanup happens automatically via defer
/// ```
///
/// ## Framework Usage
/// When using commands through the zcli framework, cleanup is automatic.
/// Manual cleanup is only needed when calling parsing functions directly.
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
        const result = parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(result == .ok);
        const parsed = result.ok;
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
        const result = parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(result == .ok);
        const parsed = result.ok;
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
    const result = parseOptions(TestOptions, allocator, &args);
    try std.testing.expect(result == .ok);
    const parsed = result.ok;

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
        const result = parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();
        try std.testing.expectEqualStrings("test", parsed.options.name);
        try std.testing.expectEqual(@as(u16, 9000), parsed.options.port);
    }

    // Test without space
    {
        const args = [_][]const u8{ "-ntest2", "-p9001" };
        const result = parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();
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
    const result = parseOptions(TestOptions, allocator, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

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
    const result = parseOptions(TestOptions, allocator, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

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
        const result = parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();

        try std.testing.expectEqualStrings("app.conf", parsed.options.config.?);
        try std.testing.expectEqual(@as(u16, 8080), parsed.options.port.?);
    }

    // Test with defaults
    {
        const args = [_][]const u8{};
        const result = parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();

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
    const result = parseOptions(TestOptions, allocator, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

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
        const result = parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(result.isError());
        const err = result.getError().?;
        switch (err) {
            .option_unknown => |ctx| {
                try std.testing.expectEqualStrings("unknown", ctx.option_name);
                try std.testing.expectEqual(false, ctx.is_short);
            },
            else => try std.testing.expect(false),
        }
    }

    // Missing option value
    {
        const args = [_][]const u8{"--name"};
        const result = parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(result.isError());
        const err = result.getError().?;
        switch (err) {
            .option_missing_value => |ctx| {
                try std.testing.expectEqualStrings("name", ctx.option_name);
                try std.testing.expectEqual(false, ctx.is_short);
            },
            else => try std.testing.expect(false),
        }
    }

    // Invalid option value
    {
        const args = [_][]const u8{ "--count", "not_a_number" };
        const result = parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(result.isError());
        const err = result.getError().?;
        switch (err) {
            .option_invalid_value => |ctx| {
                try std.testing.expectEqualStrings("count", ctx.option_name);
                try std.testing.expectEqual(false, ctx.is_short);
                try std.testing.expectEqualStrings("not_a_number", ctx.provided_value.?);
            },
            else => try std.testing.expect(false),
        }
    }

    // Boolean option with value
    {
        const BoolOptions = struct {
            verbose: bool = false,
        };
        const args = [_][]const u8{"--verbose=true"};
        const result = parseOptions(BoolOptions, allocator, &args);
        try std.testing.expect(result.isError());
        const err = result.getError().?;
        switch (err) {
            .option_invalid_value => |ctx| {
                // Currently boolean options with =value are treated as invalid value
                // rather than boolean_with_value. This is acceptable behavior.
                try std.testing.expectEqualStrings("verbose", ctx.option_name);
                try std.testing.expectEqual(false, ctx.is_short);
                try std.testing.expectEqualStrings("true", ctx.provided_value.?);
            },
            else => try std.testing.expect(false),
        }
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
    const result = parseOptions(TestOptions, allocator, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();
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
    const result = parseOptions(TestOptions, allocator, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();
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
    const result = parseOptionsWithMeta(TestOptions, meta, allocator, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();
    defer cleanupOptions(TestOptions, parsed.options, allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.options.files.len);
    try std.testing.expectEqualStrings("test1.txt", parsed.options.files[0]);
    try std.testing.expectEqualStrings("test2.txt", parsed.options.files[1]);
    try std.testing.expect(parsed.options.verbose);

    // Should fail with the field name when custom name is specified
    const fail_args = [_][]const u8{ "--files", "should_fail.txt" };
    const fail_result = parseOptionsWithMeta(TestOptions, meta, allocator, &fail_args);
    try std.testing.expect(fail_result == .err);
    switch (fail_result.err) {
        .option_unknown => |ctx| {
            try std.testing.expectEqualStrings("files", ctx.option_name);
        },
        else => try std.testing.expect(false),
    }
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
        const result = parseOptionsWithMeta(TestOptions, meta, allocator, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();
        defer cleanupOptions(TestOptions, parsed.options, allocator);

        try std.testing.expectEqual(@as(usize, 1), parsed.options.output_files.len);
        try std.testing.expectEqualStrings("test.txt", parsed.options.output_files[0]);
    }

    // Should fail with field name when custom name is provided
    {
        const args = [_][]const u8{ "--output-files", "test.txt" };
        const result = parseOptionsWithMeta(TestOptions, meta, allocator, &args);
        try std.testing.expect(result == .err);
        switch (result.err) {
            .option_unknown => |ctx| {
                try std.testing.expectEqualStrings("output-files", ctx.option_name);
            },
            else => try std.testing.expect(false),
        }
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
    const result = parseOptions(TestOptions, allocator, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

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
    const result = parseOptions(TestOptions, allocator, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

    try std.testing.expectEqual(@as(i32, -42), parsed.options.value);
    try std.testing.expect(parsed.options.verbose);
}

test "parseOptions continues through negative numbers (GNU-style)" {
    const TestOptions = struct {
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;

    // Should continue parsing through negative numbers in GNU-style
    const args = [_][]const u8{ "--verbose", "-123", "other", "args" };
    const result = parseOptions(TestOptions, allocator, &args);
    try std.testing.expect(!result.isError());
    const parsed = result.unwrap();

    try std.testing.expect(parsed.options.verbose);
    try std.testing.expectEqual(@as(usize, 4), parsed.result.next_arg_index);
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
        const result = parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();

        try std.testing.expect(parsed.options.verbose);
        try std.testing.expect(parsed.options.quiet);
        try std.testing.expect(parsed.options.force);
        try std.testing.expect(!parsed.options.all);
    }

    // Test mixed bundled and separate
    {
        const args = [_][]const u8{ "-vq", "-f", "-a" };
        const result = parseOptions(TestOptions, allocator, &args);
        try std.testing.expect(!result.isError());
        const parsed = result.unwrap();

        try std.testing.expect(parsed.options.verbose);
        try std.testing.expect(parsed.options.quiet);
        try std.testing.expect(parsed.options.force);
        try std.testing.expect(parsed.options.all);
    }
}

/// Result of parsing options while extracting positional arguments
pub fn ParseOptionsAndArgsResult(comptime OptionsType: type) type {
    return struct {
        options: OptionsType,
        remaining_args: []const []const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: @This()) void {
            self.allocator.free(self.remaining_args);
        }
    };
}

/// ParseResult wrapper for parseOptionsAndArgs
pub fn OptionsAndArgsParseResult(comptime OptionsType: type) type {
    return args_parser.ParseResult(ParseOptionsAndArgsResult(OptionsType));
}

/// Helper function to check if an option expects a value
fn optionExpectsValue(comptime OptionsType: type, comptime meta: anytype, option_name: []const u8) bool {
    const struct_info = @typeInfo(OptionsType).@"struct";

    inline for (struct_info.fields) |field| {
        // Get the actual option name (might be customized via metadata)
        const actual_name = if (@hasField(@TypeOf(meta), "options")) blk: {
            const options_meta = @field(meta, "options");
            if (@hasField(@TypeOf(options_meta), field.name)) {
                const field_meta = @field(options_meta, field.name);
                if (@TypeOf(field_meta) != []const u8 and @hasField(@TypeOf(field_meta), "name")) {
                    break :blk field_meta.name;
                }
            }
            break :blk field.name;
        } else field.name;

        if (std.mem.eql(u8, actual_name, option_name)) {
            // Boolean options don't expect values
            return field.type != bool;
        }
    }
    return false;
}

/// Helper function to check if a short option expects a value
fn shortOptionExpectsValue(comptime OptionsType: type, comptime meta: anytype, option_char: u8) bool {
    const struct_info = @typeInfo(OptionsType).@"struct";

    inline for (struct_info.fields) |field| {
        // Check if this field has a short option that matches
        if (@hasField(@TypeOf(meta), "options")) {
            const options_meta = @field(meta, "options");
            if (@hasField(@TypeOf(options_meta), field.name)) {
                const field_meta = @field(options_meta, field.name);
                if (@TypeOf(field_meta) != []const u8 and @hasField(@TypeOf(field_meta), "short")) {
                    if (field_meta.short == option_char) {
                        return field.type != bool;
                    }
                }
            }
        }

        // Default: first character of field name
        if (field.name.len > 0 and field.name[0] == option_char) {
            return field.type != bool;
        }
    }
    return false;
}

/// Parse options from anywhere in the arguments array, returning the options and remaining positional arguments
pub fn parseOptionsAndArgs(
    comptime OptionsType: type,
    comptime meta: anytype,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) OptionsAndArgsParseResult(OptionsType) {
    // Lists to collect options and remaining args
    var option_args = std.ArrayList([]const u8).init(allocator);
    defer option_args.deinit();
    var remaining_args = std.ArrayList([]const u8).init(allocator);
    defer remaining_args.deinit();

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];

        // Check if this is an option
        if (std.mem.startsWith(u8, arg, "-") and !utils.isNegativeNumber(arg)) {
            option_args.append(arg) catch {
                return OptionsAndArgsParseResult(OptionsType){ .err = StructuredError{ .system_out_of_memory = {} } };
            };

            // Check if this option expects a value
            var expects_value = false;

            if (std.mem.startsWith(u8, arg, "--")) {
                // Long option - check if it expects a value
                const option_name = if (std.mem.indexOf(u8, arg, "=")) |eq_pos|
                    arg[2..eq_pos]
                else
                    arg[2..];

                expects_value = optionExpectsValue(OptionsType, meta, option_name);

                // If option has =value syntax, it's already included
                if (std.mem.indexOf(u8, arg, "=") != null) {
                    expects_value = false; // Already has value embedded
                }
            } else if (arg.len >= 2) {
                // Short option - check if it expects a value
                const option_char = arg[1];
                expects_value = shortOptionExpectsValue(OptionsType, meta, option_char);
            }

            // If option expects a value and next arg exists and isn't an option, consume it
            if (expects_value and i + 1 < args.len) {
                const next_arg = args[i + 1];
                if (!std.mem.startsWith(u8, next_arg, "-") or utils.isNegativeNumber(next_arg)) {
                    option_args.append(next_arg) catch {
                        return OptionsAndArgsParseResult(OptionsType){ .err = StructuredError{ .system_out_of_memory = {} } };
                    };
                    i += 1;
                }
            }
        } else {
            // This is a positional argument
            remaining_args.append(arg) catch {
                return OptionsAndArgsParseResult(OptionsType){ .err = StructuredError{ .system_out_of_memory = {} } };
            };
        }

        i += 1;
    }

    // Parse the collected options
    const options_result = parseOptionsWithMeta(OptionsType, meta, allocator, option_args.items);
    switch (options_result) {
        .ok => |parsed| {
            const remaining_slice = remaining_args.toOwnedSlice() catch {
                return OptionsAndArgsParseResult(OptionsType){ .err = StructuredError{ .system_out_of_memory = {} } };
            };
            return OptionsAndArgsParseResult(OptionsType){ .ok = ParseOptionsAndArgsResult(OptionsType){
                .options = parsed.options,
                .remaining_args = remaining_slice,
                .allocator = allocator,
            } };
        },
        .err => |structured_err| {
            return OptionsAndArgsParseResult(OptionsType){ .err = structured_err };
        },
    }
}
