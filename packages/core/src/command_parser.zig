const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const option_utils = @import("options/utils.zig");
const tokenizer = @import("options/tokenizer.zig");
const diagnostic_errors = @import("diagnostic_errors.zig");
const command_validation = @import("command_validation.zig");

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

// Post-parse policy lives behind a separate seam. These aliases preserve the
// command_parser interface used by the generated registry and existing callers.
pub const MissingRequiredOption = command_validation.MissingRequiredOption;
pub const firstMissingRequiredOption = command_validation.firstMissingRequiredOption;

/// One flag per Options field (field-declaration order — the same keying as
/// `options_provided`), true where `meta.options.<field>.no_config` locks the
/// field against config files (ADR-0032). Fully comptime; all false, and every
/// branch guarded by it folded away, unless a field carries the marker.
pub fn noConfigMask(
    comptime OptionsType: type,
    comptime meta: anytype,
) [options_parser.optionFieldCount(OptionsType)]bool {
    // `return comptime blk:` rather than a `comptime { … }` body, matching
    // `option_utils.exclusiveSets` — the established idiom here for a helper
    // whose whole result is folded at compile time.
    return comptime blk: {
        var mask = [_]bool{false} ** options_parser.optionFieldCount(OptionsType);
        const info = @typeInfo(OptionsType);
        if (info == .@"struct") {
            for (info.@"struct".fields, 0..) |field, i| {
                mask[i] = option_utils.isNoConfig(meta, field.name);
            }
        }
        break :blk mask;
    };
}

/// The `provided` view to hand `applyConfigDefaults` hooks: the real CLI/env
/// bitset with every `no_config` field forced true (ADR-0032).
///
/// This is the *primary* enforcement of the marker, and it deliberately adds no
/// new obligation: every hook already owes the framework "skip any field whose
/// `provided` flag is true" — that single check is what makes CLI > env > config
/// hold — so a locked field is skipped by the machinery a conforming hook has
/// already implemented. A third-party config source gets the guarantee for free,
/// which is why this lives here and not inside `zcli_config`.
///
/// The caller keeps the real bitset for the required/constraint checks, so a
/// locked field still reads as unsupplied unless the CLI or env truly supplied
/// it — a locked *required* option correctly reports "missing" rather than
/// silently taking a config value.
pub fn maskNoConfig(
    comptime OptionsType: type,
    comptime meta: anytype,
    provided: [options_parser.optionFieldCount(OptionsType)]bool,
) [options_parser.optionFieldCount(OptionsType)]bool {
    const mask = comptime noConfigMask(OptionsType, meta);
    var masked = provided;
    inline for (mask, 0..) |locked, i| {
        if (locked) masked[i] = true;
    }
    return masked;
}

/// Does any field of `OptionsType` carry the `no_config` marker? Comptime, and
/// false for the overwhelming majority of commands — which is what lets
/// `NoConfigSnapshot` erase the backstop's cost entirely rather than merely
/// making its branches dead.
pub fn anyNoConfig(comptime OptionsType: type, comptime meta: anytype) bool {
    return comptime blk: {
        for (noConfigMask(OptionsType, meta)) |locked| {
            if (locked) break :blk true;
        }
        break :blk false;
    };
}

/// What `captureNoConfig` hands `restoreNoConfig`: the options struct when some
/// field is marked, and `void` when none is.
///
/// The `void` case is the point. An unconditional `const before = options` would
/// copy the whole struct on every command invocation to serve a marker almost no
/// command uses — a real cost on a path this repo gates with a startup-time and
/// binary-size budget, and not something a dead `if` removes, since the copy
/// happens before any branch. Making the *type* zero-sized removes the copy
/// itself.
pub fn NoConfigSnapshot(comptime OptionsType: type, comptime meta: anytype) type {
    return if (anyNoConfig(OptionsType, meta)) OptionsType else void;
}

/// Take the pre-config snapshot `restoreNoConfig` restores from. Compiles to
/// nothing when no field is marked (the snapshot type is `void`); otherwise it
/// is one copy of the options struct, paid only by commands that use the marker.
pub fn captureNoConfig(
    comptime OptionsType: type,
    comptime meta: anytype,
    options: OptionsType,
) NoConfigSnapshot(OptionsType, meta) {
    if (comptime !anyNoConfig(OptionsType, meta)) return {};
    return options;
}

