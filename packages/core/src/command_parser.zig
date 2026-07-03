const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const option_utils = @import("options/utils.zig");
const diagnostic_errors = @import("diagnostic_errors.zig");

pub const ZcliError = diagnostic_errors.ZcliError;
pub const ZcliDiagnostic = diagnostic_errors.ZcliDiagnostic;

/// Result of parsing a complete command line with mixed arguments and options
pub fn CommandParseResult(comptime ArgsType: type, comptime OptionsType: type) type {
    return struct {
        args: ArgsType,
        options: OptionsType,
        allocator: ?std.mem.Allocator = null, // Only set if cleanup is needed
        _positional_slice: ?[]const []const u8 = null, // Keep varargs slice alive

        pub fn deinit(self: @This()) void {
            if (self.allocator) |allocator| {
                // Cleanup any allocated arrays in options
                options_parser.cleanupOptions(OptionsType, self.options, allocator);

                // Cleanup positional slice if we allocated it
                if (self._positional_slice) |slice| {
                    allocator.free(slice);
                }
            }
        }
    };
}

/// Parse a command line with mixed arguments and options in a single pass.
/// This function understands both positional arguments and options, handling them
/// in the order they appear while respecting the semantics of each.
///
/// Example:
/// ```
/// const Args = struct { file: []const u8, output: ?[]const u8 = null };
/// const Options = struct { verbose: bool = false, format: enum { json, yaml } = .json };
///
/// const result = try parseCommandLine(Args, Options, null, allocator, context.environ,
///     &.{"input.txt", "--verbose", "--format", "json", "output.txt"});
/// defer result.deinit();
///
/// // result.args.file = "input.txt"
/// // result.args.output = "output.txt"
/// // result.options.verbose = true
/// // result.options.format = .json
/// ```
pub fn parseCommandLine(
    comptime ArgsType: type,
    comptime OptionsType: type,
    comptime meta: anytype,
    allocator: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    args: []const []const u8,
    diag: ?*?ZcliDiagnostic,
) ZcliError!CommandParseResult(ArgsType, OptionsType) {
    // First pass: separate options from positional arguments
    var option_args = std.ArrayList([]const u8).empty;
    defer option_args.deinit(allocator);
    var positional_args = std.ArrayList([]const u8).empty;
    defer positional_args.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];

        // Handle "--" separator (everything after is positional)
        if (std.mem.eql(u8, arg, "--")) {
            // Add remaining args as positional
            for (args[i + 1 ..]) |remaining_arg| {
                positional_args.append(allocator, remaining_arg) catch return ZcliError.SystemOutOfMemory;
            }
            break;
        }

        // Handle options (start with -, but not negative numbers)
        if (std.mem.startsWith(u8, arg, "-") and !isNegativeNumber(arg)) {
            option_args.append(allocator, arg) catch return ZcliError.SystemOutOfMemory;

            // Check if this option expects a value
            if (std.mem.startsWith(u8, arg, "--")) {
                // Long option
                if (std.mem.indexOf(u8, arg, "=")) |_| {
                    // --option=value format, no additional arg needed
                    i += 1;
                    continue;
                } else {
                    // --option format, might need next arg as value. Uses the
                    // same resolution the options parser uses (incl. custom
                    // meta names) and the same "next token is a value, not
                    // another flag" condition, so split and parse agree.
                    const option_name = arg[2..]; // Remove "--"
                    const takes_value = option_utils.longOptionTakesValue(OptionsType, meta, option_name) orelse false;
                    if (takes_value and i + 1 < args.len and
                        (!std.mem.startsWith(u8, args[i + 1], "-") or isNegativeNumber(args[i + 1])))
                    {
                        i += 1;
                        option_args.append(allocator, args[i]) catch return ZcliError.SystemOutOfMemory;
                    }
                }
            } else {
                // Short option -x or -xyz
                const option_chars = arg[1..];
                if (option_chars.len == 1) {
                    // Single short option, might need value
                    const option_char = option_chars[0];
                    const takes_value = option_utils.shortOptionTakesValue(OptionsType, meta, option_char) orelse false;
                    if (takes_value and i + 1 < args.len) {
                        i += 1;
                        option_args.append(allocator, args[i]) catch return ZcliError.SystemOutOfMemory;
                    }
                }
                // For bundled short options (-xyz), assume they're all boolean
            }
        } else {
            // Positional argument
            positional_args.append(allocator, arg) catch return ZcliError.SystemOutOfMemory;
        }

        i += 1;
    }

    // Parse options from the collected option arguments. Always goes through
    // the meta-aware parser (not just when flags were passed) so `.env`
    // fallbacks apply to a command line with no options at all.
    const options = try parseOptionsFromArgs(OptionsType, meta, allocator, environ, option_args.items, diag);

    // Parse positional arguments
    // Note: We need to keep positional_args.items alive for the lifetime of the result
    // because parseArgs may create references to the input slice (for varargs)
    const positional_slice = positional_args.toOwnedSlice(allocator) catch return ZcliError.SystemOutOfMemory;
    const parsed_args = args_parser.parseArgs(ArgsType, positional_slice, diag) catch |err| {
        // If parseArgs fails, we need to clean up the slice we allocated
        allocator.free(positional_slice);
        return err;
    };

    const has_varargs = hasVarargsFields(ArgsType);
    const needs_cleanup = hasArrayFields(OptionsType) or has_varargs;
    return CommandParseResult(ArgsType, OptionsType){
        .args = parsed_args,
        .options = options,
        .allocator = if (needs_cleanup) allocator else null,
        ._positional_slice = if (has_varargs) positional_slice else blk: {
            // If no varargs, we don't need to keep the slice alive, so free it now
            allocator.free(positional_slice);
            break :blk null;
        },
    };
}

