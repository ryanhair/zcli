const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const tokenizer = @import("options/tokenizer.zig");
const diagnostic_errors = @import("diagnostic_errors.zig");

pub const ZcliError = diagnostic_errors.ZcliError;
pub const ZcliDiagnostic = diagnostic_errors.ZcliDiagnostic;

/// One flag per Options field (field-declaration order) — the size of the
/// `options_provided`/`config_applied` bitsets the registry threads through
/// the required/constraint checks.
pub const optionFieldCount = options_parser.optionFieldCount;

/// Result of parsing a complete command line with mixed arguments and options
pub fn CommandParseResult(comptime ArgsType: type, comptime OptionsType: type) type {
    return struct {
        args: ArgsType,
        options: OptionsType,
        /// One flag per Options field, true when env or CLI set it. The registry
        /// combines this with the config pass to enforce required options.
        options_provided: [options_parser.optionFieldCount(OptionsType)]bool = [_]bool{false} ** options_parser.optionFieldCount(OptionsType),
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

    // Drive the shared argv tokenizer (options/tokenizer.zig) with the same
    // Options/meta spec the options parser resolves against, so this split and
    // the parse cannot disagree about which token is a flag's value (#287,
    // #299, #427): the tokenizer owns the `--` terminator, the negative-number
    // and bare-`-` positional rules, the short-bundle state machine, and the
    // next-token value lookahead. Here a token classifies to one of two piles;
    // a value the tokenizer consumed for an option travels with the option.
    var tok = tokenizer.Tokenizer(tokenizer.OptionsSpec(OptionsType, meta)){ .args = args };
    while (tok.next()) |token| {
        switch (token) {
            // The `--` itself is dropped; everything after it arrives as
            // `.positional`, verbatim.
            .terminator => {},
            .positional => |item| positional_args.append(allocator, item.raw) catch return ZcliError.SystemOutOfMemory,
            .long => |long| {
                option_args.append(allocator, long.raw) catch return ZcliError.SystemOutOfMemory;
                if (long.next_value) |value| {
                    option_args.append(allocator, value) catch return ZcliError.SystemOutOfMemory;
                }
            },
            .shorts => |shorts| {
                option_args.append(allocator, shorts.raw) catch return ZcliError.SystemOutOfMemory;
                if (shorts.next_value) |value| {
                    option_args.append(allocator, value) catch return ZcliError.SystemOutOfMemory;
                }
            },
        }
    }

    // Parse options from the collected option arguments. Always goes through
    // the meta-aware parser (not just when flags were passed) so `.env`
    // fallbacks apply to a command line with no options at all.
    const options_res = try parseOptionsFromArgs(OptionsType, meta, allocator, environ, option_args.items, diag);
    const options = options_res.options;

    // Parse positional arguments
    // Note: We need to keep positional_args.items alive for the lifetime of the result
    // because parseArgs may create references to the input slice (for varargs)
    const positional_slice = positional_args.toOwnedSlice(allocator) catch {
        // Same contract as the parseArgs failure below: options were already
        // parsed, so their accumulated arrays must be freed before bailing out
        // — under a plain (non-arena) allocator they would otherwise leak on
        // the out-of-memory path (#744).
        options_parser.cleanupOptions(OptionsType, options, allocator);
        return ZcliError.SystemOutOfMemory;
    };
    const parsed_args = args_parser.parseArgs(ArgsType, positional_slice, diag) catch |err| {
        // parseArgs failed AFTER options were parsed: free the accumulated
        // option arrays as well as the slice we allocated — under a plain
        // (non-arena) allocator both would otherwise leak.
        options_parser.cleanupOptions(OptionsType, options, allocator);
        allocator.free(positional_slice);
        return err;
    };

    const has_varargs = hasVarargsFields(ArgsType);
    const needs_cleanup = hasArrayFields(OptionsType) or has_varargs;
    return CommandParseResult(ArgsType, OptionsType){
        .args = parsed_args,
        .options = options,
        .options_provided = options_res.provided,
        .allocator = if (needs_cleanup) allocator else null,
        ._positional_slice = if (has_varargs) positional_slice else blk: {
            // If no varargs, we don't need to keep the slice alive, so free it now
            allocator.free(positional_slice);
            break :blk null;
        },
    };
}

/// Parse options from a list of option arguments, returning the parsed values
/// alongside the per-field `provided` flags the required-option check needs.
fn parseOptionsFromArgs(
    comptime OptionsType: type,
    comptime meta: anytype,
    allocator: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    option_args: []const []const u8,
    diag: ?*?ZcliDiagnostic,
) ZcliError!options_parser.OptionsResult(OptionsType) {
    // Delegate to the meta-aware options parser: meta carries custom names,
    // shorts, and `.env` fallback declarations.
    return options_parser.parseOptionsWithMeta(OptionsType, meta, allocator, environ, option_args, diag);
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

/// Check if an args type has a varargs field (last field is a slice of
/// strings). Delegates to args.zig's isVarArgs so the two classifiers cannot
/// drift — a plain trailing string (`[]const u8`) is a positional, not
/// varargs, and must not cause the positional slice to be retained.
fn hasVarargsFields(comptime ArgsType: type) bool {
    const type_info = @typeInfo(ArgsType);
    if (type_info != .@"struct") return false;
    if (type_info.@"struct".fields.len == 0) return false;

    const last_field = type_info.@"struct".fields[type_info.@"struct".fields.len - 1];
    return args_parser.isVarArgs(last_field.type);
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

test "e2e: comma-separated array values through the pre-split" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ArrayOptions = struct {
        files: [][]const u8 = &.{},
        numbers: []i32 = &.{},
    };

    // The pre-split must feed the comma token through intact so the options
    // parser can split it; repetition composes with the comma form.
    const result = try parseCommandLine(struct {}, ArrayOptions, null, allocator, null, &.{ "--files", "a.txt,b.txt", "--files", "c.txt", "--numbers", "1,2,3" }, null);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.options.files.len);
    try testing.expectEqualStrings("a.txt", result.options.files[0]);
    try testing.expectEqualStrings("b.txt", result.options.files[1]);
    try testing.expectEqualStrings("c.txt", result.options.files[2]);
    try testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, result.options.numbers);
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

// #287 — the pre-split classifier used a local `-<digit>`-only isNegativeNumber
// that diverged from the shared one, so `-.5`/`-inf` positionals were silently
// routed to options and dropped. These parseCommandLine-level tests are the
// layer the prior gap slipped through (lower-layer tests all passed).
test "#287 non-integer negative positional reaches the args, not option_args" {
    const allocator = std.testing.allocator;
    const Args = struct { v: []const u8 };
    const Options = struct { verbose: bool = false };

    // Previously ArgumentMissingRequired: `-.5` vanished between split and parse.
    for ([_][]const u8{ "-.5", "-inf", "-nan", "-1e5", "-1.5e-3" }) |tok| {
        const result = try parseCommandLine(Args, Options, null, allocator, null, &.{tok}, null);
        defer result.deinit();
        try std.testing.expectEqualStrings(tok, result.args.v);
    }
}

test "#287 varargs of non-integer negatives are all captured" {
    const allocator = std.testing.allocator;
    const Args = struct { values: [][]const u8 };
    const Options = struct {};

    // Previously received zero values.
    const result = try parseCommandLine(Args, Options, null, allocator, null, &.{ "-.5", "-.25", "-inf" }, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.args.values.len);
    try std.testing.expectEqualStrings("-.5", result.args.values[0]);
    try std.testing.expectEqualStrings("-.25", result.args.values[1]);
    try std.testing.expectEqualStrings("-inf", result.args.values[2]);
}

test "#287 non-integer negative as an option value (both positions agree)" {
    const allocator = std.testing.allocator;
    const Options = struct { min: f64 = 0 };

    const result = try parseCommandLine(struct {}, Options, null, allocator, null, &.{ "--min", "-.5" }, null);
    defer result.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), result.options.min, 0.0001);
}