/// Undo any write an `applyConfigDefaults` hook made to a `no_config` field:
/// restore the pre-hook value from `before` and clear its `config_applied` flag.
///
/// The backstop to `maskNoConfig`. A hook that honors `provided` never touches a
/// locked field and this is a no-op; a hook that ignores it cannot make the
/// marker a lie. Without this the marker would be advisory — exactly the
/// weakness in relying on a doc comment that #788 set out to remove.
///
/// `before` comes from `captureNoConfig` and holds the options as they stood
/// after CLI/env parsing, so restoring is a plain assignment of the value that
/// was already correct. Clearing the applied flag matters as much as the value:
/// leaving it set would tell the required-option check that a locked field had
/// been supplied.
///
/// Restoring *orphans* rather than frees whatever a rogue hook wrote. It has to:
/// a slice field's current value may be the hook's allocation or the struct's
/// own comptime default, and nothing here can tell them apart, so freeing risks
/// an invalid free. Under the framework's arena-per-command (ADR-0001) — which
/// is what the registry always uses, and what the config plugin allocates
/// coerced arrays from — the orphan is reclaimed wholesale. A conforming hook
/// never allocates for a locked field in the first place, because `maskNoConfig`
/// made it skip.
pub fn restoreNoConfig(
    comptime OptionsType: type,
    comptime meta: anytype,
    options: *OptionsType,
    before: NoConfigSnapshot(OptionsType, meta),
    config_applied: *[options_parser.optionFieldCount(OptionsType)]bool,
) void {
    if (comptime !anyNoConfig(OptionsType, meta)) return;
    const mask = comptime noConfigMask(OptionsType, meta);
    inline for (@typeInfo(OptionsType).@"struct".fields, 0..) |field, i| {
        if (mask[i]) {
            @field(options, field.name) = @field(before, field.name);
            config_applied[i] = false;
        }
    }
}

pub const MissingDependency = command_validation.MissingDependency;
pub const firstMissingDependency = command_validation.firstMissingDependency;
pub const MutuallyExclusive = command_validation.MutuallyExclusive;
pub const firstExclusiveViolation = command_validation.firstExclusiveViolation;
pub const ValidationFailure = command_validation.ValidationFailure;
pub const firstOptionValidationError = command_validation.firstOptionValidationError;
pub const firstArgValidationError = command_validation.firstArgValidationError;

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

test "noConfigMask: marks exactly the fields carrying meta.<field>.no_config" {
    const Options = struct {
        verbose: bool = false,
        skip_verification: bool = false,
        registry: []const u8 = "default",
    };
    const meta = .{
        .options = .{
            .skip_verification = .{ .no_config = true },
            // `false` is a legitimate no-op, not a lock — a computed marker has to
            // read the way it looks.
            .registry = .{ .description = "registry URL", .no_config = false },
        },
    };

    const mask = noConfigMask(Options, meta);
    try std.testing.expectEqual(false, mask[0]);
    try std.testing.expectEqual(true, mask[1]);
    try std.testing.expectEqual(false, mask[2]);

    // A command with no meta at all locks nothing.
    const bare = noConfigMask(Options, null);
    for (bare) |locked| try std.testing.expectEqual(false, locked);
}

test "maskNoConfig: hides a locked field from the hook without touching the real bitset" {
    const Options = struct {
        verbose: bool = false,
        skip_verification: bool = false,
    };
    const meta = .{ .options = .{ .skip_verification = .{ .no_config = true } } };

    const provided = [_]bool{ false, false }; // neither supplied by CLI/env
    const masked = maskNoConfig(Options, meta, provided);

    // The hook sees the locked field as already supplied, so its precedence
    // check skips it; the unlocked field is still fair game.
    try std.testing.expectEqual(false, masked[0]);
    try std.testing.expectEqual(true, masked[1]);

    // The caller's bitset is untouched — the required/constraint checks must
    // keep seeing that nothing was actually supplied.
    try std.testing.expectEqual(false, provided[1]);
}

test "restoreNoConfig: undoes a hook that wrote to a locked field anyway" {
    const Options = struct {
        verbose: bool = false,
        skip_verification: bool = false,
    };
    const meta = .{ .options = .{ .skip_verification = .{ .no_config = true } } };

    const before = captureNoConfig(Options, meta, .{ .verbose = false, .skip_verification = false });
    // A non-conforming hook that ignored `provided` and set both fields.
    var options: Options = .{ .verbose = true, .skip_verification = true };
    var applied = [_]bool{ true, true };

    restoreNoConfig(Options, meta, &options, before, &applied);

    // The locked field is back to its pre-config value and no longer counts as
    // supplied; the unlocked field's config value stands.
    try std.testing.expectEqual(false, options.skip_verification);
    try std.testing.expectEqual(false, applied[1]);
    try std.testing.expectEqual(true, options.verbose);
    try std.testing.expectEqual(true, applied[0]);
}

test "restoreNoConfig: no-op when nothing is marked, and the snapshot is zero-sized" {
    const Options = struct { count: u32 = 1 };

    // The cost claim, pinned as a type-level fact rather than asserted in prose:
    // with no marker the snapshot is `void`, so the registry takes no copy at
    // all (as opposed to taking one that a dead branch then ignores).
    try std.testing.expectEqual(void, NoConfigSnapshot(Options, .{}));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(NoConfigSnapshot(Options, .{})));
    try std.testing.expectEqual(false, anyNoConfig(Options, .{}));

    const before = captureNoConfig(Options, .{}, .{ .count = 1 });
    var options: Options = .{ .count = 7 };
    var applied = [_]bool{true};

    restoreNoConfig(Options, .{}, &options, before, &applied);

    // A config-sourced value on an unmarked field survives untouched.
    try std.testing.expectEqual(@as(u32, 7), options.count);
    try std.testing.expectEqual(true, applied[0]);
}