/// Check if a string represents a negative number
fn isNegativeNumber(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;

    // Check if the character after '-' is a digit
    return std.ascii.isDigit(arg[1]);
}

/// Parse options from a list of option arguments
fn parseOptionsFromArgs(
    comptime OptionsType: type,
    comptime meta: anytype,
    allocator: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    option_args: []const []const u8,
    diag: ?*?ZcliDiagnostic,
) ZcliError!OptionsType {
    // Delegate to the meta-aware options parser: meta carries custom names,
    // shorts, and `.env` fallback declarations.
    const result = try options_parser.parseOptionsWithMeta(OptionsType, meta, allocator, environ, option_args, diag);
    return result.options;
}

/// Initialize an options struct with all default values
fn initializeDefaultOptions(comptime OptionsType: type) OptionsType {
    const type_info = @typeInfo(OptionsType);
    if (type_info != .@"struct") {
        @compileError("OptionsType must be a struct");
    }

    var result: OptionsType = undefined;

    inline for (type_info.@"struct".fields) |field| {
        if (comptime option_utils.isArrayType(field.type)) {
            const element_type = @typeInfo(field.type).pointer.child;
            @field(result, field.name) = @as(field.type, &[_]element_type{});
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else if (field.type == bool) {
            @field(result, field.name) = false;
        } else if (field.default_value_ptr) |default_ptr| {
            const default_value: *const field.type = @ptrCast(@alignCast(default_ptr));
            @field(result, field.name) = default_value.*;
        } else {
            // Same rule the options parser enforces: a field with no
            // absent-flag value would be read as undefined memory.
            @compileError("option field '" ++ field.name ++ "' has type `" ++ @typeName(field.type) ++
                "` and no default value, so it would be undefined when the flag is not passed. " ++
                "Options must be bool, optional, an accumulating array, or have a default; " ++
                "required values belong in Args.");
        }
    }

    return result;
}

/// Check if an options type has any array fields that need cleanup
fn hasArrayFields(comptime OptionsType: type) bool {
    const type_info = @typeInfo(OptionsType);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".fields) |field| {
        if (@typeInfo(field.type) == .pointer) {
            const ptr_info = @typeInfo(field.type).pointer;
            if (ptr_info.size == .slice) {
                return true; // Found an array/slice field
            }
        }
    }

    return false;
}

