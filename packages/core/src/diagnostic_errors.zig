const std = @import("std");
const levenshtein = @import("levenshtein.zig");
const custom_type = @import("custom_type.zig");
const Writer = std.Io.Writer;

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
        /// A custom type's `describe(err)` reason for why parsing failed, or null.
        /// When set it replaces the "Expected …" clause (and any suggestion).
        reason: ?[]const u8 = null,
    },
    ArgumentTooMany: struct {
        /// Minimum accepted positional count (required args only).
        min_count: usize,
        /// Maximum accepted positional count (required + optional + defaulted,
        /// excluding varargs). Equals `min_count` when there are no optional
        /// positionals.
        max_count: usize,
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
        /// A custom type's `describe(err)` reason for why parsing failed, or null.
        /// When set it replaces the "Expected …" clause (and any suggestion).
        reason: ?[]const u8 = null,
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
    // A custom type describes its own expectation via `hint` (else its type name).
    if (comptime custom_type.isCustomParsed(Bare)) return custom_type.hintFor(Bare);
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
    // A custom-type `hint` is author-written text — a plain phrase (has a space,
    // no brackets/dots of a raw type name). Pass it through verbatim; anything
    // else (a qualified or unusual type name) becomes the generic phrase.
    if (std.mem.indexOfScalar(u8, type_name, ' ') != null and
        std.mem.indexOfAny(u8, type_name, "[].") == null) return type_name;
    return "a value";
}

/// Write `s` to `w`, dropping C0 control bytes (0x00-0x1F) and DEL (0x7F)
/// except `\t` (0x09) and `\n` (0x0A). Every diagnostic-rendering boundary
/// runs the user-controlled slice of its message (an unknown command name,
/// an unknown option name, a rejected argument/option value) through this
/// before it reaches the terminal. Without it, a crafted value containing an
/// ESC byte can smuggle a raw ANSI/OSC escape sequence — e.g. a window-title
/// set or an OSC 52 clipboard write — straight through to the user's
/// terminal. UTF-8 multibyte sequences pass through untouched: both
/// continuation bytes (0x80-0xBF) and lead bytes (0xC0 and up) fall outside
/// the stripped range.
pub fn writeSanitized(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| {
        switch (c) {
            0x00...0x08, 0x0B...0x1F, 0x7F => {}, // drop control bytes, incl. ESC (0x1b); \t/\n fall through below
            else => try w.writeByte(c),
        }
    }
}