test "NoConfigSnapshot: a marked field makes the snapshot the options struct" {
    const Options = struct {
        verbose: bool = false,
        skip_verification: bool = false,
    };
    const meta = .{ .options = .{ .skip_verification = .{ .no_config = true } } };

    try std.testing.expectEqual(true, anyNoConfig(Options, meta));
    try std.testing.expectEqual(Options, NoConfigSnapshot(Options, meta));

    // `.no_config = false` is a no-op, so it must NOT make the command pay for
    // the snapshot — the marker's cost tracks real use, not mere mention.
    const inert = .{ .options = .{ .skip_verification = .{ .no_config = false } } };
    try std.testing.expectEqual(false, anyNoConfig(Options, inert));
    try std.testing.expectEqual(void, NoConfigSnapshot(Options, inert));
}

/// A deliberately non-conforming `applyConfigDefaults`: it ignores `provided`
/// entirely and stamps every field it can. Exists so the backstop is proven by
/// RUNNING a hook like this, not by reading `restoreNoConfig` and believing it —
/// nothing in the hook contract can stop such a plugin being written, which is
/// the whole reason layer 2 exists.
///
/// It lives here rather than in plugin_config_integration_test.zig for a module
/// reason: that file imports the config plugin's source, so it is built with the
/// "zcli" module, and `zcli.zig` already contains this file — importing this
/// file relatively from there would put one file in two modules, which Zig
/// rejects outright. The rogue hook needs no plugin anyway, only the helpers it
/// must not be able to defeat.
const RogueConfigHook = struct {
    fn applyConfigDefaults(
        comptime OptionsType: type,
        options: *OptionsType,
        provided: []const bool,
        applied: []bool,
    ) void {
        _ = provided; // the bug being modelled
        inline for (@typeInfo(OptionsType).@"struct".fields, 0..) |field, i| {
            if (field.type == bool) {
                @field(options, field.name) = true;
                applied[i] = true;
            } else if (field.type == []const u8) {
                @field(options, field.name) = "https://evil.example";
                applied[i] = true;
            }
        }
    }
};

test "no_config: a rogue hook that ignores `provided` cannot write a locked field" {
    const Options = struct {
        skip_verification: bool = false,
        registry: []const u8 = "https://trusted.example",
        verbose: bool = false,
    };
    const meta = .{ .options = .{
        .skip_verification = .{ .no_config = true },
        .registry = .{ .no_config = true },
    } };

    var options: Options = .{};
    var applied = [_]bool{false} ** 3;
    const provided = [_]bool{false} ** 3;

    // The registry's exact sequence, with the rogue hook standing in.
    const hook_provided = maskNoConfig(Options, meta, provided);
    const before = captureNoConfig(Options, meta, options);
    RogueConfigHook.applyConfigDefaults(Options, &options, &hook_provided, &applied);

    // Layer 1 did not save us — this hook never looked at `provided`.
    try std.testing.expectEqual(true, options.skip_verification);
    try std.testing.expectEqualStrings("https://evil.example", options.registry);

    restoreNoConfig(Options, meta, &options, before, &applied);

    // Layer 2 did: values back to the pre-config ones, and the applied flags
    // cleared so nothing downstream believes the fields were supplied.
    try std.testing.expectEqual(false, options.skip_verification);
    try std.testing.expectEqualStrings("https://trusted.example", options.registry);
    try std.testing.expect(!applied[0]);
    try std.testing.expect(!applied[1]);

    // The unmarked field keeps the hook's write — the backstop is targeted, not
    // a blanket rollback of everything a misbehaving plugin did.
    try std.testing.expectEqual(true, options.verbose);
    try std.testing.expect(applied[2]);
}

test "no_config: a locked REQUIRED option supplied only by config still reports missing" {
    // The subtlest interaction in ADR-0032. Both options are required (no
    // default, non-optional, non-bool, non-array); only `signing_key` is locked.
    const Options = struct {
        signing_key: []const u8,
        project: []const u8,
    };
    const meta = .{ .options = .{ .signing_key = .{ .no_config = true } } };

    // Nothing came from CLI or env. This is the REAL bitset — the registry never
    // overwrites it with the masked view, precisely so this check sees the truth.
    const provided = [_]bool{ false, false };

    // A config pass that filled the unlocked field and (correctly) skipped the
    // locked one: exactly the report the masked view produces.
    const config_applied = [_]bool{ false, true };

    const missing = firstMissingRequiredOption(Options, meta, provided, config_applied);
    try std.testing.expect(missing != null);
    // Reported by effective long name, so the user sees the flag they would type.
    try std.testing.expectEqualStrings("signing-key", missing.?.name);

    // Control: had the field not been locked, that same config value would have
    // satisfied it — so the marker is what changes the outcome, not the fixture.
    const both_applied = [_]bool{ true, true };
    try std.testing.expect(firstMissingRequiredOption(Options, meta, provided, both_applied) == null);

    // And CLI/env still satisfy a locked required option, which is the point:
    // the value has to come from somewhere the user controls.
    const from_cli = [_]bool{ true, false };
    try std.testing.expect(firstMissingRequiredOption(Options, meta, from_cli, config_applied) == null);
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