/// Check if an args type has varargs fields (last field is an array)
fn hasVarargsFields(comptime ArgsType: type) bool {
    const type_info = @typeInfo(ArgsType);
    if (type_info != .@"struct") return false;
    if (type_info.@"struct".fields.len == 0) return false;

    // Check if the last field is an array/slice
    const last_field = type_info.@"struct".fields[type_info.@"struct".fields.len - 1];
    if (@typeInfo(last_field.type) == .pointer) {
        const ptr_info = @typeInfo(last_field.type).pointer;
        return ptr_info.size == .slice;
    }

    return false;
}

// Tests
test "parseCommandLine basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Args = struct {
        file: []const u8,
        output: ?[]const u8 = null,
    };

    const Options = struct {
        verbose: bool = false,
        format: enum { json, yaml } = .json,
    };

    // Test mixed args and options
    const result = try parseCommandLine(Args, Options, null, allocator, null, &.{ "input.txt", "--verbose", "output.txt" }, null);
    defer result.deinit();

    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expectEqualStrings("output.txt", result.args.output.?);
    try testing.expect(result.options.verbose);
    try testing.expectEqual(.json, result.options.format);
}

test "parseCommandLine options only" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Args = struct {
        file: ?[]const u8 = null,
    };

    const Options = struct {
        verbose: bool = false,
        count: u32 = 1,
    };

    const result = try parseCommandLine(Args, Options, null, allocator, null, &.{ "--verbose", "--count", "5" }, null);
    defer result.deinit();

    try testing.expect(result.args.file == null);
    try testing.expect(result.options.verbose);
    try testing.expectEqual(@as(u32, 5), result.options.count);
}

// End-to-end tests migrated from command_parser_e2e_test.zig
// These tests ensure complex real-world scenarios work correctly

test "e2e: arguments only" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const BasicArgs = struct {
        file: []const u8,
        output: ?[]const u8 = null,
    };

    const result = try parseCommandLine(BasicArgs, struct {}, null, allocator, null, &.{ "input.txt", "output.txt" }, null);
    defer result.deinit();

    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expectEqualStrings("output.txt", result.args.output.?);
}

test "e2e: optional arguments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const BasicArgs = struct {
        file: []const u8,
        output: ?[]const u8 = null,
    };

    const result = try parseCommandLine(BasicArgs, struct {}, null, allocator, null, &.{"input.txt"}, null);
    defer result.deinit();

    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expect(result.args.output == null);
}

test "e2e: boolean flags only" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const BasicOptions = struct {
        verbose: bool = false,
        debug: bool = false,
        count: u32 = 1,
        format: enum { json, yaml, xml } = .json,
    };

    const result = try parseCommandLine(struct {}, BasicOptions, null, allocator, null, &.{ "--verbose", "--debug" }, null);
    defer result.deinit();

    try testing.expect(result.options.verbose);
    try testing.expect(result.options.debug);
    try testing.expectEqual(@as(u32, 1), result.options.count);
    try testing.expectEqual(.json, result.options.format);
}

test "e2e: value options" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const BasicOptions = struct {
        verbose: bool = false,
        debug: bool = false,
        count: u32 = 1,
        format: enum { json, yaml, xml } = .json,
    };

    const result = try parseCommandLine(struct {}, BasicOptions, null, allocator, null, &.{ "--count", "42", "--format", "yaml" }, null);
    defer result.deinit();

    try testing.expect(!result.options.verbose);
    try testing.expect(!result.options.debug);
    try testing.expectEqual(@as(u32, 42), result.options.count);
    try testing.expectEqual(.yaml, result.options.format);
}

