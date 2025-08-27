const std = @import("std");

/// Standard Zig error types for zcli parsing operations
/// These align with the current StructuredError variants but follow standard Zig patterns
pub const ZcliError = error{
    // Argument parsing errors
    ArgumentMissingRequired,
    ArgumentInvalidValue,
    ArgumentTooMany,

    // Option parsing errors
    OptionUnknown,
    OptionMissingValue,
    OptionInvalidValue,
    OptionBooleanWithValue,
    OptionDuplicate,

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

/// Rich diagnostic information corresponding to each error type
/// This provides the same context as StructuredError but only when explicitly requested
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
    },
    ArgumentTooMany: struct {
        expected_count: usize,
        actual_count: usize,
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

/// Get a user-friendly description of a diagnostic
pub fn formatDiagnostic(diagnostic: ZcliDiagnostic, allocator: std.mem.Allocator) ![]u8 {
    return switch (diagnostic) {
        .ArgumentMissingRequired => |ctx| std.fmt.allocPrint(allocator, "Missing required argument '{s}' at position {d}. Expected type: {s}", .{ ctx.field_name, ctx.position + 1, ctx.expected_type }),
        .ArgumentInvalidValue => |ctx| std.fmt.allocPrint(allocator, "Invalid value '{s}' for argument '{s}' at position {d}. Expected type: {s}", .{ ctx.provided_value, ctx.field_name, ctx.position + 1, ctx.expected_type }),
        .ArgumentTooMany => |ctx| std.fmt.allocPrint(allocator, "Too many arguments provided. Expected {d} arguments, got {d}", .{ ctx.expected_count, ctx.actual_count }),
        .OptionUnknown => |ctx| blk: {
            const base_msg = try std.fmt.allocPrint(allocator, "Unknown option '{s}{s}'", .{ if (ctx.is_short) "-" else "--", ctx.option_name });

            if (ctx.suggestions.len > 0) {
                var full_msg = std.ArrayList(u8).init(allocator);
                defer full_msg.deinit();
                try full_msg.appendSlice(base_msg);
                allocator.free(base_msg);
                try full_msg.appendSlice("\nDid you mean:\n");
                for (ctx.suggestions) |suggestion| {
                    try full_msg.writer().print("  --{s}\n", .{suggestion});
                }
                break :blk try full_msg.toOwnedSlice();
            } else {
                break :blk base_msg;
            }
        },
        .OptionMissingValue => |ctx| std.fmt.allocPrint(allocator, "Option '{s}{s}' requires a value of type: {s}", .{ if (ctx.is_short) "-" else "--", ctx.option_name, ctx.expected_type }),
        .OptionInvalidValue => |ctx| std.fmt.allocPrint(allocator, "Invalid value '{s}' for option '{s}{s}'. Expected type: {s}", .{ ctx.provided_value, if (ctx.is_short) "-" else "--", ctx.option_name, ctx.expected_type }),
        .OptionBooleanWithValue => |ctx| std.fmt.allocPrint(allocator, "Boolean option '{s}{s}' does not accept a value (got '{s}')", .{ if (ctx.is_short) "-" else "--", ctx.option_name, ctx.provided_value }),
        .OptionDuplicate => |ctx| std.fmt.allocPrint(allocator, "Duplicate option '{s}{s}'", .{ if (ctx.is_short) "-" else "--", ctx.option_name }),
        .CommandNotFound => |ctx| blk: {
            const base_msg = try std.fmt.allocPrint(allocator, "Unknown command '{s}'", .{ctx.attempted_command});

            if (ctx.suggestions.len > 0) {
                var full_msg = std.ArrayList(u8).init(allocator);
                defer full_msg.deinit();
                try full_msg.appendSlice(base_msg);
                allocator.free(base_msg);
                try full_msg.appendSlice("\nDid you mean:\n");
                for (ctx.suggestions) |suggestion| {
                    try full_msg.writer().print("  {s}\n", .{suggestion});
                }
                break :blk try full_msg.toOwnedSlice();
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

    // Test argument error diagnostic
    const arg_diag = ZcliDiagnostic{ .ArgumentMissingRequired = .{
        .field_name = "username",
        .position = 0,
        .expected_type = "string",
    } };

    const arg_msg = try formatDiagnostic(arg_diag, allocator);
    defer allocator.free(arg_msg);

    try std.testing.expect(std.mem.indexOf(u8, arg_msg, "username") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg_msg, "position 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg_msg, "string") != null);

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
