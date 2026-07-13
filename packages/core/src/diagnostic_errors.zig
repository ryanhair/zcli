const std = @import("std");
const levenshtein = @import("levenshtein.zig");

pub const ZcliError = error{
    // Argument parsing errors
    ArgumentMissingRequired,
    ArgumentInvalidValue,
    ArgumentTooMany,
    ArgumentValidationFailed,

    // Option parsing errors
    OptionUnknown,
    OptionMissingValue,
    OptionInvalidValue,
    OptionBooleanWithValue,
    OptionDuplicate,
    OptionMissingRequired,
    OptionMutuallyExclusive,
    OptionMissingDependency,
    OptionValidationFailed,

    // Command routing errors
    CommandNotFound,
    SubcommandNotFound,

    // Build-time errors
    BuildCommandDiscoveryFailed,
    BuildRegistryGenerationFailed,
    BuildOutOfMemory,

    // System errors
    SystemOutOfMemory,
    SystemFileNotFound,
    SystemAccessDenied,

    // Special cases
    HelpRequested,
    VersionRequested,

    // Resource limits
    ResourceLimitExceeded,
};

pub const ZcliDiagnostic = union(enum) {
    // Argument parsing errors
    ArgumentMissingRequired: struct {
        field_name: []const u8,
        position: usize,
        expected_type: []const u8,
    },
    ArgumentInvalidValue: struct {
        field_name: []const u8,
        position: usize,
        provided_value: []const u8,
        expected_type: []const u8,
        /// Nearest valid choice for a mistyped enum value ("did you mean … ?"),
        /// or null. A comptime variant name with static lifetime — never freed.
        suggestion: ?[]const u8 = null,
    },
    ArgumentTooMany: struct {
        expected_count: usize,
        actual_count: usize,
    },
    /// A positional arg's `meta.args.<field>.validate` rejected the parsed value.
    /// `field_name` is the Args field name; `position` is 0-based;
    /// `provided_value` is the rejected value rendered to a string; `reason` is
    /// the author-provided message, rendered verbatim.
    ArgumentValidationFailed: struct {
        field_name: []const u8,
        position: usize,
        provided_value: []const u8,
        reason: []const u8,
    },

    // Option parsing errors
    OptionUnknown: struct {
        option_name: []const u8,
        is_short: bool,
        suggestions: []const []const u8,
    },
    OptionMissingValue: struct {
        option_name: []const u8,
        is_short: bool,
        expected_type: []const u8,
    },
    OptionInvalidValue: struct {
        option_name: []const u8,
        is_short: bool,
        provided_value: []const u8,
        expected_type: []const u8,
        /// Nearest valid choice for a mistyped enum value ("did you mean … ?"),
        /// or null. A comptime variant name with static lifetime — never freed.
        suggestion: ?[]const u8 = null,
    },
    OptionBooleanWithValue: struct {
        option_name: []const u8,
        is_short: bool,
        provided_value: []const u8,
    },
    OptionDuplicate: struct {
        option_name: []const u8,
        is_short: bool,
    },
    OptionMissingRequired: struct {
        option_name: []const u8,
        expected_type: []const u8,
    },
    /// Two members of a `meta.exclusive` set were both supplied. Names are the
    /// effective long flag names (without the leading `--`), static lifetime.
    OptionMutuallyExclusive: struct {
        first: []const u8,
        second: []const u8,
    },
    /// A field declaring `meta.options.<field>.requires` was supplied without one
    /// of its dependencies. Names are the effective long flag names (without the
    /// leading `--`), static lifetime.
    OptionMissingDependency: struct {
        option_name: []const u8,
        required_name: []const u8,
    },
    /// A field's `meta.options.<field>.validate` rejected the resolved value.
    /// `option_name` is the effective long flag name (without `--`);
    /// `provided_value` is the rejected value rendered to a string; `reason` is
    /// the author-provided message, rendered verbatim.
    OptionValidationFailed: struct {
        option_name: []const u8,
        provided_value: []const u8,
        reason: []const u8,
    },

    // Command routing errors
    CommandNotFound: struct {
        attempted_command: []const u8,
        command_path: []const []const u8,
        suggestions: []const []const u8,
    },
    SubcommandNotFound: struct {
        subcommand_name: []const u8,
        parent_path: []const []const u8,
        suggestions: []const []const u8,
    },

    // Build-time errors
    BuildCommandDiscoveryFailed: struct {
        file_path: []const u8,
        details: []const u8,
        suggestion: ?[]const u8,
    },
    BuildRegistryGenerationFailed: struct {
        details: []const u8,
        suggestion: ?[]const u8,
    },
    BuildOutOfMemory: struct {
        operation: []const u8,
        details: []const u8,
    },

    // System errors
    SystemOutOfMemory: void,
    SystemFileNotFound: struct {
        file_path: []const u8,
    },
    SystemAccessDenied: struct {
        file_path: []const u8,
    },

    // Special cases
    HelpRequested: void,
    VersionRequested: void,

    // Resource limits
    ResourceLimitExceeded: struct {
        limit_type: []const u8,
        limit_value: usize,
        actual_value: usize,
        suggestion: ?[]const u8,
    },
};

