//! Post-parse command option and argument validation.
//!
//! Parsing owns token consumption, value conversion, and allocation. This
//! module owns the ordered policy sweep over those resolved values: required
//! options, dependencies, exclusivity, then field validation hooks.

const std = @import("std");
const options_parser = @import("options.zig");
const option_utils = @import("options/utils.zig");
const diagnostic_errors = @import("diagnostic_errors.zig");

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

test "firstMissingRequiredOption: satisfied by CLI, env, or config; else reported" {
    const Options = struct {
        region: []const u8,
        verbose: bool = false,
    };

    const none = [_]bool{ false, false };

    const miss = firstMissingRequiredOption(Options, null, none, none);
    try std.testing.expect(miss != null);
    try std.testing.expectEqualStrings("region", miss.?.name);
    try std.testing.expectEqualStrings("[]const u8", miss.?.expected_type);

    const provided = [_]bool{ true, false };
    try std.testing.expect(firstMissingRequiredOption(Options, null, provided, none) == null);

    const config_applied = [_]bool{ true, false };
    try std.testing.expect(firstMissingRequiredOption(Options, null, none, config_applied) == null);
}

test "firstMissingRequiredOption: reports the effective name and handles no required fields" {
    const Required = struct { output_file: []const u8 };
    const meta = .{ .options = .{ .output_file = .{ .name = "out" } } };
    const miss = firstMissingRequiredOption(Required, meta, .{false}, .{false});
    try std.testing.expect(miss != null);
    try std.testing.expectEqualStrings("out", miss.?.name);

    const Optional = struct { verbose: bool = false, name: ?[]const u8 = null };
    const none = [_]bool{ false, false };
    try std.testing.expect(firstMissingRequiredOption(Optional, null, none, none) == null);
}

test "firstMissingDependency: source tracking and effective names" {
    const Options = struct {
        output: ?[]const u8 = null,
        output_format: ?enum { pretty, compact } = null,
    };
    const meta = .{ .options = .{ .output_format = .{ .requires = .{.output} } } };
    const none = [_]bool{ false, false };

    const missing = firstMissingDependency(Options, meta, .{ false, true }, none);
    try std.testing.expect(missing != null);
    try std.testing.expectEqualStrings("output-format", missing.?.option_name);
    try std.testing.expectEqualStrings("output", missing.?.required_name);
    try std.testing.expect(firstMissingDependency(Options, meta, .{ true, true }, none) == null);
    try std.testing.expect(firstMissingDependency(Options, meta, .{ true, false }, none) == null);
    try std.testing.expect(firstMissingDependency(Options, meta, .{ false, true }, .{ true, false }) == null);

    const Custom = struct {
        out: ?[]const u8 = null,
        fmt: ?[]const u8 = null,
    };
    const custom_meta = .{ .options = .{
        .out = .{ .name = "output" },
        .fmt = .{ .requires = .{.out} },
    } };
    const custom_missing = firstMissingDependency(Custom, custom_meta, .{ false, true }, .{ false, false });
    try std.testing.expectEqualStrings("fmt", custom_missing.?.option_name);
    try std.testing.expectEqualStrings("output", custom_missing.?.required_name);
}

test "firstExclusiveViolation: declaration order and overlapping sets" {
    const Options = struct {
        json: bool = false,
        yaml: bool = false,
        xml: bool = false,
    };
    const meta = .{ .exclusive = .{.{ .json, .yaml, .xml }} };
    const none = [_]bool{ false, false, false };

    const violation = firstExclusiveViolation(Options, meta, .{ true, false, true }, none);
    try std.testing.expectEqualStrings("json", violation.?.first);
    try std.testing.expectEqualStrings("xml", violation.?.second);
    try std.testing.expect(firstExclusiveViolation(Options, meta, .{ false, true, false }, none) == null);
    try std.testing.expect(firstExclusiveViolation(Options, meta, none, none) == null);

    const overlapping = .{ .exclusive = .{ .{ .json, .yaml }, .{ .yaml, .xml } } };
    try std.testing.expect(firstExclusiveViolation(Options, overlapping, .{ true, false, true }, none) == null);
    const second = firstExclusiveViolation(Options, overlapping, .{ false, true, true }, none);
    try std.testing.expectEqualStrings("yaml", second.?.first);
    try std.testing.expectEqualStrings("xml", second.?.second);
}

test "firstOptionValidationError: ordering, optional fields, and effective names" {
    const V = struct {
        fn port(p: u16) ?[]const u8 {
            return if (p == 0) "must be between 1 and 65535" else null;
        }
        fn nonzero(n: u32) ?[]const u8 {
            return if (n == 0) "must not be zero" else null;
        }
        fn nonempty(s: []const u8) ?[]const u8 {
            return if (s.len == 0) "must not be empty" else null;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const PortOptions = struct { port: u16 = 8080 };
    const port_meta = .{ .options = .{ .port = .{ .validate = V.port } } };
    try std.testing.expect(firstOptionValidationError(allocator, PortOptions, port_meta, .{ .port = 8080 }) == null);
    const port_failure = firstOptionValidationError(allocator, PortOptions, port_meta, .{ .port = 0 });
    try std.testing.expectEqualStrings("port", port_failure.?.name);
    try std.testing.expectEqualStrings("must be between 1 and 65535", port_failure.?.reason);
    try std.testing.expectEqualStrings("0", port_failure.?.provided_value);

    const Optional = struct { limit: ?u32 = null };
    const optional_meta = .{ .options = .{ .limit = .{ .validate = V.nonzero } } };
    try std.testing.expect(firstOptionValidationError(allocator, Optional, optional_meta, .{ .limit = null }) == null);
    try std.testing.expect(firstOptionValidationError(allocator, Optional, optional_meta, .{ .limit = 5 }) == null);
    try std.testing.expect(firstOptionValidationError(allocator, Optional, optional_meta, .{ .limit = 0 }) != null);

    const Named = struct { output_dir: []const u8 = "" };
    const named_meta = .{ .options = .{ .output_dir = .{ .name = "out", .validate = V.nonempty } } };
    const named_failure = firstOptionValidationError(allocator, Named, named_meta, .{ .output_dir = "" });
    try std.testing.expectEqualStrings("out", named_failure.?.name);
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
    const allocator = arena.allocator();

    try std.testing.expect(firstArgValidationError(allocator, Args, meta, .{ .name = "x", .count = 3 }) == null);
    const failure = firstArgValidationError(allocator, Args, meta, .{ .name = "x", .count = 99 });
    try std.testing.expectEqualStrings("count", failure.?.name);
    try std.testing.expectEqualStrings("must be 10 or less", failure.?.reason);
    try std.testing.expectEqualStrings("99", failure.?.provided_value);
    try std.testing.expectEqual(@as(usize, 1), failure.?.position);

    const bare_meta = .{ .args = .{ .name = "just a description" } };
    try std.testing.expect(firstArgValidationError(allocator, Args, bare_meta, .{ .name = "", .count = 0 }) == null);
}