test "e2e: options after arguments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const BasicArgs = struct {
        file: []const u8,
        output: ?[]const u8 = null,
    };

    const BasicOptions = struct {
        verbose: bool = false,
        debug: bool = false,
        count: u32 = 1,
        format: enum { json, yaml, xml } = .json,
    };

    const result = try parseCommandLine(BasicArgs, BasicOptions, null, allocator, null, &.{ "input.txt", "--verbose", "output.txt", "--count", "10" }, null);
    defer result.deinit();

    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expectEqualStrings("output.txt", result.args.output.?);
    try testing.expect(result.options.verbose);
    try testing.expectEqual(@as(u32, 10), result.options.count);
}

test "e2e: options before arguments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const BasicArgs = struct {
        file: []const u8,
        output: ?[]const u8 = null,
    };

    const BasicOptions = struct {
        verbose: bool = false,
        debug: bool = false,
        count: u32 = 1,
        format: enum { json, yaml, xml } = .json,
    };

    const result = try parseCommandLine(BasicArgs, BasicOptions, null, allocator, null, &.{ "--verbose", "--count", "5", "input.txt", "output.txt" }, null);
    defer result.deinit();

    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expectEqualStrings("output.txt", result.args.output.?);
    try testing.expect(result.options.verbose);
    try testing.expectEqual(@as(u32, 5), result.options.count);
}

test "e2e: fully interleaved options and arguments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const BasicArgs = struct {
        file: []const u8,
        output: ?[]const u8 = null,
    };

    const BasicOptions = struct {
        verbose: bool = false,
        debug: bool = false,
        count: u32 = 1,
        format: enum { json, yaml, xml } = .json,
    };

    const result = try parseCommandLine(BasicArgs, BasicOptions, null, allocator, null, &.{ "--debug", "input.txt", "--count", "3", "--verbose", "output.txt" }, null);
    defer result.deinit();

    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expectEqualStrings("output.txt", result.args.output.?);
    try testing.expect(result.options.verbose);
    try testing.expect(result.options.debug);
    try testing.expectEqual(@as(u32, 3), result.options.count);
}

test "e2e: multiple array values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ArrayOptions = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
        verbose: bool = false,
    };

    const result = try parseCommandLine(struct {}, ArrayOptions, null, allocator, null, &.{ "--files", "a.txt", "--files", "b.txt", "--files", "c.txt" }, null);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.options.files.len);
    try testing.expectEqualStrings("a.txt", result.options.files[0]);
    try testing.expectEqualStrings("b.txt", result.options.files[1]);
    try testing.expectEqualStrings("c.txt", result.options.files[2]);
}

test "e2e: array options mixed with other options" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ArrayOptions = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
        verbose: bool = false,
    };

    const result = try parseCommandLine(struct {}, ArrayOptions, null, allocator, null, &.{ "--files", "first.txt", "--verbose", "--files", "second.txt", "--numbers", "42" }, null);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.options.files.len);
    try testing.expectEqualStrings("first.txt", result.options.files[0]);
    try testing.expectEqualStrings("second.txt", result.options.files[1]);
    try testing.expectEqual(@as(usize, 1), result.options.numbers.len);
    try testing.expectEqual(@as(i32, 42), result.options.numbers[0]);
    try testing.expect(result.options.verbose);
}

