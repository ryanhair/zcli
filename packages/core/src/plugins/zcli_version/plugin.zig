const std = @import("std");
const zcli = @import("zcli");

/// zcli-version Plugin
///
/// Provides version information display for CLI applications.
/// Handles --version/-V global option.
/// Unique identifier for this plugin (required for type-safe context data)
pub const plugin_id = "zcli_version";

/// Plugin-specific context data
pub const ContextData = struct {
    version_requested: bool = false,
};

/// Public API: Check if version was requested
pub fn isVersionRequested(context: anytype) bool {
    return context.plugins.zcli_version.version_requested;
}

/// Global options provided by this plugin
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("version", bool, .{ .short = 'V', .default = false, .description = "Show version information" }),
};

/// Handle global options - specifically the --version flag
pub fn handleGlobalOption(
    context: anytype,
    option_name: []const u8,
    value: anytype,
) !void {
    if (std.mem.eql(u8, option_name, "version")) {
        const bool_val = if (@TypeOf(value) == bool) value else false;
        if (bool_val) {
            context.plugins.zcli_version.version_requested = true;
        }
    }
}

/// Pre-execute hook to show version if requested
pub fn preExecute(
    context: anytype,
    args: zcli.ParsedArgs,
) !?zcli.ParsedArgs {
    if (context.plugins.zcli_version.version_requested) {
        try showVersion(context);
        // Return null to stop execution
        return null;
    }

    // Continue normal execution
    return args;
}

/// Display version information
fn showVersion(context: anytype) !void {
    var stdout = context.stdout();
    try stdout.print("{s} v{s}\n", .{ context.app_name, context.app_version });
}

// ============================================================================
// Tests
// ============================================================================

test "version plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "global_options"));
    try std.testing.expect(@hasDecl(@This(), "handleGlobalOption"));
    try std.testing.expect(@hasDecl(@This(), "preExecute"));
    try std.testing.expect(@hasDecl(@This(), "ContextData"));
    try std.testing.expect(@hasDecl(@This(), "isVersionRequested"));
}

// Note: Integration tests for handleGlobalOption and preExecute
// require a compiled registry with this plugin registered. See integration tests.