/// Get a user-friendly description of a diagnostic
pub fn formatDiagnostic(diagnostic: ZcliDiagnostic, allocator: std.mem.Allocator) ![]u8 {
    return switch (diagnostic) {
        .ArgumentMissingRequired => |ctx| std.fmt.allocPrint(allocator, "Missing required argument '{s}' at position {d}. Expected {s}.", .{ ctx.field_name, ctx.position + 1, humanType(ctx.expected_type) }),
        .ArgumentInvalidValue => |ctx| if (ctx.reason) |r|
            std.fmt.allocPrint(allocator, "Invalid value '{s}' for argument '{s}' at position {d}: {s}.", .{ ctx.provided_value, ctx.field_name, ctx.position + 1, r })
        else if (ctx.suggestion) |s|
            std.fmt.allocPrint(allocator, "Invalid value '{s}' for argument '{s}' at position {d}. Expected {s}. Did you mean '{s}'?", .{ ctx.provided_value, ctx.field_name, ctx.position + 1, humanType(ctx.expected_type), s })
        else
            std.fmt.allocPrint(allocator, "Invalid value '{s}' for argument '{s}' at position {d}. Expected {s}.", .{ ctx.provided_value, ctx.field_name, ctx.position + 1, humanType(ctx.expected_type) }),
        .ArgumentTooMany => |ctx| if (ctx.max_count == ctx.min_count)
            std.fmt.allocPrint(allocator, "Too many arguments provided. Expected {d} arguments, got {d}", .{ ctx.max_count, ctx.actual_count })
        else
            std.fmt.allocPrint(allocator, "Too many arguments provided. Expected {d}-{d} arguments, got {d}", .{ ctx.min_count, ctx.max_count, ctx.actual_count }),
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
        .OptionInvalidValue => |ctx| if (ctx.reason) |r|
            std.fmt.allocPrint(allocator, "Invalid value '{s}' for option '{s}{s}': {s}.", .{ ctx.provided_value, if (ctx.is_short) "-" else "--", ctx.option_name, r })
        else if (ctx.suggestion) |s|
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

test "expectedTypeName uses a custom type's hint" {
    const Dur = struct {
        secs: u64,
        pub const hint = "a duration like 5m30s";
        pub fn parse(s: []const u8) error{Bad}!@This() {
            return .{ .secs = std.fmt.parseInt(u64, s, 10) catch return error.Bad };
        }
    };
    try std.testing.expectEqualStrings("a duration like 5m30s", expectedTypeName(Dur));
    try std.testing.expectEqualStrings("a duration like 5m30s", expectedTypeName(?Dur));
}

test "OptionInvalidValue renders a custom type's describe reason, else its hint" {
    const allocator = std.testing.allocator;
    // With a describe reason: shown after the colon, no "Expected" clause.
    {
        const diag = ZcliDiagnostic{ .OptionInvalidValue = .{
            .option_name = "timeout",
            .is_short = false,
            .provided_value = "25h",
            .expected_type = "a duration",
            .reason = "hours must be less than 24",
        } };
        const msg = try formatDiagnostic(diag, allocator);
        defer allocator.free(msg);
        try std.testing.expectEqualStrings("Invalid value '25h' for option '--timeout': hours must be less than 24.", msg);
    }
    // Without a reason, the hint (a phrase) passes through humanType verbatim.
    {
        const diag = ZcliDiagnostic{ .OptionInvalidValue = .{
            .option_name = "timeout",
            .is_short = false,
            .provided_value = "nope",
            .expected_type = "a duration like 5m30s",
        } };
        const msg = try formatDiagnostic(diag, allocator);
        defer allocator.free(msg);
        try std.testing.expectEqualStrings("Invalid value 'nope' for option '--timeout'. Expected a duration like 5m30s.", msg);
    }
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

test "writeSanitized strips ESC and other C0 control bytes" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeSanitized(&aw.writer, "before\x1bafter");
    try std.testing.expectEqualStrings("beforeafter", aw.written());
}

test "writeSanitized neuters a full OSC escape sequence" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    // OSC 0 (set window title), BEL-terminated — the ESC and BEL are the
    // bytes a terminal parses as the start/end of the sequence; stripping
    // them leaves inert text behind instead of a live escape sequence.
    try writeSanitized(&aw.writer, "\x1b]0;pwned\x07");
    try std.testing.expectEqualStrings("]0;pwned", aw.written());
}

test "writeSanitized drops DEL but preserves \\n and \\t" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeSanitized(&aw.writer, "a\tb\nc\x7fd");
    try std.testing.expectEqualStrings("a\tb\ncd", aw.written());
}

test "writeSanitized leaves plain UTF-8 (including multibyte) untouched" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const s = "caf\xc3\xa9 \xe4\xbd\xa0\xe5\xa5\xbd \xf0\x9f\x9a\x80"; // "café 你好 🚀"
    try writeSanitized(&aw.writer, s);
    try std.testing.expectEqualStrings(s, aw.written());
}

test "expectedTypeName lists enum variants" {
    const Color = enum { red, green, blue };
    try std.testing.expectEqualStrings("one of: red, green, blue", expectedTypeName(Color));
    try std.testing.expectEqualStrings("one of: red, green, blue", expectedTypeName(?Color));
    try std.testing.expectEqualStrings("[]const u8", expectedTypeName([]const u8));
    try std.testing.expectEqualStrings("u32", expectedTypeName(u32));
}
