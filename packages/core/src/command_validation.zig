//! Resolved command-input policy.
//!
//! Parsing owns token consumption, value conversion, and allocation. This
//! module owns config-source precedence around `applyConfigDefaults` adapters
//! and the ordered policy sweep over the resulting values: required options,
//! dependencies, exclusivity, then field validation hooks.

const std = @import("std");
const options_parser = @import("options.zig");
const option_utils = @import("options/utils.zig");
const diagnostic_errors = @import("diagnostic_errors.zig");

const ZcliDiagnostic = diagnostic_errors.ZcliDiagnostic;
const ZcliError = diagnostic_errors.ZcliError;

/// One flag per Options field (field-declaration order — the same keying as
/// `options_provided`), true where `meta.options.<field>.no_config` locks the
/// field against config files (ADR-0032). Fully comptime; all false, and every
/// branch guarded by it folded away, unless a field carries the marker.
fn noConfigMask(
    comptime OptionsType: type,
    comptime meta: anytype,
) [options_parser.optionFieldCount(OptionsType)]bool {
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

/// The `provided` view handed to config adapters: the real CLI/env bitset with
/// every `no_config` field forced true. The real bitset stays unchanged for the
/// required and constraint checks that follow config application.
fn maskNoConfig(
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

fn anyNoConfig(comptime OptionsType: type, comptime meta: anytype) bool {
    return comptime blk: {
        for (noConfigMask(OptionsType, meta)) |locked| {
            if (locked) break :blk true;
        }
        break :blk false;
    };
}

/// The options struct when any field is locked, and `void` otherwise. Making
/// the type zero-sized in the common case prevents an unconditional options
/// struct copy on the registry's startup- and binary-size-budgeted path.
fn NoConfigSnapshot(comptime OptionsType: type, comptime meta: anytype) type {
    return if (anyNoConfig(OptionsType, meta)) OptionsType else void;
}

fn captureNoConfig(
    comptime OptionsType: type,
    comptime meta: anytype,
    options: OptionsType,
) NoConfigSnapshot(OptionsType, meta) {
    if (comptime !anyNoConfig(OptionsType, meta)) return {};
    return options;
}

/// Restore any `no_config` field a non-conforming adapter wrote and clear its
/// applied flag. The overwritten value is deliberately orphaned, not freed:
/// its ownership cannot be distinguished from a comptime default here, and the
/// registry's command arena reclaims it wholesale (ADR-0001/ADR-0032).
fn restoreNoConfig(
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

/// Apply every registered config adapter in priority order under the framework's
/// source-precedence policy. Adapters share one `config_applied` bitset, so an
/// earlier adapter wins over a later one; CLI/env values and `no_config` fields
/// are masked as already supplied. The restore pass makes `no_config` a
/// guarantee even when an adapter ignores the existing `provided` contract.
pub fn applyConfigAdapters(
    comptime OptionsType: type,
    comptime meta: anytype,
    comptime plugins: []const type,
    context: anytype,
    options: *OptionsType,
    provided: [options_parser.optionFieldCount(OptionsType)]bool,
) [options_parser.optionFieldCount(OptionsType)]bool {
    const hook_provided = maskNoConfig(OptionsType, meta, provided);
    const before_config = captureNoConfig(OptionsType, meta, options.*);
    var config_applied = [_]bool{false} ** options_parser.optionFieldCount(OptionsType);

    inline for (plugins) |Plugin| {
        if (@hasDecl(Plugin, "applyConfigDefaults")) {
            Plugin.applyConfigDefaults(context, OptionsType, options, &hook_provided, &config_applied);
        }
    }

    restoreNoConfig(OptionsType, meta, options, before_config, &config_applied);
    return config_applied;
}

/// A required option that no value source supplied — reported to the user via
/// the `OptionMissingRequired` diagnostic. `name` is the option's effective long
/// flag name (custom `meta.options.<field>.name` or dashed field name).
const MissingRequiredOption = struct {
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
fn firstMissingRequiredOption(
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
const MissingDependency = struct {
    option_name: []const u8,
    required_name: []const u8,
};

/// The first unmet `requires` dependency (in field order, then dependency
/// order), or null. A field's dependencies are enforced only when the field
/// itself was supplied; each dependency must then be supplied by some source.
/// Runs beside `firstMissingRequiredOption`, over the same `options_provided`
/// and `config_applied` bitsets ("supplied" = either flag; the same explicit
/// notion `firstMissingRequiredOption` uses).
fn firstMissingDependency(
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
const MutuallyExclusive = struct {
    first: []const u8,
    second: []const u8,
};

/// The first `meta.exclusive` set with two or more supplied members (reporting
/// the first two in declaration order), or null. Runs beside
/// `firstMissingRequiredOption`, after `requires`, over the same
/// `options_provided` and `config_applied` bitsets.
fn firstExclusiveViolation(
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
const ValidationFailure = struct {
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
fn firstOptionValidationError(
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
fn firstArgValidationError(
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

/// Validate fully resolved command inputs and return the first failure in the
/// ordering fixed by ADR-0022 and ADR-0025. On failure, `diag` is populated
/// before the error is returned; the registry remains responsible for assigning
/// it to the context, dispatching `onError`, and rendering an unhandled error.
///
/// Validation rendering may allocate from `allocator`. The registry passes its
/// command arena and keeps the parsed result alive until command dispatch ends,
/// so diagnostic payloads remain valid through error hooks and rendering. Tests
/// may pass any allocator as long as it outlives their diagnostic assertions.
pub fn validateResolved(
    allocator: std.mem.Allocator,
    comptime ArgsType: type,
    comptime OptionsType: type,
    comptime meta: anytype,
    args: ArgsType,
    options: OptionsType,
    provided: [options_parser.optionFieldCount(OptionsType)]bool,
    config_applied: [options_parser.optionFieldCount(OptionsType)]bool,
    diag: *?ZcliDiagnostic,
) ZcliError!void {
    if (firstMissingRequiredOption(OptionsType, meta, provided, config_applied)) |missing| {
        diag.* = .{ .OptionMissingRequired = .{
            .option_name = missing.name,
            .expected_type = missing.expected_type,
        } };
        return error.OptionMissingRequired;
    }

    if (firstMissingDependency(OptionsType, meta, provided, config_applied)) |dep| {
        diag.* = .{ .OptionMissingDependency = .{
            .option_name = dep.option_name,
            .required_name = dep.required_name,
        } };
        return error.OptionMissingDependency;
    }

    if (firstExclusiveViolation(OptionsType, meta, provided, config_applied)) |ex| {
        diag.* = .{ .OptionMutuallyExclusive = .{
            .first = ex.first,
            .second = ex.second,
        } };
        return error.OptionMutuallyExclusive;
    }

    if (firstArgValidationError(allocator, ArgsType, meta, args)) |failure| {
        diag.* = .{ .ArgumentValidationFailed = .{
            .field_name = failure.name,
            .position = failure.position,
            .provided_value = failure.provided_value,
            .reason = failure.reason,
        } };
        return error.ArgumentValidationFailed;
    }

    if (firstOptionValidationError(allocator, OptionsType, meta, options)) |failure| {
        diag.* = .{ .OptionValidationFailed = .{
            .option_name = failure.name,
            .provided_value = failure.provided_value,
            .reason = failure.reason,
        } };
        return error.OptionValidationFailed;
    }
}

const FirstCountConfig = struct {
    pub fn applyConfigDefaults(context: anytype, comptime OptionsType: type, options: *OptionsType, provided: []const bool, applied: []bool) void {
        _ = context;
        if (!provided[0] and !applied[0]) {
            options.count = 11;
            applied[0] = true;
        }
    }
};

const SecondCountConfig = struct {
    pub fn applyConfigDefaults(context: anytype, comptime OptionsType: type, options: *OptionsType, provided: []const bool, applied: []bool) void {
        _ = context;
        if (!provided[0] and !applied[0]) {
            options.count = 22;
            applied[0] = true;
        }
    }
};

const SecurityConfig = struct {
    pub fn applyConfigDefaults(context: anytype, comptime OptionsType: type, options: *OptionsType, provided: []const bool, applied: []bool) void {
        _ = context;
        if (!provided[0] and !applied[0]) {
            options.skip_verification = true;
            applied[0] = true;
        }
        if (!provided[1] and !applied[1]) {
            options.registry = "https://evil.example";
            applied[1] = true;
        }
        if (!provided[2] and !applied[2]) {
            options.count = 9;
            applied[2] = true;
        }
    }
};

const RogueConfig = struct {
    pub fn applyConfigDefaults(context: anytype, comptime OptionsType: type, options: *OptionsType, provided: []const bool, applied: []bool) void {
        _ = context;
        _ = provided;
        inline for (@typeInfo(OptionsType).@"struct".fields, 0..) |field, i| {
            if (field.type == bool) {
                @field(options, field.name) = true;
                applied[i] = true;
            } else if (field.type == []const u8) {
                @field(options, field.name) = "https://evil.example";
                applied[i] = true;
            } else if (field.type == u32) {
                @field(options, field.name) = 77;
                applied[i] = true;
            }
        }
    }
};

const RequiredConfig = struct {
    pub fn applyConfigDefaults(context: anytype, comptime OptionsType: type, options: *OptionsType, provided: []const bool, applied: []bool) void {
        _ = context;
        if (!provided[0] and !applied[0]) {
            options.signing_key = "attacker-key";
            applied[0] = true;
        }
        if (!provided[1] and !applied[1]) {
            options.project = "acme";
            applied[1] = true;
        }
    }
};

test "applyConfigAdapters: earlier config wins and CLI or env wins over every adapter" {
    const Options = struct { count: u32 = 5 };
    var context: u8 = 0;

    var from_config = Options{};
    const config_applied = applyConfigAdapters(Options, null, &.{ FirstCountConfig, SecondCountConfig }, &context, &from_config, .{false});
    try std.testing.expectEqual(@as(u32, 11), from_config.count);
    try std.testing.expect(config_applied[0]);

    var from_higher_source = Options{ .count = 99 };
    const skipped = applyConfigAdapters(Options, null, &.{ FirstCountConfig, SecondCountConfig }, &context, &from_higher_source, .{true});
    try std.testing.expectEqual(@as(u32, 99), from_higher_source.count);
    try std.testing.expect(!skipped[0]);
}

test "applyConfigAdapters: no_config masks conforming adapters and restores rogue writes" {
    const Options = struct {
        skip_verification: bool = false,
        registry: []const u8 = "https://trusted.example",
        count: u32 = 1,
    };
    const meta = .{ .options = .{
        .skip_verification = .{ .no_config = true },
        .registry = .{ .no_config = true },
    } };
    var context: u8 = 0;

    var conforming = Options{};
    const conforming_applied = applyConfigAdapters(Options, meta, &.{SecurityConfig}, &context, &conforming, .{ false, false, false });
    try std.testing.expect(!conforming.skip_verification);
    try std.testing.expectEqualStrings("https://trusted.example", conforming.registry);
    try std.testing.expectEqual(@as(u32, 9), conforming.count);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, &conforming_applied);

    var rogue = Options{};
    const rogue_applied = applyConfigAdapters(Options, meta, &.{RogueConfig}, &context, &rogue, .{ false, false, false });
    try std.testing.expect(!rogue.skip_verification);
    try std.testing.expectEqualStrings("https://trusted.example", rogue.registry);
    try std.testing.expectEqual(@as(u32, 77), rogue.count);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, &rogue_applied);

    // The restore point is the already-resolved CLI/env value, not the struct
    // default: even a rogue adapter cannot roll a trusted higher source back.
    var rogue_after_higher_source = Options{
        .skip_verification = true,
        .registry = "https://from-env.example",
    };
    const higher_source_applied = applyConfigAdapters(Options, meta, &.{RogueConfig}, &context, &rogue_after_higher_source, .{ true, true, false });
    try std.testing.expect(rogue_after_higher_source.skip_verification);
    try std.testing.expectEqualStrings("https://from-env.example", rogue_after_higher_source.registry);
    try std.testing.expectEqual(@as(u32, 77), rogue_after_higher_source.count);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, &higher_source_applied);
}

test "NoConfigSnapshot: unused and false markers stay zero-sized" {
    const Options = struct { count: u32 = 1 };
    try std.testing.expectEqual(void, NoConfigSnapshot(Options, .{}));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(NoConfigSnapshot(Options, .{})));

    const inert = .{ .options = .{ .count = .{ .no_config = false } } };
    try std.testing.expectEqual(void, NoConfigSnapshot(Options, inert));

    const active = .{ .options = .{ .count = .{ .no_config = true } } };
    try std.testing.expectEqual(Options, NoConfigSnapshot(Options, active));
}

test "resolved policy: a locked required option ignores config but accepts CLI or env" {
    const Options = struct {
        signing_key: []const u8,
        project: []const u8,
    };
    const meta = .{ .options = .{ .signing_key = .{ .no_config = true } } };
    var context: u8 = 0;
    var options: Options = .{ .signing_key = "", .project = "" };
    const applied = applyConfigAdapters(Options, meta, &.{RequiredConfig}, &context, &options, .{ false, false });

    try std.testing.expectEqualStrings("", options.signing_key);
    try std.testing.expectEqualStrings("acme", options.project);
    try std.testing.expectEqualSlices(bool, &.{ false, true }, &applied);

    var diag: ?ZcliDiagnostic = null;
    try std.testing.expectError(
        error.OptionMissingRequired,
        validateResolved(std.testing.allocator, struct {}, Options, meta, .{}, options, .{ false, false }, applied, &diag),
    );
    try std.testing.expectEqualStrings("signing-key", diag.?.OptionMissingRequired.option_name);

    diag = null;
    try validateResolved(std.testing.allocator, struct {}, Options, meta, .{}, .{ .signing_key = "trusted", .project = options.project }, .{ true, false }, applied, &diag);
    try std.testing.expect(diag == null);
}

test "validateResolved: required uses effective name and any source satisfies it" {
    const Options = struct { output_file: []const u8 };
    const meta = .{ .options = .{ .output_file = .{ .name = "out" } } };
    const options = Options{ .output_file = "" };
    var diag: ?ZcliDiagnostic = null;

    try std.testing.expectError(
        error.OptionMissingRequired,
        validateResolved(std.testing.allocator, struct {}, Options, meta, .{}, options, .{false}, .{false}, &diag),
    );
    try std.testing.expectEqualStrings("out", diag.?.OptionMissingRequired.option_name);
    try std.testing.expectEqualStrings("[]const u8", diag.?.OptionMissingRequired.expected_type);

    diag = null;
    try validateResolved(std.testing.allocator, struct {}, Options, meta, .{}, options, .{true}, .{false}, &diag);
    try validateResolved(std.testing.allocator, struct {}, Options, meta, .{}, options, .{false}, .{true}, &diag);
}

test "validateResolved: dependency and exclusive diagnostics use declaration order" {
    const Options = struct {
        json: bool = false,
        yaml: bool = false,
        output: ?[]const u8 = null,
        output_format: ?enum { pretty, compact } = null,
    };
    const meta = .{
        .exclusive = .{.{ .json, .yaml }},
        .options = .{ .output_format = .{ .requires = .{.output} } },
    };
    const options = Options{};
    const none = [_]bool{ false, false, false, false };
    var diag: ?ZcliDiagnostic = null;

    try std.testing.expectError(
        error.OptionMissingDependency,
        validateResolved(std.testing.allocator, struct {}, Options, meta, .{}, options, .{ false, false, false, true }, none, &diag),
    );
    try std.testing.expectEqualStrings("output-format", diag.?.OptionMissingDependency.option_name);
    try std.testing.expectEqualStrings("output", diag.?.OptionMissingDependency.required_name);

    diag = null;
    try std.testing.expectError(
        error.OptionMutuallyExclusive,
        validateResolved(std.testing.allocator, struct {}, Options, meta, .{}, options, .{ true, true, false, false }, none, &diag),
    );
    try std.testing.expectEqualStrings("json", diag.?.OptionMutuallyExclusive.first);
    try std.testing.expectEqualStrings("yaml", diag.?.OptionMutuallyExclusive.second);
}

test "validateResolved: Args validation precedes Options validation" {
    const V = struct {
        fn small(n: u8) ?[]const u8 {
            return if (n > 10) "must be 10 or less" else null;
        }
        fn nonzero(n: u16) ?[]const u8 {
            return if (n == 0) "must not be zero" else null;
        }
    };
    const Args = struct { count: u8 };
    const Options = struct { port: u16 = 8080 };
    const meta = .{
        .args = .{ .count = .{ .validate = V.small } },
        .options = .{ .port = .{ .name = "listen", .validate = V.nonzero } },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diag: ?ZcliDiagnostic = null;

    try std.testing.expectError(
        error.ArgumentValidationFailed,
        validateResolved(allocator, Args, Options, meta, .{ .count = 99 }, .{ .port = 0 }, .{false}, .{false}, &diag),
    );
    try std.testing.expectEqualStrings("count", diag.?.ArgumentValidationFailed.field_name);
    try std.testing.expectEqual(@as(usize, 0), diag.?.ArgumentValidationFailed.position);
    try std.testing.expectEqualStrings("99", diag.?.ArgumentValidationFailed.provided_value);

    diag = null;
    try std.testing.expectError(
        error.OptionValidationFailed,
        validateResolved(allocator, Args, Options, meta, .{ .count = 3 }, .{ .port = 0 }, .{false}, .{false}, &diag),
    );
    try std.testing.expectEqualStrings("listen", diag.?.OptionValidationFailed.option_name);
    try std.testing.expectEqualStrings("0", diag.?.OptionValidationFailed.provided_value);
    try std.testing.expectEqualStrings("must not be zero", diag.?.OptionValidationFailed.reason);
}

test "validateResolved: optional values are skipped only when absent" {
    const V = struct {
        fn nonzero(n: u32) ?[]const u8 {
            return if (n == 0) "must not be zero" else null;
        }
    };
    const Options = struct { limit: ?u32 = null };
    const meta = .{ .options = .{ .limit = .{ .validate = V.nonzero } } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diag: ?ZcliDiagnostic = null;

    try validateResolved(allocator, struct {}, Options, meta, .{}, .{ .limit = null }, .{false}, .{false}, &diag);
    try validateResolved(allocator, struct {}, Options, meta, .{}, .{ .limit = 5 }, .{true}, .{false}, &diag);
    try std.testing.expectError(
        error.OptionValidationFailed,
        validateResolved(allocator, struct {}, Options, meta, .{}, .{ .limit = 0 }, .{true}, .{false}, &diag),
    );
    try std.testing.expectEqualStrings("limit", diag.?.OptionValidationFailed.option_name);
}

test "validateResolved: required, requires, and exclusive precede value hooks" {
    const V = struct {
        fn reject(_: bool) ?[]const u8 {
            return "rejected";
        }
    };
    const Options = struct {
        required: []const u8,
        left: bool = false,
        right: bool = false,
        dependent: bool = false,
    };
    const meta = .{
        .exclusive = .{.{ .left, .right }},
        .options = .{
            .left = .{ .validate = V.reject },
            .dependent = .{ .requires = .{.left} },
        },
    };
    const options = Options{ .required = "" };
    const none = [_]bool{ false, false, false, false };
    var diag: ?ZcliDiagnostic = null;

    try std.testing.expectError(
        error.OptionMissingRequired,
        validateResolved(std.testing.allocator, struct {}, Options, meta, .{}, options, .{ false, true, true, true }, none, &diag),
    );

    diag = null;
    try std.testing.expectError(
        error.OptionMissingDependency,
        validateResolved(std.testing.allocator, struct {}, Options, meta, .{}, options, .{ true, false, true, true }, none, &diag),
    );

    diag = null;
    try std.testing.expectError(
        error.OptionMutuallyExclusive,
        validateResolved(std.testing.allocator, struct {}, Options, meta, .{}, options, .{ true, true, true, false }, none, &diag),
    );
}
