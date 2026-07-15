const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const option_utils = @import("options/utils.zig");
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

        // Handle options. `isOption` (options/utils.zig — the single source of
        // truth) excludes negative numbers (`-.5`, `-inf`) and the bare `-`
        // stdin/stdout sentinel, which are positionals, not flags.
        if (option_utils.isOption(arg)) {
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
                    if (takes_value and i + 1 < args.len and option_utils.isValueToken(args[i + 1])) {
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
                    // A following flag is not this short option's value — same
                    // "next token is a value" rule the long path uses (#299).
                    if (takes_value and i + 1 < args.len and option_utils.isValueToken(args[i + 1])) {
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
    const options_res = try parseOptionsFromArgs(OptionsType, meta, allocator, environ, option_args.items, diag);
    const options = options_res.options;

    // Parse positional arguments
    // Note: We need to keep positional_args.items alive for the lifetime of the result
    // because parseArgs may create references to the input slice (for varargs)
    const positional_slice = positional_args.toOwnedSlice(allocator) catch return ZcliError.SystemOutOfMemory;
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

/// A required option that no value source supplied — reported to the user via
/// the `OptionMissingRequired` diagnostic. `name` is the option's effective long
/// flag name (custom `meta.options.<field>.name` or dashed field name).
pub const MissingRequiredOption = struct {
    name: []const u8,
    expected_type: []const u8,
};

/// The first required option (in field order) that no source supplied, or null.
///
/// A required option — see `option_utils.isRequiredOption` — has no meaning when
/// absent, so exactly one of these must hold for it: env or CLI set it
/// (`provided[i]`), or the config pass filled it (`config_applied[i]`, reported
/// by the config plugin's applyConfigDefaults). Explicit bitsets, not a value
/// diff — a config value equal to the required-option placeholder (0, the first
/// enum variant) is still supplied (#388). Called by the registry after the
/// config pass.
pub fn firstMissingRequiredOption(
    comptime OptionsType: type,
    comptime meta: anytype,
    provided: [options_parser.optionFieldCount(OptionsType)]bool,
    config_applied: [options_parser.optionFieldCount(OptionsType)]bool,
) ?MissingRequiredOption {
    const info = @typeInfo(OptionsType);
    if (info != .@"struct") return null;
    inline for (info.@"struct".fields, 0..) |field, i| {
        if (comptime option_utils.isRequiredOption(field)) {
            if (!provided[i] and !config_applied[i]) {
                return .{
                    .name = comptime option_utils.effectiveLongName(meta, field.name),
                    .expected_type = diagnostic_errors.expectedTypeName(field.type),
                };
            }
        }
    }
    return null;
}

/// The field index of `name` in `OptionsType` (comptime). Constraint names are
/// validated with `@hasField` at build time, so this always resolves here.
fn fieldIndex(comptime OptionsType: type, comptime name: []const u8) usize {
    inline for (@typeInfo(OptionsType).@"struct".fields, 0..) |field, i| {
        if (comptime std.mem.eql(u8, field.name, name)) return i;
    }
    @compileError("no Options field named '" ++ name ++ "'");
}

/// A supplied option whose `meta.options.<field>.requires` dependency was not
/// supplied. Names are effective long flag names (custom `.name` or dashed
/// field name), static lifetime.
pub const MissingDependency = struct {
    option_name: []const u8,
    required_name: []const u8,
};

/// The first unmet `requires` dependency (in field order, then dependency
/// order), or null. A field's dependencies are enforced only when the field
/// itself was supplied; each dependency must then be supplied by some source.
/// Runs beside `firstMissingRequiredOption`, over the same `options_provided`
/// and `config_applied` bitsets ("supplied" = either flag; the same explicit
/// notion `firstMissingRequiredOption` uses).
pub fn firstMissingDependency(
    comptime OptionsType: type,
    comptime meta: anytype,
    provided: [options_parser.optionFieldCount(OptionsType)]bool,
    config_applied: [options_parser.optionFieldCount(OptionsType)]bool,
) ?MissingDependency {
    const info = @typeInfo(OptionsType);
    if (info != .@"struct") return null;
    inline for (info.@"struct".fields, 0..) |field, i| {
        if (comptime option_utils.requiresFor(meta, field.name)) |req_list| {
            if (provided[i] or config_applied[i]) {
                inline for (req_list) |dep| {
                    const dep_i = comptime fieldIndex(OptionsType, dep);
                    if (!(provided[dep_i] or config_applied[dep_i])) {
                        return .{
                            .option_name = comptime option_utils.effectiveLongName(meta, field.name),
                            .required_name = comptime option_utils.effectiveLongName(meta, dep),
                        };
                    }
                }
            }
        }
    }
    return null;
}

/// Two members of a `meta.exclusive` set that were both supplied. Names are
/// effective long flag names, static lifetime.
pub const MutuallyExclusive = struct {
    first: []const u8,
    second: []const u8,
};

/// The first `meta.exclusive` set with two or more supplied members (reporting
/// the first two in declaration order), or null. Runs beside
/// `firstMissingRequiredOption`, after `requires`, over the same
/// `options_provided` and `config_applied` bitsets.
pub fn firstExclusiveViolation(
    comptime OptionsType: type,
    comptime meta: anytype,
    provided: [options_parser.optionFieldCount(OptionsType)]bool,
    config_applied: [options_parser.optionFieldCount(OptionsType)]bool,
) ?MutuallyExclusive {
    const sets = comptime option_utils.exclusiveSets(meta);
    inline for (sets) |set| {
        var first_name: ?[]const u8 = null;
        inline for (set) |member| {
            const idx = comptime fieldIndex(OptionsType, member);
            if (provided[idx] or config_applied[idx]) {
                const eff = comptime option_utils.effectiveLongName(meta, member);
                if (first_name) |f| return .{ .first = f, .second = eff };
                first_name = eff;
            }
        }
    }
    return null;
}

/// A field whose `validate` hook rejected the resolved value. `name` is the
/// effective long flag name (options) or field name (args); `provided_value` is
/// the rejected value rendered to a string (for the "Invalid value 'X'" clause);
/// `reason` is the author's message; `position` is the 0-based positional index
/// for args.
pub const ValidationFailure = struct {
    name: []const u8,
    reason: []const u8,
    provided_value: []const u8 = "",
    position: usize = 0,
};

/// Render a validated value to a string for the diagnostic. Strings pass through
/// as-is; enums via `@tagName`; scalars are formatted. The result lives on
/// `allocator` (an arena in practice, like the rendered diagnostic message) or is
/// static — never individually freed.
fn renderValidatedValue(allocator: std.mem.Allocator, comptime T: type, value: T) []const u8 {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.child == u8) value else (std.fmt.allocPrint(allocator, "{any}", .{value}) catch "?"),
        .@"enum" => @tagName(value),
        .int, .float => std.fmt.allocPrint(allocator, "{d}", .{value}) catch "?",
        .bool => if (value) "true" else "false",
        else => std.fmt.allocPrint(allocator, "{any}", .{value}) catch "?",
    };
}

/// The first Options field whose `meta.options.<field>.validate` rejected the
/// resolved value (in field order), or null. Runs after required/requires/
/// exclusive, on the final value from any source; a `?T` field is validated
/// only when a value is present (null is skipped, since absence is governed by
/// required/optional, not by the value hook).
pub fn firstOptionValidationError(
    allocator: std.mem.Allocator,
    comptime OptionsType: type,
    comptime meta: anytype,
    options: OptionsType,
) ?ValidationFailure {
    const info = @typeInfo(OptionsType);
    if (info != .@"struct") return null;
    inline for (info.@"struct".fields) |field| {
        if (comptime option_utils.hasValidate(meta, field.name)) {
            const validate_fn = @field(meta.options, field.name).validate;
            const value = @field(options, field.name);
            switch (@typeInfo(field.type)) {
                .optional => if (value) |v| {
                    if (validate_fn(v)) |r| return .{
                        .name = comptime option_utils.effectiveLongName(meta, field.name),
                        .reason = r,
                        .provided_value = renderValidatedValue(allocator, @TypeOf(v), v),
                    };
                },
                else => if (validate_fn(value)) |r| return .{
                    .name = comptime option_utils.effectiveLongName(meta, field.name),
                    .reason = r,
                    .provided_value = renderValidatedValue(allocator, field.type, value),
                },
            }
        }
    }
    return null;
}

/// The first positional Args field whose `meta.args.<field>.validate` rejected
/// the parsed value (in positional order), or null. Same value-hook semantics as
/// options; `position` is the 0-based field index for the diagnostic.
pub fn firstArgValidationError(
    allocator: std.mem.Allocator,
    comptime ArgsType: type,
    comptime meta: anytype,
    args: ArgsType,
) ?ValidationFailure {
    const info = @typeInfo(ArgsType);
    if (info != .@"struct") return null;
    inline for (info.@"struct".fields, 0..) |field, i| {
        if (comptime option_utils.hasValidateArg(meta, field.name)) {
            const validate_fn = @field(meta.args, field.name).validate;
            const value = @field(args, field.name);
            switch (@typeInfo(field.type)) {
                .optional => if (value) |v| {
                    if (validate_fn(v)) |r| return .{
                        .name = field.name,
                        .reason = r,
                        .provided_value = renderValidatedValue(allocator, @TypeOf(v), v),
                        .position = i,
                    };
                },
                else => if (validate_fn(value)) |r| return .{
                    .name = field.name,
                    .reason = r,
                    .provided_value = renderValidatedValue(allocator, field.type, value),
                    .position = i,
                },
            }
        }
    }
    return null;
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

test "firstMissingRequiredOption: satisfied by CLI, env, or config; else reported" {
    const Options = struct {
        region: []const u8, // required
        verbose: bool = false,
    };

    const none = [_]bool{ false, false };

    // Nothing set it and config didn't fill it → missing.
    {
        const miss = firstMissingRequiredOption(Options, null, none, none);
        try std.testing.expect(miss != null);
        try std.testing.expectEqualStrings("region", miss.?.name);
        try std.testing.expectEqualStrings("[]const u8", miss.?.expected_type);
    }
    // env or CLI set it (provided[0] = true) → satisfied.
    {
        const provided = [_]bool{ true, false };
        try std.testing.expect(firstMissingRequiredOption(Options, null, provided, none) == null);
    }
    // Config filled it (config_applied[0] = true) → satisfied, even if the
    // value it wrote equals the required-option placeholder (#388).
    {
        const config_applied = [_]bool{ true, false };
        try std.testing.expect(firstMissingRequiredOption(Options, null, none, config_applied) == null);
    }
}

test "firstMissingRequiredOption: reports the effective (custom) flag name" {
    const Options = struct { output_file: []const u8 };
    const meta = .{ .options = .{ .output_file = .{ .name = "out" } } };
    const none = [_]bool{false};
    const miss = firstMissingRequiredOption(Options, meta, none, none);
    try std.testing.expect(miss != null);
    try std.testing.expectEqualStrings("out", miss.?.name);
}

test "firstMissingRequiredOption: no required fields is never missing" {
    const Options = struct { verbose: bool = false, name: ?[]const u8 = null };
    const none = [_]bool{ false, false };
    try std.testing.expect(firstMissingRequiredOption(Options, null, none, none) == null);
}

test "firstMissingDependency: enforced only when the dependent option is supplied" {
    const Options = struct {
        output: ?[]const u8 = null,
        output_format: ?enum { pretty, compact } = null,
    };
    const meta = .{ .options = .{ .output_format = .{ .requires = .{.output} } } };
    const none = [_]bool{ false, false };

    // output_format supplied, output not → violation.
    {
        const provided = [_]bool{ false, true };
        const miss = firstMissingDependency(Options, meta, provided, none);
        try std.testing.expect(miss != null);
        try std.testing.expectEqualStrings("output-format", miss.?.option_name);
        try std.testing.expectEqualStrings("output", miss.?.required_name);
    }
    // Both supplied → satisfied.
    {
        const provided = [_]bool{ true, true };
        try std.testing.expect(firstMissingDependency(Options, meta, provided, none) == null);
    }
    // Dependent option absent → dependency not enforced.
    {
        const provided = [_]bool{ true, false };
        try std.testing.expect(firstMissingDependency(Options, meta, provided, none) == null);
    }
    // Dependency satisfied by config (config_applied flag).
    {
        const provided = [_]bool{ false, true };
        const config_applied = [_]bool{ true, false };
        try std.testing.expect(firstMissingDependency(Options, meta, provided, config_applied) == null);
    }
}

test "firstMissingDependency: reports effective (custom/dashed) flag names" {
    const Options = struct {
        out: ?[]const u8 = null,
        fmt: ?[]const u8 = null,
    };
    const meta = .{ .options = .{
        .out = .{ .name = "output" },
        .fmt = .{ .requires = .{.out} },
    } };
    const none = [_]bool{ false, false };
    const provided = [_]bool{ false, true };
    const miss = firstMissingDependency(Options, meta, provided, none);
    try std.testing.expect(miss != null);
    try std.testing.expectEqualStrings("fmt", miss.?.option_name);
    // The dependency reports its custom flag name, not the field name.
    try std.testing.expectEqualStrings("output", miss.?.required_name);
}

test "firstExclusiveViolation: at most one member of a set may be supplied" {
    const Options = struct {
        json: bool = false,
        yaml: bool = false,
        xml: bool = false,
    };
    const meta = .{ .exclusive = .{.{ .json, .yaml, .xml }} };
    const none = [_]bool{ false, false, false };

    // Two members supplied → violation, reporting them in declaration order.
    {
        const provided = [_]bool{ true, false, true }; // json + xml
        const ex = firstExclusiveViolation(Options, meta, provided, none);
        try std.testing.expect(ex != null);
        try std.testing.expectEqualStrings("json", ex.?.first);
        try std.testing.expectEqualStrings("xml", ex.?.second);
    }
    // Exactly one supplied → fine.
    {
        const provided = [_]bool{ false, true, false };
        try std.testing.expect(firstExclusiveViolation(Options, meta, provided, none) == null);
    }
    // None supplied → fine.
    {
        try std.testing.expect(firstExclusiveViolation(Options, meta, none, none) == null);
    }
}

test "firstExclusiveViolation: overlapping sets are checked independently" {
    // a⊥b and b⊥c, but a+c is legal (non-clique graph, ADR example).
    const Options = struct {
        a: bool = false,
        b: bool = false,
        c: bool = false,
    };
    const meta = .{ .exclusive = .{ .{ .a, .b }, .{ .b, .c } } };
    const none = [_]bool{ false, false, false };

    // a + c: neither set has two supplied members → legal.
    {
        const provided = [_]bool{ true, false, true };
        try std.testing.expect(firstExclusiveViolation(Options, meta, provided, none) == null);
    }
    // b + c: violates the second set.
    {
        const provided = [_]bool{ false, true, true };
        const ex = firstExclusiveViolation(Options, meta, provided, none);
        try std.testing.expect(ex != null);
        try std.testing.expectEqualStrings("b", ex.?.first);
        try std.testing.expectEqualStrings("c", ex.?.second);
    }
}

test "firstOptionValidationError: reports the first field the hook rejects" {
    const V = struct {
        fn port(p: u16) ?[]const u8 {
            return if (p == 0) "must be between 1 and 65535" else null;
        }
    };
    const Options = struct { port: u16 = 8080 };
    const meta = .{ .options = .{ .port = .{ .validate = V.port } } };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A valid value (from any source — the sweep sees only the final value).
    try std.testing.expect(firstOptionValidationError(a, Options, meta, .{ .port = 8080 }) == null);

    // An invalid value → failure carrying the reason, flag name, and rendered value.
    const f = firstOptionValidationError(a, Options, meta, .{ .port = 0 });
    try std.testing.expect(f != null);
    try std.testing.expectEqualStrings("port", f.?.name);
    try std.testing.expectEqualStrings("must be between 1 and 65535", f.?.reason);
    try std.testing.expectEqualStrings("0", f.?.provided_value);
}

test "firstOptionValidationError: optional field is validated only when present" {
    const V = struct {
        fn nonzero(n: u32) ?[]const u8 {
            return if (n == 0) "must not be zero" else null;
        }
    };
    const Options = struct { limit: ?u32 = null };
    const meta = .{ .options = .{ .limit = .{ .validate = V.nonzero } } };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expect(firstOptionValidationError(a, Options, meta, .{ .limit = null }) == null);
    try std.testing.expect(firstOptionValidationError(a, Options, meta, .{ .limit = 5 }) == null);
    try std.testing.expect(firstOptionValidationError(a, Options, meta, .{ .limit = 0 }) != null);
}

test "firstOptionValidationError: reports the effective (custom) flag name" {
    const V = struct {
        fn nonempty(s: []const u8) ?[]const u8 {
            return if (s.len == 0) "must not be empty" else null;
        }
    };
    const Options = struct { output_dir: []const u8 = "" };
    const meta = .{ .options = .{ .output_dir = .{ .name = "out", .validate = V.nonempty } } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = firstOptionValidationError(arena.allocator(), Options, meta, .{ .output_dir = "" });
    try std.testing.expect(f != null);
    try std.testing.expectEqualStrings("out", f.?.name);
}

test "firstArgValidationError: reports the field, reason, and position" {
    const V = struct {
        fn nonempty(s: []const u8) ?[]const u8 {
            return if (s.len == 0) "must not be empty" else null;
        }
        fn small(n: u8) ?[]const u8 {
            return if (n > 10) "must be 10 or less" else null;
        }
    };
    const Args = struct { name: []const u8, count: u8 };
    const meta = .{ .args = .{
        .name = .{ .validate = V.nonempty },
        .count = .{ .description = "how many", .validate = V.small },
    } };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // All valid.
    try std.testing.expect(firstArgValidationError(a, Args, meta, .{ .name = "x", .count = 3 }) == null);

    // Second positional rejected → position 1 (0-based), reported after name passes.
    const f = firstArgValidationError(a, Args, meta, .{ .name = "x", .count = 99 });
    try std.testing.expect(f != null);
    try std.testing.expectEqualStrings("count", f.?.name);
    try std.testing.expectEqualStrings("must be 10 or less", f.?.reason);
    try std.testing.expectEqualStrings("99", f.?.provided_value);
    try std.testing.expectEqual(@as(usize, 1), f.?.position);

    // Bare-string arg meta (no validate) is simply skipped.
    const meta2 = .{ .args = .{ .name = "just a description" } };
    try std.testing.expect(firstArgValidationError(a, Args, meta2, .{ .name = "", .count = 0 }) == null);
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
