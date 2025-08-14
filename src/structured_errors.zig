const std = @import("std");

/// Structured error types with rich context information for better debugging and user experience.
///
/// This is the foundation of zcli's error handling system. All parsing functions return
/// `ParseResult<T>` which contains either successfully parsed data or a `StructuredError`
/// with detailed context about what went wrong.
///
/// ## Key Features:
/// - **Rich Context**: Every error includes field names, positions, values, and expected types
/// - **Smart Suggestions**: Typo detection and correction suggestions for commands and options
/// - **Consistent API**: All parsing functions use the same error structure
/// - **Human-Readable**: Automatic generation of user-friendly error messages
///
/// ## Usage:
/// ```zig
/// const result = parseOptions(Options, allocator, args);
/// switch (result) {
///     .ok => |parsed| { /* use parsed data */ },
///     .err => |err| {
///         const desc = try err.description(allocator);
///         defer allocator.free(desc);
///         try stderr.print("Error: {s}\n", .{desc});
///     },
/// }
/// ```
///
/// See ERROR_HANDLING.md for comprehensive documentation.
/// Context information for argument parsing errors
pub const ArgumentErrorContext = struct {
    field_name: []const u8,
    position: usize, // 0-based position in args
    provided_value: ?[]const u8 = null,
    expected_type: []const u8,
    actual_count: ?usize = null, // For too many arguments errors

    /// Create context for missing required argument
    pub fn missingRequired(field_name: []const u8, position: usize, expected_type: []const u8) @This() {
        return .{
            .field_name = field_name,
            .position = position,
            .provided_value = null,
            .expected_type = expected_type,
        };
    }

    /// Create context for invalid argument value
    pub fn invalidValue(field_name: []const u8, position: usize, provided_value: []const u8, expected_type: []const u8) @This() {
        return .{
            .field_name = field_name,
            .position = position,
            .provided_value = provided_value,
            .expected_type = expected_type,
        };
    }

    /// Create context for too many arguments
    pub fn tooMany(expected_count: usize, actual_count: usize) @This() {
        return .{
            .field_name = "", // Not applicable for this error
            .position = expected_count,
            .provided_value = null,
            .expected_type = "argument count",
            .actual_count = actual_count,
        };
    }
};

/// Context information for option parsing errors
pub const OptionErrorContext = struct {
    option_name: []const u8,
    is_short: bool = false, // true for -o, false for --option
    provided_value: ?[]const u8 = null,
    expected_type: ?[]const u8 = null,
    suggested_options: ?[][]const u8 = null, // For unknown option suggestions

    /// Create context for unknown option
    pub fn unknown(option_name: []const u8, is_short: bool) @This() {
        return .{
            .option_name = option_name,
            .is_short = is_short,
            .provided_value = null,
            .expected_type = null,
        };
    }

    /// Create context for missing option value
    pub fn missingValue(option_name: []const u8, is_short: bool, expected_type: []const u8) @This() {
        return .{
            .option_name = option_name,
            .is_short = is_short,
            .provided_value = null,
            .expected_type = expected_type,
        };
    }

    /// Create context for invalid option value
    pub fn invalidValue(option_name: []const u8, is_short: bool, provided_value: []const u8, expected_type: []const u8) @This() {
        return .{
            .option_name = option_name,
            .is_short = is_short,
            .provided_value = provided_value,
            .expected_type = expected_type,
        };
    }

    /// Create context for boolean option with value
    pub fn booleanWithValue(option_name: []const u8, is_short: bool, provided_value: []const u8) @This() {
        return .{
            .option_name = option_name,
            .is_short = is_short,
            .provided_value = provided_value,
            .expected_type = "boolean (no value)",
        };
    }
};

