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

// Note: end-to-end coverage (—version prints and skips execution, -V, and the
// onError path for --version on a bogus command, running through a real
// registry) lives in plugin_pipeline_test.zig. These tests instead exercise
// this file's functions directly, driving `context` by hand.

fn newTestCtx(allocator: std.mem.Allocator, stdio: *zcli.Stdio, environ: *const std.process.Environ.Map) zcli.TestContext(&.{@This()}) {
    const Ctx = zcli.TestContext(&.{@This()});
    var ctx = Ctx.init(allocator, std.testing.io, stdio, environ);
    ctx.app_name = "myapp";
    ctx.app_version = "2.3.4";
    return ctx;
}

test "showVersion prints '<name> v<version>' to stdout" {
    const allocator = std.testing.allocator;

    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    stdio.stdout_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = newTestCtx(allocator, &stdio, &environ);
    defer ctx.deinit();

    try showVersion(&ctx);
    try ctx.stdout().flush();

    try std.testing.expectEqualStrings("myapp v2.3.4\n", aw.written());
}

test "handleGlobalOption sets version_requested only for a true 'version' value" {
    const allocator = std.testing.allocator;

    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const environ = std.process.Environ.Map.init(allocator);
    var ctx = newTestCtx(allocator, &stdio, &environ);
    defer ctx.deinit();

    // An unrelated global option is ignored.
    try handleGlobalOption(&ctx, "color", true);
    try std.testing.expect(!ctx.plugins.zcli_version.version_requested);

    // `version` with a false value (shouldn't normally happen, but the
    // handler only acts on `true`) leaves the flag unset.
    try handleGlobalOption(&ctx, "version", false);
    try std.testing.expect(!ctx.plugins.zcli_version.version_requested);

    // `version` with true sets it.
    try handleGlobalOption(&ctx, "version", true);
    try std.testing.expect(ctx.plugins.zcli_version.version_requested);
    try std.testing.expect(isVersionRequested(&ctx));
}

test "preExecute prints the version and stops execution when requested" {
    const allocator = std.testing.allocator;

    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    stdio.stdout_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = newTestCtx(allocator, &stdio, &environ);
    defer ctx.deinit();

    ctx.plugins.zcli_version.version_requested = true;
    const args = zcli.ParsedArgs{ .positional = &.{} };
    const result = try preExecute(&ctx, args);
    try ctx.stdout().flush();

    // null tells the registry to stop — the command never runs.
    try std.testing.expect(result == null);
    try std.testing.expectEqualStrings("myapp v2.3.4\n", aw.written());
}

test "preExecute passes args through unchanged when version wasn't requested" {
    const allocator = std.testing.allocator;

    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    stdio.stdout_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = newTestCtx(allocator, &stdio, &environ);
    defer ctx.deinit();

    const args = zcli.ParsedArgs{ .positional = &.{"greet"} };
    const result = try preExecute(&ctx, args);
    try ctx.stdout().flush();

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.positional.len);
    try std.testing.expectEqualStrings("", aw.written()); // nothing printed
}

test "onError prints the version and reports handled only when version was requested" {
    const allocator = std.testing.allocator;

    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    stdio.stdout_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = newTestCtx(allocator, &stdio, &environ);
    defer ctx.deinit();

    // Not requested: CommandNotFound passes through untouched.
    try std.testing.expect(!(try onError(&ctx, error.CommandNotFound)));
    try std.testing.expectEqualStrings("", aw.written());

    // A different error, even when requested, is not this plugin's to handle.
    ctx.plugins.zcli_version.version_requested = true;
    try std.testing.expect(!(try onError(&ctx, error.ArgumentInvalidValue)));
    try std.testing.expectEqualStrings("", aw.written());

    // Requested + CommandNotFound: prints the version and reports handled.
    try std.testing.expect(try onError(&ctx, error.CommandNotFound));
    try ctx.stdout().flush();
    try std.testing.expectEqualStrings("myapp v2.3.4\n", aw.written());
}
