const std = @import("std");
const builtin = @import("builtin");

/// Centralized logging utilities for zcli framework
/// Provides consistent error message formatting across all modules
/// Log levels for zcli operations
pub const Level = enum {
    /// For build-time errors that prevent compilation
    build_error,
    /// For runtime parsing errors (user input issues)
    parse_error,
    /// For build-time warnings (skipped files, etc.)
    build_warning,
    /// For runtime validation warnings
    validation_warning,
};

/// Standard error message formatting
pub fn logError(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    // Suppress all logs during tests to avoid test step failures
    if (builtin.is_test) return;

    switch (level) {
        .build_error => std.log.err(fmt, args),
        .parse_error => std.log.err(fmt, args),
        .build_warning => std.log.warn(fmt, args),
        .validation_warning => std.log.warn(fmt, args),
    }
}

/// Log argument parsing errors with consistent formatting
pub fn logArgumentError(comptime fmt: []const u8, args: anytype) void {
    logError(.parse_error, fmt, args);
}

/// Log option parsing errors with consistent formatting
pub fn logOptionError(comptime fmt: []const u8, args: anytype) void {
    logError(.parse_error, fmt, args);
}

/// Log build system warnings with consistent formatting
pub fn logBuildWarning(comptime fmt: []const u8, args: anytype) void {
    logError(.build_warning, fmt, args);
}

/// Log build system errors with consistent formatting
pub fn logBuildError(comptime fmt: []const u8, args: anytype) void {
    logError(.build_error, fmt, args);
}

// ============================================================================
// Standard Error Message Formatters
// ============================================================================

/// Format missing required argument error
pub fn missingRequiredArgument(field_name: []const u8, position: u32) void {
    logArgumentError("Missing required argument '{s}' (argument {d})", .{ field_name, position });
}

/// Format too many arguments error
pub fn tooManyArguments(expected: usize, actual: usize) void {
    logArgumentError("Too many arguments provided. Expected {d}, got {d}", .{ expected, actual });
}

/// Format invalid argument value error
pub fn invalidArgumentValue(value: []const u8, expected_type: []const u8) void {
    logArgumentError("Invalid {s} value: '{s}'", .{ expected_type, value });
}

/// Format invalid boolean argument error
pub fn invalidBooleanArgument(value: []const u8) void {
    logArgumentError("Invalid boolean value: '{s}'. Expected 'true', 'false', '1', or '0'", .{value});
}

/// Format invalid enum argument error
pub fn invalidEnumArgument(value: []const u8) void {
    logArgumentError("Invalid enum value: '{s}'", .{value});
}

/// Format unknown option error
pub fn unknownOption(option: []const u8) void {
    logOptionError("Unknown option: {s}{s}", .{ if (option.len == 1) "-" else "--", option });
}

/// Format missing option value error
pub fn missingOptionValue(option: []const u8) void {
    logOptionError("Option --{s} requires a value", .{option});
}

/// Format invalid option value error
pub fn invalidOptionValue(option: []const u8, value: []const u8, expected_type: []const u8) void {
    logOptionError("Invalid {s} value for option --{s}: '{s}'", .{ expected_type, option, value });
}

/// Format invalid short option value error
pub fn invalidShortOptionValue(option: u8, value: []const u8, expected_type: []const u8) void {
    logOptionError("Invalid {s} value for option -{c}: '{s}'", .{ expected_type, option, value });
}

/// Format boolean option with value error
pub fn booleanOptionWithValue(option: []const u8) void {
    logOptionError("Boolean option --{s} does not take a value", .{option});
}

/// Format option name too long error
pub fn optionNameTooLong(option: []const u8, max_length: u32) void {
    logOptionError("Option name too long (max {d} characters): --{s}", .{ max_length, option });
}

/// Format build warning for invalid command name
pub fn invalidCommandName(name: []const u8, reason: []const u8) void {
    logBuildWarning("Skipping invalid command name: {s} ({s})", .{ name, reason });
}

/// Format build error for an invalid command name. This is a hard error, not a
/// warning: silently skipping the file makes the command vanish from the CLI
/// with no reliable signal (mirrors the depth-cap and collision errors).
pub fn invalidCommandNameError(name: []const u8, reason: []const u8) void {
    logBuildError("Invalid command name '{s}': {s}", .{ name, reason });
}