// Compile-time validation to ensure every error has a corresponding diagnostic
// This prevents errors and diagnostics from getting out of sync
comptime {
    @setEvalBranchQuota(5000);
    const error_fields = std.meta.fields(ZcliError);
    const diagnostic_fields = std.meta.fields(std.meta.FieldEnum(ZcliDiagnostic));

    if (error_fields.len != diagnostic_fields.len) {
        @compileError(std.fmt.comptimePrint("ZcliError and ZcliDiagnostic field count mismatch: {} vs {}", .{ error_fields.len, diagnostic_fields.len }));
    }

    // Verify each error has a corresponding diagnostic
    for (error_fields) |error_field| {
        var found = false;
        for (diagnostic_fields) |diag_field| {
            if (std.mem.eql(u8, error_field.name, diag_field.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            @compileError("Missing diagnostic for error: " ++ error_field.name);
        }
    }
}

/// Check if an error has diagnostic information available
pub fn hasDiagnostic(err: anyerror) bool {
    inline for (std.meta.fields(ZcliDiagnostic)) |field| {
        if (std.mem.eql(u8, field.name, @errorName(err))) {
            return true;
        }
    }
    return false;
}

/// The expectation string a diagnostic should carry for a field of type `T`.
///
/// For enums this is a comptime-built variant list — `one of: a, b, c` — which
/// `humanType` passes through verbatim. For everything else it is the raw
/// `@typeName(T)`, which `humanType` maps to a friendly phrase at render time.
/// Every parser site that fills a diagnostic's `expected_type` uses this so the
/// enum-listing behavior is uniform.
pub fn expectedTypeName(comptime T: type) []const u8 {
    const Bare = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    return switch (@typeInfo(Bare)) {
        .@"enum" => |e| comptime blk: {
            var list: []const u8 = "one of: ";
            for (e.fields, 0..) |f, i| {
                list = list ++ (if (i == 0) "" else ", ") ++ f.name;
            }
            break :blk list;
        },
        else => @typeName(T),
    };
}

/// For an enum-typed field (or `?enum`), the valid variant name nearest to a
/// mistyped `value`, for a "did you mean …?" hint — or null when the field is
/// not an enum or nothing is close enough. Variant names are comptime string
/// literals with static lifetime, so the result needs no allocation and is never
/// freed. Shared by the args parser and the options parser so enum suggestions
/// read identically for positional args and option values.
pub fn nearestEnumValue(comptime T: type, value: []const u8) ?[]const u8 {
    const Bare = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    switch (@typeInfo(Bare)) {
        .@"enum" => |e| {
            var best: ?[]const u8 = null;
            var best_distance: usize = std.math.maxInt(usize);
            inline for (e.fields) |f| {
                const d = levenshtein.editDistance(value, f.name);
                if (d < best_distance) {
                    best_distance = d;
                    best = f.name;
                }
            }
            // Only offer a suggestion when it is a plausible typo of a variant,
            // not an unrelated word — same spirit as the unknown-option list.
            const max_distance = 3;
            if (best) |name| {
                if (best_distance <= max_distance and best_distance < name.len) return name;
            }
            return null;
        },
        else => return null,
    }
}

fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Turn a Zig type name (as produced by `@typeName`, or an `expectedTypeName`
/// enum list) into an expectation phrase an end user of the CLI can
/// understand. This is the only place raw type strings are rendered, so all
/// humanizing lives here.
fn humanType(type_name: []const u8) []const u8 {
    // Enum variant lists (from expectedTypeName) are already human-readable.
    if (std.mem.startsWith(u8, type_name, "one of:")) return type_name;
    if (std.mem.eql(u8, type_name, "[]const u8") or std.mem.eql(u8, type_name, "?[]const u8")) {
        return "text";
    }
    // Strip a leading optional marker so `?u32` reads like `u32`.
    const bare = if (type_name.len > 0 and type_name[0] == '?') type_name[1..] else type_name;
    if (bare.len == 0) return "a value";
    if (std.mem.eql(u8, bare, "bool")) return "true or false";
    if (std.mem.eql(u8, bare, "usize") or std.mem.eql(u8, bare, "isize")) return "an integer";
    switch (bare[0]) {
        // iNN / uNN sized integer types (all chars after the prefix are digits).
        'i', 'u' => if (bare.len > 1 and allDigits(bare[1..])) return "an integer",
        // fNN float types.
        'f' => if (bare.len > 1 and allDigits(bare[1..])) return "a number",
        else => {},
    }
    return "a value";
}

/// Get a user-friendly description of a diagnostic
pub fn formatDiagnostic(diagnostic: ZcliDiagnostic, allocator: std.mem.Allocator) ![]u8 {
    return switch (diagnostic) {
        .ArgumentMissingRequired => |ctx| std.fmt.allocPrint(allocator, "Missing required argument '{s}' at position {d}. Expected {s}.", .{ ctx.field_name, ctx.position + 1, humanType(ctx.expected_type) }),
        .ArgumentInvalidValue => |ctx| if (ctx.suggestion) |s|
            std.fmt.allocPrint(allocator, "Invalid value '{s}' for argument '{s}' at position {d}. Expected {s}. Did you mean '{s}'?", .{ ctx.provided_value, ctx.field_name, ctx.position + 1, humanType(ctx.expected_type), s })
        else
            std.fmt.allocPrint(allocator, "Invalid value '{s}' for argument '{s}' at position {d}. Expected {s}.", .{ ctx.provided_value, ctx.field_name, ctx.position + 1, humanType(ctx.expected_type) }),
        .ArgumentTooMany => |ctx| std.fmt.allocPrint(allocator, "Too many arguments provided. Expected {d} arguments, got {d}", .{ ctx.expected_count, ctx.actual_count }),
        .ArgumentValidationFailed => |ctx| std.fmt.allocPrint(allocator, "Invalid value '{s}' for argument '{s}' at position {d}: {s}.", .{ ctx.provided_value, ctx.field_name, ctx.position + 1, ctx.reason }),
        .OptionUnknown => |ctx| blk: {
            const base_msg = try std.fmt.allocPrint(allocator, "Unknown option '{s}{s}'", .{ if (ctx.is_short) "-" else "--", ctx.option_name });

            if (ctx.suggestions.len > 0) {
                var full_msg = std.ArrayList(u8).empty;
                defer full_msg.deinit(allocator);
                try full_msg.appendSlice(allocator, base_msg);
                allocator.free(base_msg);
                try full_msg.appendSlice(allocator, "\nDid you mean:\n");
                for (ctx.suggestions) |suggestion| {
                    const line = try std.fmt.allocPrint(allocator, "  --{s}\n", .{suggestion});
                    defer allocator.free(line);
                    try full_msg.appendSlice(allocator, line);
                }
                break :blk try full_msg.toOwnedSlice(allocator);
            } else {
                break :blk base_msg;
            }
        },
        .OptionMissingValue => |ctx| std.fmt.allocPrint(allocator, "Option '{s}{s}' requires {s}.", .{ if (ctx.is_short) "-" else "--", ctx.option_name, humanType(ctx.expected_type) }),
        .OptionInvalidValue => |ctx| if (ctx.suggestion) |s|
            std.fmt.allocPrint(allocator, "Invalid value '{s}' for option '{s}{s}'. Expected {s}. Did you mean '{s}'?", .{ ctx.provided_value, if (ctx.is_short) "-" else "--", ctx.option_name, humanType(ctx.expected_type), s })
        else
            std.fmt.allocPrint(allocator, "Invalid value '{s}' for option '{s}{s}'. Expected {s}.", .{ ctx.provided_value, if (ctx.is_short) "-" else "--", ctx.option_name, humanType(ctx.expected_type) }),
        .OptionBooleanWithValue => |ctx| std.fmt.allocPrint(allocator, "Boolean option '{s}{s}' does not accept a value (got '{s}')", .{ if (ctx.is_short) "-" else "--", ctx.option_name, ctx.provided_value }),
        .OptionDuplicate => |ctx| std.fmt.allocPrint(allocator, "Duplicate option '{s}{s}'", .{ if (ctx.is_short) "-" else "--", ctx.option_name }),
        .OptionMissingRequired => |ctx| std.fmt.allocPrint(allocator, "Missing required option '--{s}'. Expected {s}.", .{ ctx.option_name, humanType(ctx.expected_type) }),
        .OptionMutuallyExclusive => |ctx| std.fmt.allocPrint(allocator, "Options '--{s}' and '--{s}' cannot be used together.", .{ ctx.first, ctx.second }),
        .OptionMissingDependency => |ctx| std.fmt.allocPrint(allocator, "Option '--{s}' requires '--{s}'.", .{ ctx.option_name, ctx.required_name }),
        .OptionValidationFailed => |ctx| std.fmt.allocPrint(allocator, "Invalid value '{s}' for option '--{s}': {s}.", .{ ctx.provided_value, ctx.option_name, ctx.reason }),
        .CommandNotFound => |ctx| blk: {
            const base_msg = try std.fmt.allocPrint(allocator, "Unknown command '{s}'", .{ctx.attempted_command});

            if (ctx.suggestions.len > 0) {
                var full_msg = std.ArrayList(u8).empty;
                defer full_msg.deinit(allocator);
                try full_msg.appendSlice(allocator, base_msg);
                allocator.free(base_msg);
                try full_msg.appendSlice(allocator, "\nDid you mean:\n");
                for (ctx.suggestions) |suggestion| {
                    const line = try std.fmt.allocPrint(allocator, "  {s}\n", .{suggestion});
                    defer allocator.free(line);
                    try full_msg.appendSlice(allocator, line);
                }
                break :blk try full_msg.toOwnedSlice(allocator);
            } else {
                break :blk base_msg;
            }
        },
        .SubcommandNotFound => |ctx| std.fmt.allocPrint(allocator, "Unknown subcommand '{s}' for command path: {s}", .{ ctx.subcommand_name, if (ctx.parent_path.len > 0) ctx.parent_path[ctx.parent_path.len - 1] else "root" }),
        .BuildCommandDiscoveryFailed => |ctx| blk: {
            const base_msg = try std.fmt.allocPrint(allocator, "Command discovery failed in '{s}': {s}", .{ ctx.file_path, ctx.details });
            if (ctx.suggestion) |suggestion| {
                const full_msg = try std.fmt.allocPrint(allocator, "{s}. {s}", .{ base_msg, suggestion });
                allocator.free(base_msg);
                break :blk full_msg;
            } else {
                break :blk base_msg;
            }
        },
        .BuildRegistryGenerationFailed => |ctx| blk: {
            const base_msg = try std.fmt.allocPrint(allocator, "Registry generation failed: {s}", .{ctx.details});
            if (ctx.suggestion) |suggestion| {
                const full_msg = try std.fmt.allocPrint(allocator, "{s}. {s}", .{ base_msg, suggestion });
                allocator.free(base_msg);
                break :blk full_msg;
            } else {
                break :blk base_msg;
            }
        },
        .BuildOutOfMemory => |ctx| std.fmt.allocPrint(allocator, "Out of memory during {s}: {s}", .{ ctx.operation, ctx.details }),
        .SystemOutOfMemory => try allocator.dupe(u8, "Out of memory"),
        .SystemFileNotFound => |ctx| std.fmt.allocPrint(allocator, "File not found: {s}", .{ctx.file_path}),
        .SystemAccessDenied => |ctx| std.fmt.allocPrint(allocator, "Access denied: {s}", .{ctx.file_path}),
        .HelpRequested => try allocator.dupe(u8, "Help requested"),
        .VersionRequested => try allocator.dupe(u8, "Version requested"),
        .ResourceLimitExceeded => |ctx| blk: {
            const base_msg = try std.fmt.allocPrint(allocator, "Resource limit exceeded: {s} limit of {d} exceeded (got {d})", .{ ctx.limit_type, ctx.limit_value, ctx.actual_value });
            if (ctx.suggestion) |suggestion| {
                const full_msg = try std.fmt.allocPrint(allocator, "{s}. Suggestion: {s}", .{ base_msg, suggestion });
                allocator.free(base_msg);
                break :blk full_msg;
            } else {
                break :blk base_msg;
            }
        },
    };
}

// Tests to verify the diagnostic system works correctly
test "compile-time error/diagnostic sync validation" {
    // This test ensures that the compile-time validation works
    // If we add/remove errors without updating diagnostics, compilation will fail

    // Test that we can check if errors have diagnostics
    try std.testing.expect(hasDiagnostic(ZcliError.ArgumentMissingRequired));
    try std.testing.expect(hasDiagnostic(ZcliError.OptionUnknown));
    try std.testing.expect(!hasDiagnostic(error.SomeUnrelatedError));
}

test "diagnostic formatting" {
    const allocator = std.testing.allocator;

    // Test argument error diagnostic: the raw `@typeName` is rendered as a
    // human-readable expectation ("text"), not the Zig type name.
    const arg_diag = ZcliDiagnostic{ .ArgumentMissingRequired = .{
        .field_name = "username",
        .position = 0,
        .expected_type = "[]const u8",
    } };

    const arg_msg = try formatDiagnostic(arg_diag, allocator);
    defer allocator.free(arg_msg);

    try std.testing.expect(std.mem.indexOf(u8, arg_msg, "username") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg_msg, "position 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg_msg, "text") != null);
    // The raw Zig type name never leaks to the user.
    try std.testing.expect(std.mem.indexOf(u8, arg_msg, "[]const u8") == null);

    // Test option error diagnostic
    const opt_diag = ZcliDiagnostic{ .OptionUnknown = .{
        .option_name = "verbose",
        .is_short = false,
        .suggestions = &.{ "verbosity", "version" },
    } };

    const opt_msg = try formatDiagnostic(opt_diag, allocator);
    defer allocator.free(opt_msg);

    try std.testing.expect(std.mem.indexOf(u8, opt_msg, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, opt_msg, "Did you mean") != null);
    try std.testing.expect(std.mem.indexOf(u8, opt_msg, "verbosity") != null);
}

test "humanType maps Zig type names to human-readable expectations" {
    try std.testing.expectEqualStrings("text", humanType("[]const u8"));
    try std.testing.expectEqualStrings("text", humanType("?[]const u8"));
    try std.testing.expectEqualStrings("an integer", humanType("u32"));
    try std.testing.expectEqualStrings("an integer", humanType("i64"));
    try std.testing.expectEqualStrings("an integer", humanType("?usize"));
    try std.testing.expectEqualStrings("a number", humanType("f64"));
    try std.testing.expectEqualStrings("true or false", humanType("bool"));
    // Unknown / qualified type names fall back to a generic phrase.
    try std.testing.expectEqualStrings("a value", humanType("some.module.Color"));
    try std.testing.expectEqualStrings("a value", humanType("u"));
    // Enum lists from expectedTypeName pass through verbatim.
    try std.testing.expectEqualStrings("one of: red, green", humanType("one of: red, green"));
}

test "nearestEnumValue suggests the closest variant, or nothing" {
    const Env = enum { dev, staging, prod };
    try std.testing.expectEqualStrings("staging", nearestEnumValue(Env, "stagin").?);
    try std.testing.expectEqualStrings("prod", nearestEnumValue(Env, "prd").?);
    // Optional enums unwrap to the same variant list.
    try std.testing.expectEqualStrings("dev", nearestEnumValue(?Env, "dee").?);
    // Nothing close → no suggestion (avoids nonsense hints).
    try std.testing.expect(nearestEnumValue(Env, "xxxxxxxx") == null);
    // Non-enum types never suggest.
    try std.testing.expect(nearestEnumValue(u32, "5") == null);
    try std.testing.expect(nearestEnumValue([]const u8, "anything") == null);
}

test "OptionMissingRequired renders a humane message" {
    const allocator = std.testing.allocator;
    const diag = ZcliDiagnostic{ .OptionMissingRequired = .{
        .option_name = "region",
        .expected_type = "[]const u8",
    } };
    const msg = try formatDiagnostic(diag, allocator);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Missing required option '--region'") != null);
    // The type is humanized, not leaked raw.
    try std.testing.expect(std.mem.indexOf(u8, msg, "text") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "[]const u8") == null);
}

test "OptionMutuallyExclusive names both offending flags" {
    const allocator = std.testing.allocator;
    const diag = ZcliDiagnostic{ .OptionMutuallyExclusive = .{ .first = "json", .second = "yaml" } };
    const msg = try formatDiagnostic(diag, allocator);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "--json") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "--yaml") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "cannot be used together") != null);
}