/// Context information for command routing errors
pub const CommandErrorContext = struct {
    command_name: []const u8,
    command_path: []const []const u8, // Path to this command (e.g., ["users", "create"])
    available_commands: ?[][]const u8 = null,
    suggested_commands: ?[][]const u8 = null,

    /// Create context for unknown command
    pub fn unknown(command_name: []const u8, command_path: []const []const u8) @This() {
        return .{
            .command_name = command_name,
            .command_path = command_path,
        };
    }

    /// Create context for unknown subcommand
    pub fn unknownSubcommand(subcommand_name: []const u8, parent_path: []const []const u8) @This() {
        return .{
            .command_name = subcommand_name,
            .command_path = parent_path,
        };
    }
};

/// Context information for build-time errors
pub const BuildErrorContext = struct {
    file_path: ?[]const u8 = null,
    operation: []const u8,
    details: []const u8,
    suggestion: ?[]const u8 = null,

    /// Create context for command discovery error
    pub fn commandDiscovery(commands_dir: []const u8, details: []const u8) @This() {
        return .{
            .file_path = commands_dir,
            .operation = "command discovery",
            .details = details,
            .suggestion = "Check that the directory exists and is readable",
        };
    }

    /// Create context for registry generation error
    pub fn registryGeneration(details: []const u8, suggestion: ?[]const u8) @This() {
        return .{
            .file_path = null,
            .operation = "registry generation",
            .details = details,
            .suggestion = suggestion,
        };
    }
};