/// Format build error for two commands that resolve to the same command name
/// (e.g. `foo.zig` leaf and `foo/` group). Hard error: `put`-ing the same key
/// twice would otherwise silently drop one, non-deterministically, depending on
/// filesystem iteration order.
pub fn duplicateCommandName(name: []const u8, first_path: []const u8, second_path: []const u8) void {
    logBuildError(
        "Duplicate command '{s}': defined by both '{s}' and '{s}'. " ++
            "A leaf command and a command group cannot share a name — " ++
            "delete one, or use '{s}/index.zig' for an executable parent with subcommands.",
        .{ name, first_path, second_path, name },
    );
}

/// Format build error for exceeding the maximum nesting depth. This is a hard
/// error, not a warning: silently dropping a too-deep subtree hides commands.
pub fn maxNestingDepthExceeded(max_depth: u32, path: []const u8) void {
    logBuildError("Maximum command nesting depth ({d}) exceeded at path: {s}", .{ max_depth, path });
}

/// Format build error for a command path that could not be read: an
/// unreadable directory (permissions, or it vanished mid-scan) or a dangling
/// symlink whose target can't be resolved. Hard error: silently skipping made
/// an entire command subtree vanish from the CLI with only an easy-to-miss
/// build-log line (#629).
pub fn commandPathUnreadable(path: []const u8, reason: []const u8) void {
    logBuildError("Cannot read command path '{s}': {s}", .{ path, reason });
}

/// Format build warning for field name too long
pub fn fieldNameTooLong(field_name: []const u8, max_length: u32) void {
    logBuildWarning("Field name too long for conversion buffer (max {d} characters): {s}", .{ max_length, field_name });
}

/// Format build error messages with structured formatting
pub fn buildError(comptime title: []const u8, path: []const u8, comptime description: []const u8, comptime suggestion: []const u8) void {
    // Suppress all logs during tests to avoid test step failures
    if (builtin.is_test) return;

    std.log.err("\n" ++
        "=== " ++ title ++ " ===\n" ++
        description ++ ": '{s}'\n" ++
        "\n" ++
        suggestion ++ "\n" ++
        "===========================", .{path});
}

/// Format suggestion generation failure warning
pub fn suggestionGenerationFailed(err: anyerror) void {
    logBuildWarning("Failed to generate command suggestions: {}", .{err});
}

/// Format registry generation out of memory error
pub fn registryGenerationOutOfMemory() void {
    // Suppress all logs during tests to avoid test step failures
    if (builtin.is_test) return;

    std.log.err("\n" ++
        "=== Build Error ===\n" ++
        "Out of memory while generating command registry.\n" ++
        "\n" ++
        "The command structure may be too large. Try:\n" ++
        "- Reducing the number of commands\n" ++
        "- Simplifying command metadata\n" ++
        "- Increasing available memory\n" ++
        "==================\n", .{});
}

/// Format general registry generation error
pub fn registryGenerationFailed(err: anyerror) void {
    // Suppress all logs during tests to avoid test step failures
    if (builtin.is_test) return;

    std.log.err("\n" ++
        "=== Registry Generation Error ===\n" ++
        "Failed to generate command registry source code.\n" ++
        "Error: {any}\n" ++
        "==============================\n", .{err});
}

// ============================================================================
// Tests
// ============================================================================

test "logging utility functions" {
    // Test that functions compile and can be called
    // Logs are suppressed during tests so these won't cause output

    missingRequiredArgument("name", 1);
    tooManyArguments(2, 3);
    invalidArgumentValue("not_a_number", "integer");
    invalidBooleanArgument("maybe");
    invalidEnumArgument("purple");

    unknownOption("unknown");
    unknownOption("u"); // short option
    missingOptionValue("output");
    invalidOptionValue("count", "abc", "integer");
    invalidShortOptionValue('c', "xyz", "integer");
    booleanOptionWithValue("verbose");
    optionNameTooLong("very-long-option-name", 16);

    invalidCommandName("bad name", "contains spaces");
    maxNestingDepthExceeded(6, "/deep/path/here");
    fieldNameTooLong("very_long_field_name_that_exceeds_limits", 32);
    commandPathUnreadable("commands/broken", "cannot open directory");

    buildError("Test Error", "/path/to/file", "Test description", "Test suggestion");
}