test "OptionMissingDependency names the supplied option and its missing requirement" {
    const allocator = std.testing.allocator;
    const diag = ZcliDiagnostic{ .OptionMissingDependency = .{ .option_name = "output-format", .required_name = "output" } };
    const msg = try formatDiagnostic(diag, allocator);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "'--output-format' requires '--output'") != null);
}

test "ArgumentValidationFailed renders the field, 1-based position, and reason" {
    const allocator = std.testing.allocator;
    const diag = ZcliDiagnostic{ .ArgumentValidationFailed = .{ .field_name = "count", .position = 1, .provided_value = "99", .reason = "must be 10 or less" } };
    const msg = try formatDiagnostic(diag, allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("Invalid value '99' for argument 'count' at position 2: must be 10 or less.", msg);
}

test "OptionValidationFailed renders the flag and the author's reason" {
    const allocator = std.testing.allocator;
    const diag = ZcliDiagnostic{ .OptionValidationFailed = .{ .option_name = "replicas", .provided_value = "0", .reason = "must be between 1 and 100" } };
    const msg = try formatDiagnostic(diag, allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings("Invalid value '0' for option '--replicas': must be between 1 and 100.", msg);
}

test "invalid enum value messages carry a did-you-mean" {
    const allocator = std.testing.allocator;
    // Argument form.
    {
        const diag = ZcliDiagnostic{ .ArgumentInvalidValue = .{
            .field_name = "env",
            .position = 0,
            .provided_value = "stagin",
            .expected_type = "one of: dev, staging, prod",
            .suggestion = "staging",
        } };
        const msg = try formatDiagnostic(diag, allocator);
        defer allocator.free(msg);
        try std.testing.expect(std.mem.indexOf(u8, msg, "one of: dev, staging, prod") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg, "Did you mean 'staging'?") != null);
    }
    // Option form.
    {
        const diag = ZcliDiagnostic{ .OptionInvalidValue = .{
            .option_name = "level",
            .is_short = false,
            .provided_value = "inof",
            .expected_type = "one of: debug, info, warn",
            .suggestion = "info",
        } };
        const msg = try formatDiagnostic(diag, allocator);
        defer allocator.free(msg);
        try std.testing.expect(std.mem.indexOf(u8, msg, "Did you mean 'info'?") != null);
    }
}

test "expectedTypeName lists enum variants" {
    const Color = enum { red, green, blue };
    try std.testing.expectEqualStrings("one of: red, green, blue", expectedTypeName(Color));
    try std.testing.expectEqualStrings("one of: red, green, blue", expectedTypeName(?Color));
    try std.testing.expectEqualStrings("[]const u8", expectedTypeName([]const u8));
    try std.testing.expectEqualStrings("u32", expectedTypeName(u32));
}
