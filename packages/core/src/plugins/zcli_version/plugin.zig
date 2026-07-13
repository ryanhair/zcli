const std = @import("std");
const zcli = @import("zcli");

/// zcli-version Plugin
///
/// Provides version information display for CLI applications.
/// Handles --version/-V global option.
/// Unique identifier for this plugin (required for type-safe context data)
pub const plugin_id = "zcli_version";

/// Run below zcli_help (priority 100): when both `--help` and `--version` are
/// passed, help wins. Priority orders every hook the registry dispatches
/// (preExecute, onError, …) highest-first, so this also decides who answers a
/// `--version` that lands on a non-existent command (see `onError` below) —
/// help's group/no-command handling is consulted before ours.
pub const priority = 90;

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
        // The registry always dispatches the declared bool value for this
        // option, so use it directly — no type guard needed.
        if (value) {
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

/// Error hook: honor `--version` even when routing fails.
///
/// The flag is consumed pre-routing (in `handleGlobalOption`) but only acted on
/// post-routing (in `preExecute`). When it rides on a non-existent command,
/// routing returns `error.CommandNotFound` before `preExecute` ever runs — so
/// `myapp --version bogus` would otherwise report "command not found" instead
/// of the version the user asked for. Catch that here: if a version was
/// requested, print it (stdout) and mark the error handled.
pub fn onError(
    context: anytype,
    err: anyerror,
) !bool {
    if (err == error.CommandNotFound and context.plugins.zcli_version.version_requested) {
        try showVersion(context);
        return true; // Handled — the user got their version.
    }
    return false;
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
    try std.testing.expect(@hasDecl(@This(), "onError"));
    try std.testing.expect(@hasDecl(@This(), "ContextData"));
    try std.testing.expect(@hasDecl(@This(), "isVersionRequested"));
}

// Note: behavioral coverage (—version prints and skips execution, -V, and the
// onError path for --version on a bogus command) lives in
// plugin_pipeline_test.zig, which registers this plugin in a real registry.