/// Comprehensive structured error type that can hold context for any zcli error
pub const StructuredError = union(enum) {
    // Argument parsing errors
    argument_missing_required: ArgumentErrorContext,
    argument_invalid_value: ArgumentErrorContext,
    argument_too_many: ArgumentErrorContext,

    // Option parsing errors
    option_unknown: OptionErrorContext,
    option_missing_value: OptionErrorContext,
    option_invalid_value: OptionErrorContext,
    option_boolean_with_value: OptionErrorContext,
    option_duplicate: OptionErrorContext,

    // Command routing errors
    command_not_found: CommandErrorContext,
    subcommand_not_found: CommandErrorContext,

    // Build-time errors
    build_command_discovery_failed: BuildErrorContext,
    build_registry_generation_failed: BuildErrorContext,
    build_out_of_memory: BuildErrorContext,

    // Special cases
    help_requested: void,
    version_requested: void,

    // Low-level system errors (wrapped)
    system_out_of_memory: void,
    system_file_not_found: []const u8, // file path
    system_access_denied: []const u8, // file path

    /// Convert this structured error to a simple error for compatibility with existing code
    pub fn toSimpleError(self: @This()) anyerror {
        return switch (self) {
            .argument_missing_required => error.MissingRequiredArgument,
            .argument_invalid_value => error.InvalidArgumentType,
            .argument_too_many => error.TooManyArguments,

            .option_unknown => error.UnknownOption,
            .option_missing_value => error.MissingOptionValue,
            .option_invalid_value => error.InvalidOptionValue,
            .option_boolean_with_value => error.InvalidOptionValue,
            .option_duplicate => error.DuplicateOption,

            .command_not_found => error.CommandNotFound,
            .subcommand_not_found => error.SubcommandNotFound,

            .build_command_discovery_failed => error.BuildCommandDiscoveryFailed,
            .build_registry_generation_failed => error.BuildRegistryGenerationFailed,
            .build_out_of_memory => error.OutOfMemory,

            .help_requested => error.HelpRequested,
            .version_requested => error.VersionRequested,

            .system_out_of_memory => error.OutOfMemory,
            .system_file_not_found => error.FileNotFound,
            .system_access_denied => error.AccessDenied,
        };
    }

    /// Get a human-readable description of this error
    pub fn description(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .argument_missing_required => |ctx| std.fmt.allocPrint(allocator, "Missing required argument '{s}' at position {d}. Expected type: {s}", .{ ctx.field_name, ctx.position + 1, ctx.expected_type }),
            .argument_invalid_value => |ctx| std.fmt.allocPrint(allocator, "Invalid value '{s}' for argument '{s}' at position {d}. Expected type: {s}", .{ ctx.provided_value.?, ctx.field_name, ctx.position + 1, ctx.expected_type }),
            .argument_too_many => |ctx| {
                if (ctx.actual_count) |actual| {
                    return std.fmt.allocPrint(allocator, "Too many arguments provided. Expected {d} arguments, got {d}", .{ ctx.position, actual });
                } else {
                    return std.fmt.allocPrint(allocator, "Too many arguments provided. Expected {d} arguments", .{ctx.position});
                }
            },

            .option_unknown => |ctx| std.fmt.allocPrint(allocator, "Unknown option '{s}{s}'", .{ if (ctx.is_short) "-" else "--", ctx.option_name }),
            .option_missing_value => |ctx| std.fmt.allocPrint(allocator, "Option '{s}{s}' requires a value of type: {s}", .{ if (ctx.is_short) "-" else "--", ctx.option_name, ctx.expected_type.? }),
            .option_invalid_value => |ctx| std.fmt.allocPrint(allocator, "Invalid value '{s}' for option '{s}{s}'. Expected type: {s}", .{ ctx.provided_value.?, if (ctx.is_short) "-" else "--", ctx.option_name, ctx.expected_type.? }),
            .option_boolean_with_value => |ctx| std.fmt.allocPrint(allocator, "Boolean option '{s}{s}' does not accept a value (got '{s}')", .{ if (ctx.is_short) "-" else "--", ctx.option_name, ctx.provided_value.? }),

            .command_not_found => |ctx| std.fmt.allocPrint(allocator, "Unknown command '{s}'", .{ctx.command_name}),
            .subcommand_not_found => |ctx| std.fmt.allocPrint(allocator, "Unknown subcommand '{s}' for command path: {s}", .{ ctx.command_name, if (ctx.command_path.len > 0) ctx.command_path[ctx.command_path.len - 1] else "root" }),

            .build_command_discovery_failed => |ctx| std.fmt.allocPrint(allocator, "Command discovery failed in '{s}': {s}", .{ ctx.file_path.?, ctx.details }),
            .build_registry_generation_failed => |ctx| std.fmt.allocPrint(allocator, "Registry generation failed: {s}", .{ctx.details}),

            .help_requested => std.fmt.allocPrint(allocator, "Help requested", .{}),
            .version_requested => std.fmt.allocPrint(allocator, "Version requested", .{}),

            .system_out_of_memory => std.fmt.allocPrint(allocator, "Out of memory", .{}),
            .system_file_not_found => |path| std.fmt.allocPrint(allocator, "File not found: {s}", .{path}),
            .system_access_denied => |path| std.fmt.allocPrint(allocator, "Access denied: {s}", .{path}),

            else => std.fmt.allocPrint(allocator, "Unknown error", .{}),
        };
    }

    /// Get suggestions for fixing this error (if any)
    pub fn suggestions(self: @This()) ?[]const []const u8 {
        return switch (self) {
            .option_unknown => |ctx| ctx.suggested_options,
            .command_not_found => |ctx| ctx.suggested_commands,
            .subcommand_not_found => |ctx| ctx.suggested_commands,
            else => null,
        };
    }
};