test "e2e: repeated array options with short codes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const RepeatOptions = struct {
        output: [][]const u8 = &.{},

        pub const meta = .{
            .options = .{
                .output = .{ .short = 'o' },
            },
        };
    };

    // Test with long form (should work)
    {
        const result = try parseCommandLine(struct {}, RepeatOptions, RepeatOptions.meta, allocator, null, &.{ "--output", "file1.txt", "--output", "file2.txt", "--output", "file3.txt" }, null);
        defer result.deinit();

        try testing.expectEqual(@as(usize, 3), result.options.output.len);
        try testing.expectEqualStrings("file1.txt", result.options.output[0]);
        try testing.expectEqualStrings("file2.txt", result.options.output[1]);
        try testing.expectEqualStrings("file3.txt", result.options.output[2]);
    }

    // Test with short form (reported bug: doesn't work)
    {
        const result = try parseCommandLine(struct {}, RepeatOptions, RepeatOptions.meta, allocator, null, &.{ "-o", "file1.txt", "-o", "file2.txt", "-o", "file3.txt" }, null);
        defer result.deinit();

        try testing.expectEqual(@as(usize, 3), result.options.output.len);
        try testing.expectEqualStrings("file1.txt", result.options.output[0]);
        try testing.expectEqualStrings("file2.txt", result.options.output[1]);
        try testing.expectEqualStrings("file3.txt", result.options.output[2]);
    }

    // Test mixed long and short form
    {
        const result = try parseCommandLine(struct {}, RepeatOptions, RepeatOptions.meta, allocator, null, &.{ "-o", "file1.txt", "--output", "file2.txt", "-o", "file3.txt" }, null);
        defer result.deinit();

        try testing.expectEqual(@as(usize, 3), result.options.output.len);
        try testing.expectEqualStrings("file1.txt", result.options.output[0]);
        try testing.expectEqualStrings("file2.txt", result.options.output[1]);
        try testing.expectEqualStrings("file3.txt", result.options.output[2]);
    }
}

test "e2e: git-like command" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const GitArgs = struct {
        repository: ?[]const u8 = null,
    };

    const GitOptions = struct {
        bare: bool = false,
        shared: bool = false,
        template: ?[]const u8 = null,
    };

    const result = try parseCommandLine(GitArgs, GitOptions, null, allocator, null, &.{ "my-repo", "--bare", "--template", "/path/to/template" }, null);
    defer result.deinit();

    try testing.expectEqualStrings("my-repo", result.args.repository.?);
    try testing.expect(result.options.bare);
    try testing.expectEqualStrings("/path/to/template", result.options.template.?);
    try testing.expect(!result.options.shared);
}

test "e2e: docker-like command with filters" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const DockerOptions = struct {
        all: bool = false,
        filter: [][]const u8 = &.{},
        format: ?[]const u8 = null,
        quiet: bool = false,
    };

    const result = try parseCommandLine(struct {}, DockerOptions, null, allocator, null, &.{ "--filter", "status=running", "--all", "--filter", "name=web", "--quiet" }, null);
    defer result.deinit();

    try testing.expect(result.options.all);
    try testing.expect(result.options.quiet);
    try testing.expectEqual(@as(usize, 2), result.options.filter.len);
    try testing.expectEqualStrings("status=running", result.options.filter[0]);
    try testing.expectEqualStrings("name=web", result.options.filter[1]);
}

test "e2e: negative numbers as arguments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const NumberArgs = struct {
        threshold: []const u8,
        value: ?[]const u8 = null,
    };

    const BasicOptions = struct {
        verbose: bool = false,
        debug: bool = false,
        count: u32 = 1,
        format: enum { json, yaml, xml } = .json,
    };

    const result = try parseCommandLine(NumberArgs, BasicOptions, null, allocator, null, &.{ "--verbose", "-5", "--count", "10", "-42" }, null);
    defer result.deinit();

    try testing.expectEqualStrings("-5", result.args.threshold);
    try testing.expectEqualStrings("-42", result.args.value.?);
    try testing.expect(result.options.verbose);
    try testing.expectEqual(@as(u32, 10), result.options.count);
}

test "e2e: empty string values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const EmptyArgs = struct {
        name: []const u8,
        message: ?[]const u8 = null,
    };

    const EmptyOptions = struct {
        output: ?[]const u8 = null,
        prefix: []const u8 = "default",
    };

    const result = try parseCommandLine(EmptyArgs, EmptyOptions, null, allocator, null, &.{ "test", "", "--output", "", "--prefix", "custom" }, null);
    defer result.deinit();

    try testing.expectEqualStrings("test", result.args.name);
    try testing.expectEqualStrings("", result.args.message.?);
    try testing.expectEqualStrings("", result.options.output.?);
    try testing.expectEqualStrings("custom", result.options.prefix);
}