// #427 — the pre-split only did value-lookahead for single-char short tokens, so
// a bundle like `-vf out.txt` (a leading boolean then a value-taker) fell through
// as "all boolean" and routed the value to the positionals; the parser then saw
// `-vf` alone and reported a spurious OptionMissingValue. These parseCommandLine
// -level tests go through the pre-split (the misleading parseOptions-direct test
// in options/parser.zig bypasses it).
test "#427 bundled short with value-taker last consumes the separated value" {
    const allocator = std.testing.allocator;
    const Options = struct { verbose: bool = false, file: []const u8 = "" };
    const meta = .{ .options = .{ .verbose = .{ .short = 'v' }, .file = .{ .short = 'f' } } };

    const result = try parseCommandLine(struct {}, Options, meta, allocator, null, &.{ "-vf", "out.txt" }, null);
    defer result.deinit();
    try std.testing.expect(result.options.verbose);
    try std.testing.expectEqualStrings("out.txt", result.options.file);
}

test "#427 bundled short with attached value" {
    const allocator = std.testing.allocator;
    const Options = struct { verbose: bool = false, file: []const u8 = "" };
    const meta = .{ .options = .{ .verbose = .{ .short = 'v' }, .file = .{ .short = 'f' } } };

    const result = try parseCommandLine(struct {}, Options, meta, allocator, null, &.{"-vfout.txt"}, null);
    defer result.deinit();
    try std.testing.expect(result.options.verbose);
    try std.testing.expectEqualStrings("out.txt", result.options.file);
}

