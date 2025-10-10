const std = @import("std");
const zcli = @import("zcli");

/// zcli-version Plugin
///
/// Provides version information display for CLI applications.
/// Handles --version/-V global option.

/// Global options provided by this plugin
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("version", bool, .{ .short = 'V', .default = false, .description = "Show version information" }),
};

/// Handle global options - specifically the --version flag
pub fn handleGlobalOption(
    context: *zcli.Context,
    option_name: []const u8,
    value: anytype,
) !void {
    if (std.mem.eql(u8, option_name, "version")) {
        const bool_val = if (@TypeOf(value) == bool) value else false;
        if (bool_val) {
            try context.setGlobalData("version_requested", "true");
        }
    }
}

/// Pre-execute hook to show version if requested
pub fn preExecute(
    context: *zcli.Context,
    args: zcli.ParsedArgs,
) !?zcli.ParsedArgs {
    const version_requested = context.getGlobalData([]const u8, "version_requested") orelse "false";
    if (std.mem.eql(u8, version_requested, "true")) {
        try showVersion(context);
        // Return null to stop execution
        return null;
    }

    // Continue normal execution
    return args;
}

/// Display version information
fn showVersion(context: *zcli.Context) !void {
    const stdout = context.stdout();
    try stdout.print("{s} v{s}\n", .{ context.app_name, context.app_version });
}

// ============================================================================
// Tests
// ============================================================================

test "version plugin global option" {
    const allocator = std.testing.allocator;

    var context = zcli.Context{
        .allocator = allocator,
        .io = zcli.IO.init(),
        .environment = zcli.Environment.init(),
        .plugin_extensions = zcli.ContextExtensions.init(allocator),
        .app_name = "test-app",
        .app_version = "1.2.3",
        .app_description = "Test application",
        .available_commands = &.{},
        .command_path = &.{},
        .plugin_command_info = &.{},
    };
    defer context.deinit();

    // Test handling version option
    try handleGlobalOption(&context, "version", true);

    const version_requested = context.getGlobalData([]const u8, "version_requested");
    try std.testing.expect(version_requested != null);
    try std.testing.expectEqualStrings("true", version_requested.?);
}

test "version plugin preExecute stops execution" {
    const allocator = std.testing.allocator;

    var context = zcli.Context{
        .allocator = allocator,
        .io = zcli.IO.init(),
        .environment = zcli.Environment.init(),
        .plugin_extensions = zcli.ContextExtensions.init(allocator),
        .app_name = "test-app",
        .app_version = "1.2.3",
        .app_description = "Test application",
        .available_commands = &.{},
        .command_path = &.{},
        .plugin_command_info = &.{},
    };
    defer context.deinit();

    // Set version requested
    try context.setGlobalData("version_requested", "true");

    // preExecute should return null to stop execution
    const result = try preExecute(&context, .{ .positional = &.{} });
    try std.testing.expect(result == null);
}

test "version plugin preExecute continues without flag" {
    const allocator = std.testing.allocator;

    var context = zcli.Context{
        .allocator = allocator,
        .io = zcli.IO.init(),
        .environment = zcli.Environment.init(),
        .plugin_extensions = zcli.ContextExtensions.init(allocator),
        .app_name = "test-app",
        .app_version = "1.2.3",
        .app_description = "Test application",
        .available_commands = &.{},
        .command_path = &.{},
        .plugin_command_info = &.{},
    };
    defer context.deinit();

    const args = zcli.ParsedArgs{ .positional = &.{} };

    // Without version flag, should continue execution
    const result = try preExecute(&context, args);
    try std.testing.expect(result != null);
}