test "e2e: missing required arguments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const BasicArgs = struct {
        file: []const u8,
        output: ?[]const u8 = null,
    };

    const BasicOptions = struct {
        verbose: bool = false,
        debug: bool = false,
        count: u32 = 1,
        format: enum { json, yaml, xml } = .json,
    };

    const result = parseCommandLine(BasicArgs, BasicOptions, null, allocator, null, &.{"--verbose"}, null);
    try testing.expectError(ZcliError.ArgumentMissingRequired, result);
}

test "e2e: too many arguments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const LimitedArgs = struct {
        single_arg: []const u8,
    };

    const BasicOptions = struct {
        verbose: bool = false,
        debug: bool = false,
        count: u32 = 1,
        format: enum { json, yaml, xml } = .json,
    };

    const result = parseCommandLine(LimitedArgs, BasicOptions, null, allocator, null, &.{ "arg1", "arg2", "arg3" }, null);
    try testing.expectError(ZcliError.ArgumentTooMany, result);
}

test "e2e: unknown option" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const BasicArgs = struct {
        file: []const u8,
        output: ?[]const u8 = null,
    };

    const BasicOptions = struct {
        verbose: bool = false,
        debug: bool = false,
        count: u32 = 1,
        format: enum { json, yaml, xml } = .json,
    };

    const result = parseCommandLine(BasicArgs, BasicOptions, null, allocator, null, &.{ "input.txt", "--unknown", "value" }, null);
    try testing.expectError(ZcliError.OptionUnknown, result);
}

test "e2e: basic example init command scenarios" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const InitArgs = struct {
        directory: ?[]const u8 = null,
    };

    const InitOptions = struct {
        bare: bool = false,
    };

    // Option only
    {
        const result = try parseCommandLine(InitArgs, InitOptions, null, allocator, null, &.{"--bare"}, null);
        defer result.deinit();
        try testing.expect(result.args.directory == null);
        try testing.expect(result.options.bare);
    }

    // Argument then option
    {
        const result = try parseCommandLine(InitArgs, InitOptions, null, allocator, null, &.{ "test-repo", "--bare" }, null);
        defer result.deinit();
        try testing.expectEqualStrings("test-repo", result.args.directory.?);
        try testing.expect(result.options.bare);
    }

    // Argument only
    {
        const result = try parseCommandLine(InitArgs, InitOptions, null, allocator, null, &.{"new-repo"}, null);
        defer result.deinit();
        try testing.expectEqualStrings("new-repo", result.args.directory.?);
        try testing.expect(!result.options.bare);
    }

    // Option then argument
    {
        const result = try parseCommandLine(InitArgs, InitOptions, null, allocator, null, &.{ "--bare", "another-repo" }, null);
        defer result.deinit();
        try testing.expectEqualStrings("another-repo", result.args.directory.?);
        try testing.expect(result.options.bare);
    }
}

test "e2e: advanced example container ls scenarios" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ContainerOptions = struct {
        all: bool = false,
        filter: [][]const u8 = &.{},
        format: ?[]const u8 = null,
        last: ?u32 = null,
        latest: bool = false,
        no_trunc: bool = false,
        quiet: bool = false,
        size: bool = false,
    };

    // Multiple filters with other options
    {
        const result = try parseCommandLine(struct {}, ContainerOptions, null, allocator, null, &.{ "--filter", "status=running", "--filter", "name=web", "--all" }, null);
        defer result.deinit();
        try testing.expect(result.options.all);
        try testing.expectEqual(@as(usize, 2), result.options.filter.len);
        try testing.expectEqualStrings("status=running", result.options.filter[0]);
        try testing.expectEqualStrings("name=web", result.options.filter[1]);
    }

    // Mixed option ordering
    {
        const result = try parseCommandLine(struct {}, ContainerOptions, null, allocator, null, &.{ "--all", "--filter", "status=Up", "--quiet" }, null);
        defer result.deinit();
        try testing.expect(result.options.all);
        try testing.expect(result.options.quiet);
        try testing.expectEqual(@as(usize, 1), result.options.filter.len);
        try testing.expectEqualStrings("status=Up", result.options.filter[0]);
    }
}