test "#427 unbundled short value-taker still works" {
    const allocator = std.testing.allocator;
    const Options = struct { verbose: bool = false, file: []const u8 = "" };
    const meta = .{ .options = .{ .verbose = .{ .short = 'v' }, .file = .{ .short = 'f' } } };

    const result = try parseCommandLine(struct {}, Options, meta, allocator, null, &.{ "-v", "-f", "out.txt" }, null);
    defer result.deinit();
    try std.testing.expect(result.options.verbose);
    try std.testing.expectEqualStrings("out.txt", result.options.file);
}

test "#427 all-boolean bundle keeps a following word as a positional" {
    const allocator = std.testing.allocator;
    const Args = struct { path: []const u8 };
    const Options = struct { verbose: bool = false, debug: bool = false };
    const meta = .{ .options = .{ .verbose = .{ .short = 'v' }, .debug = .{ .short = 'd' } } };

    const result = try parseCommandLine(Args, Options, meta, allocator, null, &.{ "-vd", "input.txt" }, null);
    defer result.deinit();
    try std.testing.expect(result.options.verbose);
    try std.testing.expect(result.options.debug);
    try std.testing.expectEqualStrings("input.txt", result.args.path);
}

test "#427 value-taker mid-bundle takes the rest as attached value, next word stays positional" {
    const allocator = std.testing.allocator;
    const Args = struct { path: []const u8 };
    const Options = struct { verbose: bool = false, file: []const u8 = "", debug: bool = false };
    const meta = .{ .options = .{ .verbose = .{ .short = 'v' }, .file = .{ .short = 'f' }, .debug = .{ .short = 'd' } } };

    // `-vfd`: v is boolean, f is the first value-taker and is not the last char,
    // so the remaining `d` is f's attached value (NOT a boolean flag). The
    // following word remains a positional.
    const result = try parseCommandLine(Args, Options, meta, allocator, null, &.{ "-vfd", "input.txt" }, null);
    defer result.deinit();
    try std.testing.expect(result.options.verbose);
    try std.testing.expectEqualStrings("d", result.options.file);
    try std.testing.expect(!result.options.debug);
    try std.testing.expectEqualStrings("input.txt", result.args.path);
}

test "#298 a bare '-' is a positional, not an unknown option" {
    const allocator = std.testing.allocator;
    const Args = struct { file: []const u8 };
    const Options = struct { verbose: bool = false };

    // Previously OptionUnknown; `-` is the stdin/stdout sentinel (`cat -`).
    const result = try parseCommandLine(Args, Options, null, allocator, null, &.{"-"}, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("-", result.args.file);
    try std.testing.expect(!result.options.verbose);
}

test "#298 bare '-' among other args and after a flag" {
    const allocator = std.testing.allocator;
    const Args = struct { a: []const u8, b: []const u8 };
    const Options = struct { verbose: bool = false };

    const result = try parseCommandLine(Args, Options, null, allocator, null, &.{ "--verbose", "-", "out" }, null);
    defer result.deinit();
    try std.testing.expect(result.options.verbose);
    try std.testing.expectEqualStrings("-", result.args.a);
    try std.testing.expectEqualStrings("out", result.args.b);
}

test "#299 a short value-option does not swallow a following flag" {
    const allocator = std.testing.allocator;
    const Options = struct {
        tag: ?[]const u8 = null,
        verbose: bool = false,
        pub const meta = .{ .options = .{ .tag = .{ .short = 't' } } };
    };

    // Previously tag="--verbose", verbose=false, no error. Must mirror the long
    // path (`--tag --verbose` → OptionMissingValue).
    var diag: ?ZcliDiagnostic = null;
    const result = parseCommandLine(struct {}, Options, Options.meta, allocator, null, &.{ "-t", "--verbose" }, &diag);
    try std.testing.expectError(ZcliError.OptionMissingValue, result);
}

test "#315 '-' is consistently an option value across --opt -, --opt=-, -o -" {
    const allocator = std.testing.allocator;
    const Options = struct {
        out: ?[]const u8 = null,
        pub const meta = .{ .options = .{ .out = .{ .short = 'o' } } };
    };

    inline for (.{
        &.{ "--out", "-" },
        &.{"--out=-"},
        &.{ "-o", "-" },
    }) |argv| {
        const result = try parseCommandLine(struct {}, Options, Options.meta, allocator, null, argv, null);
        defer result.deinit();
        try std.testing.expectEqualStrings("-", result.options.out.?);
    }
}

test "parseArgs failure after array options were parsed does not leak them" {
    const allocator = std.testing.allocator;

    const Args = struct { required: []const u8 };
    const Options = struct { files: []const []const u8 = &.{} };

    // Options parse first and accumulate two allocations; the missing
    // required positional then fails parseArgs. Under std.testing.allocator
    // the accumulated arrays must be freed on this error path — the leak
    // check at test exit is the regression assertion.
    try std.testing.expectError(
        ZcliError.ArgumentMissingRequired,
        parseCommandLine(Args, Options, null, allocator, null, &.{ "--files", "a.txt", "--files", "b.txt" }, null),
    );
}