/// Helper function to create structured errors from simple error types with context
pub const ErrorBuilder = struct {
    /// Create a structured error for missing required argument
    pub fn missingRequiredArgument(field_name: []const u8, position: usize, expected_type: []const u8) StructuredError {
        return StructuredError{ .argument_missing_required = ArgumentErrorContext.missingRequired(field_name, position, expected_type) };
    }

    /// Create a structured error for invalid argument value
    pub fn invalidArgumentValue(field_name: []const u8, position: usize, provided_value: []const u8, expected_type: []const u8) StructuredError {
        return StructuredError{ .argument_invalid_value = ArgumentErrorContext.invalidValue(field_name, position, provided_value, expected_type) };
    }

    /// Create a structured error for unknown option
    pub fn unknownOption(option_name: []const u8, is_short: bool) StructuredError {
        return StructuredError{ .option_unknown = OptionErrorContext.unknown(option_name, is_short) };
    }

    /// Create a structured error for missing option value
    pub fn missingOptionValue(option_name: []const u8, is_short: bool, expected_type: []const u8) StructuredError {
        return StructuredError{ .option_missing_value = OptionErrorContext.missingValue(option_name, is_short, expected_type) };
    }

    /// Create a structured error for invalid option value
    pub fn invalidOptionValue(option_name: []const u8, is_short: bool, provided_value: []const u8, expected_type: []const u8) StructuredError {
        return StructuredError{ .option_invalid_value = OptionErrorContext.invalidValue(option_name, is_short, provided_value, expected_type) };
    }

    /// Create a structured error for unknown command
    pub fn unknownCommand(command_name: []const u8, command_path: []const []const u8) StructuredError {
        return StructuredError{ .command_not_found = CommandErrorContext.unknown(command_name, command_path) };
    }

    /// Create a structured error for build failure
    pub fn buildError(operation: []const u8, details: []const u8, file_path: ?[]const u8, suggestion: ?[]const u8) StructuredError {
        return StructuredError{ .build_command_discovery_failed = BuildErrorContext{
            .operation = operation,
            .details = details,
            .file_path = file_path,
            .suggestion = suggestion,
        } };
    }
};

// Tests
test "structured error creation and conversion" {
    const allocator = std.testing.allocator;

    // Test argument error
    const arg_error = ErrorBuilder.missingRequiredArgument("username", 0, "string");
    try std.testing.expectEqual(error.MissingRequiredArgument, arg_error.toSimpleError());

    const arg_desc = try arg_error.description(allocator);
    defer allocator.free(arg_desc);
    try std.testing.expect(std.mem.indexOf(u8, arg_desc, "username") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg_desc, "position 1") != null);

    // Test option error
    const opt_error = ErrorBuilder.unknownOption("verbose", false);
    try std.testing.expectEqual(error.UnknownOption, opt_error.toSimpleError());

    const opt_desc = try opt_error.description(allocator);
    defer allocator.free(opt_desc);
    try std.testing.expect(std.mem.indexOf(u8, opt_desc, "--verbose") != null);

    // Test command error
    const cmd_error = ErrorBuilder.unknownCommand("invalidcmd", &[_][]const u8{"root"});
    try std.testing.expectEqual(error.CommandNotFound, cmd_error.toSimpleError());

    const cmd_desc = try cmd_error.description(allocator);
    defer allocator.free(cmd_desc);
    try std.testing.expect(std.mem.indexOf(u8, cmd_desc, "invalidcmd") != null);
}

test "structured error context information" {
    // Test that context information is preserved
    const error1 = StructuredError{ .option_invalid_value = OptionErrorContext.invalidValue("count", false, "abc", "integer") };

    switch (error1) {
        .option_invalid_value => |ctx| {
            try std.testing.expectEqualStrings("count", ctx.option_name);
            try std.testing.expectEqualStrings("abc", ctx.provided_value.?);
            try std.testing.expectEqualStrings("integer", ctx.expected_type.?);
            try std.testing.expectEqual(false, ctx.is_short);
        },
        else => try std.testing.expect(false),
    }
}

test "error builder convenience functions" {
    const opt_error = ErrorBuilder.invalidOptionValue("port", true, "abc", "u16");

    switch (opt_error) {
        .option_invalid_value => |ctx| {
            try std.testing.expectEqualStrings("port", ctx.option_name);
            try std.testing.expectEqualStrings("abc", ctx.provided_value.?);
            try std.testing.expectEqualStrings("u16", ctx.expected_type.?);
            try std.testing.expectEqual(true, ctx.is_short);
        },
        else => try std.testing.expect(false),
    }
}