test "parseCommandLine applies env fallbacks even with no flags on the command line" {
    const allocator = std.testing.allocator;

    const Args = struct { file: []const u8 };
    const Options = struct { region: []const u8 = "us-east-1" };
    const meta = .{ .options = .{ .region = .{ .env = "ZCLI_TEST_REGION" } } };

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("ZCLI_TEST_REGION", "eu-west-2");

    // No --region flag anywhere: the env fallback must still apply (the
    // no-options path used to skip the meta-aware parser entirely).
    const result = try parseCommandLine(Args, Options, meta, allocator, &env, &.{"input.txt"}, null);
    defer result.deinit();

    try std.testing.expectEqualStrings("input.txt", result.args.file);
    try std.testing.expectEqualStrings("eu-west-2", result.options.region);

    // And the CLI still wins when both are present.
    const r2 = try parseCommandLine(Args, Options, meta, allocator, &env, &.{ "input.txt", "--region", "ap-south-1" }, null);
    defer r2.deinit();
    try std.testing.expectEqualStrings("ap-south-1", r2.options.region);
}

test "pre-split honors custom meta names when classifying values" {
    // --out is a custom name for output_file, which takes a value. The old
    // pre-split heuristic only looked at field names, so "result.txt" was
    // classified as a positional and parsing then failed with
    // MissingOptionValue — split and parse disagreed about the same token.
    const allocator = std.testing.allocator;
    const Args = struct { file: []const u8 };
    const Options = struct { output_file: ?[]const u8 = null };
    const meta = .{ .options = .{ .output_file = .{ .name = "out" } } };

    const result = try parseCommandLine(Args, Options, meta, allocator, null, &.{ "--out", "result.txt", "input.zig" }, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("result.txt", result.options.output_file.?);
    try std.testing.expectEqualStrings("input.zig", result.args.file);
}

test "boolean flag followed by a bare word keeps the word as a positional" {
    const allocator = std.testing.allocator;
    const Args = struct { file: []const u8 };
    const Options = struct { verbose: bool = false };

    const result = try parseCommandLine(Args, Options, null, allocator, null, &.{ "--verbose", "input.txt" }, null);
    defer result.deinit();
    try std.testing.expect(result.options.verbose);
    try std.testing.expectEqualStrings("input.txt", result.args.file);
}

test "a flag is never classified as another flag's value" {
    // --tag wants a value but the next token is itself a flag: the split
    // applies the same next-token rule the parser does, so the parser
    // reports the missing value for the right option.
    const allocator = std.testing.allocator;
    const Options = struct { tag: ?[]const u8 = null, verbose: bool = false };

    var diag: ?ZcliDiagnostic = null;
    const result = parseCommandLine(struct {}, Options, null, allocator, null, &.{ "--tag", "--verbose" }, &diag);
    try std.testing.expectError(ZcliError.OptionMissingValue, result);
    try std.testing.expectEqualStrings("tag", diag.?.OptionMissingValue.option_name);
}

test "negative numbers classify as values and positionals, not flags" {
    const allocator = std.testing.allocator;
    const Args = struct { delta: i32 };
    const Options = struct { offset: i32 = 0 };

    const result = try parseCommandLine(Args, Options, null, allocator, null, &.{ "--offset", "-5", "-10" }, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(i32, -5), result.options.offset);
    try std.testing.expectEqual(@as(i32, -10), result.args.delta);
}
