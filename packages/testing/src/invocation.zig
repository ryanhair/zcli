//! In-process tests of the production registry lifecycle. Unlike runCommand,
//! this accepts argv and runs routing, resolution, plugins, and failure policy.
const std = @import("std");
const zcli = @import("zcli");

pub const InvocationOptions = struct {
    /// Arguments after the executable name.
    argv: []const []const u8 = &.{},
    /// Omitted input is an empty stream, never the developer's real terminal.
    stdin: []const u8 = "",
    /// Omitted environment is empty, independent of the parent process.
    environ: ?*const std.process.Environ.Map = null,
    allocator: std.mem.Allocator = std.testing.allocator,
};

/// Captured output and the registry's owned result. Release both with deinit().
pub const Result = struct {
    stdout: []const u8,
    stderr: []const u8,
    invocation: zcli.InvocationResult,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        self.invocation.deinit();
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }
};

/// Run a compiled registry through its normal, non-exiting invocation engine.
/// `Registry` is a compiled registry type or the generated command_registry
/// module; both expose init(). Use the real generated module, not a unit stub.
pub fn runInvocation(comptime Registry: type, options: InvocationOptions) !Result {
    const allocator = options.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();
    var input: std.Io.Reader = .fixed(options.stdin);
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    stdio.stdout_override = &out.writer;
    stdio.stderr_override = &err.writer;
    stdio.stdin_override = &input;

    var empty_env = std.process.Environ.Map.init(allocator);
    defer empty_env.deinit();
    var registry = Registry.init();
    var invocation = try registry.invokeWithStdio(
        allocator,
        std.testing.io,
        options.environ orelse &empty_env,
        options.argv,
        &stdio,
    );
    errdefer invocation.deinit();
    const stdout = try allocator.dupe(u8, out.written());
    errdefer allocator.free(stdout);
    const stderr = try allocator.dupe(u8, err.written());
    return .{ .stdout = stdout, .stderr = stderr, .invocation = invocation, .allocator = allocator };
}

const Echo = struct {
    pub const Args = struct { name: []const u8 };
    pub const Options = struct {};
    pub fn execute(args: Args, _: Options, context: anytype) !void {
        const text = try context.stdin().allocRemaining(context.allocator, .limited(1024));
        try context.stdout().print("{s}:{s}", .{ args.name, text });
    }
};

const app_config: zcli.Config = .{
    .app_name = "invocation-test",
    .app_version = "1.0",
    .app_description = "Invocation harness fixture",
    .exit_codes = .{ .usage = 64, .command_not_found = 64 },
};

test "runInvocation parses argv and captures exact injected stdin" {
    const App = zcli.Registry.init(app_config).register("echo", Echo).build();
    var result = try runInvocation(App, .{ .argv = &.{ "echo", "name" }, .stdin = "hello\n" });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.invocation.status);
    try std.testing.expect(result.invocation.outcome == .success);
    try std.testing.expectEqualStrings("name:hello\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "runInvocation defaults to EOF and returns configured usage status" {
    const App = zcli.Registry.init(app_config).register("echo", Echo).build();
    var empty = try runInvocation(App, .{ .argv = &.{ "echo", "name" } });
    defer empty.deinit();
    try std.testing.expectEqualStrings("name:", empty.stdout);

    var missing = try runInvocation(App, .{ .argv = &.{"echo"} });
    defer missing.deinit();
    try std.testing.expectEqual(@as(u8, 64), missing.invocation.status);
    const failure = missing.invocation.outcome.failure;
    try std.testing.expect(failure.isUsage());
    try std.testing.expectEqual(error.ArgumentMissingRequired, failure.cause);
    try std.testing.expect(failure.diagnostic != null);
    try std.testing.expect(missing.stderr.len > 0);
}

test "runInvocation retains a contextual failure after invocation cleanup" {
    const Command = struct {
        pub const Args = struct { name: []const u8 };
        pub const Options = struct {};
        pub fn execute(args: Args, _: Options, context: anytype) !void {
            return context.fail("missing item: {s}", .{args.name});
        }
    };
    const App = zcli.Registry.init(app_config).register("find", Command).build();
    var name = "widget".*;
    var result = try runInvocation(App, .{ .argv = &.{ "find", &name } });
    defer result.deinit();
    @memset(&name, 'x');
    try std.testing.expectEqual(@as(u8, 1), result.invocation.status);
    try std.testing.expectEqualStrings("missing item: widget", result.invocation.outcome.failure.message.?);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "missing item: widget") != null);
}

test "runInvocation combines stdin text resolution with literal repeatable prose" {
    const Author = struct {
        pub const Args = struct {};
        pub const Options = struct {
            body: []const u8,
            ac: []const []const u8 = &.{},
        };
        pub const meta = .{ .options = .{
            .body = .{ .stdin = true },
            .ac = .{ .short = 'a' },
        } };
        pub fn execute(_: Args, options: Options, context: anytype) !void {
            try std.json.Stringify.value(.{ .body = options.body, .ac = options.ac }, .{}, context.stdout());
        }
    };
    const App = zcli.Registry.init(app_config).register("author", Author).build();
    var result = try runInvocation(App, .{
        .argv = &.{ "author", "--body=-", "--ac", "a, b", "-ac" },
        .stdin = "hello\n",
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.invocation.status);
    try std.testing.expectEqualStrings("{\"body\":\"hello\\n\",\"ac\":[\"a, b\",\"c\"]}", result.stdout);
}
