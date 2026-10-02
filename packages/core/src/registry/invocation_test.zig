const std = @import("std");
const zcli = @import("../zcli.zig");
const testing = std.testing;

const Capture = struct {
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    stdio: zcli.Stdio,
    env: std.process.Environ.Map,
    fn init(self: *Capture) void {
        self.out = .init(testing.allocator);
        self.err = .init(testing.allocator);
        self.env = .init(testing.allocator);
        self.stdio.init(testing.io);
        self.stdio.stdout_override = &self.out.writer;
        self.stdio.stderr_override = &self.err.writer;
    }
    fn deinit(self: *Capture) void {
        self.out.deinit();
        self.err.deinit();
        self.env.deinit();
    }
    fn invoke(self: *Capture, app: anytype, args: []const []const u8) !zcli.InvocationResult {
        return app.invokeWithStdio(testing.allocator, testing.io, &self.env, args, &self.stdio);
    }
};
const Noop = struct {
    pub const Args = struct {};
    pub const Options = struct { count: u32 = 0 };
    pub fn execute(_: Args, _: Options, _: anytype) !void {}
};
const Collision = struct {
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, _: anytype) !void {
        return error.OptionUnknown;
    }
};

test "outcomes retain framework provenance and owned structured diagnostics" {
    const App = zcli.Registry.init(.{ .app_name = "test", .app_version = "1", .app_description = "", .exit_codes = .{ .usage = 64, .command_not_found = 65 } })
        .register("ok", Noop).register("collision", Collision).build();
    var app = App.init();
    var capture: Capture = undefined;
    capture.init();
    defer capture.deinit();
    var argv = [_]u8{ 'x', 'x', 'x' };
    var invalid = try capture.invoke(&app, &.{ "ok", "--count", &argv });
    defer invalid.deinit();
    @memset(&argv, 'z');
    try testing.expectEqual(@as(u8, 64), invalid.status);
    try testing.expect(invalid.outcome.failure.isUsage());
    try testing.expectEqualStrings("xxx", invalid.outcome.failure.diagnostic.?.OptionInvalidValue.provided_value);
    var collision = try capture.invoke(&app, &.{"collision"});
    defer collision.deinit();
    try testing.expectEqual(zcli.failure.Category.unexpected, collision.outcome.failure.category);
    try testing.expectEqual(zcli.failure.Origin.command, collision.outcome.failure.origin);
    var unknown = try capture.invoke(&app, &.{"absent"});
    defer unknown.deinit();
    try testing.expectEqual(@as(u8, 65), unknown.status);
}

const Lifecycle = struct {
    pub const plugin_id = "lifecycle";
    pub const ContextData = struct { json: bool = false, help: bool = false };
    var prepared: bool = false;
    var finished: bool = false;
    var released: bool = false;
    pub const global_options = [_]zcli.GlobalOption{
        zcli.option("json", bool, .{}), zcli.option("help", bool, .{}), zcli.option("number", u8, .{}),
    };
    pub fn handleGlobalOption(ctx: anytype, name: []const u8, value: anytype) !void {
        if (comptime @TypeOf(value) == bool) {
            if (std.mem.eql(u8, name, "json")) ctx.plugins.lifecycle.json = value;
            if (std.mem.eql(u8, name, "help")) ctx.plugins.lifecycle.help = value;
        }
    }
    pub fn handleInformation(ctx: anytype) !zcli.InvocationAction {
        if (ctx.plugins.lifecycle.help) return .complete;
        return .proceed;
    }
    pub fn prepare(_: anytype) !void {
        prepared = true;
        return error.Unauthorized;
    }
    pub fn onFinish(_: anytype, _: bool) !void {
        finished = true;
    }
    pub fn deinitContextData(_: *ContextData, _: std.mem.Allocator) void {
        released = true;
    }
};
const Policy = struct {
    pub const error_codes = [_]zcli.failure.ErrorRule{.{ .cause = error.Unauthorized, .code = 10, .plugin = "lifecycle", .id = "auth", .message = "Sign in first" }};
    pub fn renderFailure(ctx: anytype, failure: zcli.Failure, status: u8) !void {
        if (ctx.plugins.lifecycle.json) {
            try ctx.stderr().print("{{\"id\":\"{s}\",\"status\":{d}}}\n", .{ failure.id orelse "usage", status });
        } else try ctx.stderr().writeAll("human\n");
    }
};

test "preparation follows validation and information, mapping sees global options" {
    const App = zcli.Registry.init(.{ .app_name = "test", .app_version = "1", .app_description = "", .failure_policy = Policy })
        .register("ok", Noop).registerPlugin(Lifecycle).build();
    var app = App.init();
    var capture: Capture = undefined;
    capture.init();
    defer capture.deinit();
    Lifecycle.prepared = false;
    Lifecycle.finished = false;
    Lifecycle.released = false;
    var invalid = try capture.invoke(&app, &.{ "--json", "ok", "--count", "bad" });
    defer invalid.deinit();
    try testing.expectEqual(@as(u8, 2), invalid.status);
    try testing.expect(!Lifecycle.prepared);
    try testing.expect(Lifecycle.finished and Lifecycle.released);
    capture.err.clearRetainingCapacity();
    var help = try capture.invoke(&app, &.{ "--help", "ok", "--count", "bad" });
    defer help.deinit();
    try testing.expect(help.outcome == .completed);
    try testing.expect(!Lifecycle.prepared);
    var unauthorized = try capture.invoke(&app, &.{ "--json", "ok" });
    defer unauthorized.deinit();
    try testing.expectEqual(@as(u8, 10), unauthorized.status);
    try testing.expectEqual(zcli.failure.Stage.preparation, unauthorized.outcome.failure.stage);
    try testing.expectEqualStrings("{\"id\":\"auth\",\"status\":10}\n", capture.err.written());
    capture.err.clearRetainingCapacity();
    var invalid_global = try capture.invoke(&app, &.{ "--json", "--number", "bad", "ok" });
    defer invalid_global.deinit();
    try testing.expect(std.mem.startsWith(u8, capture.err.written(), "Error: Invalid value"));
}

const BrokenRenderer = struct {
    pub fn renderFailure(ctx: anytype, _: zcli.Failure, _: u8) !void {
        try ctx.stderr().writeAll("{partial json");
        return error.RenderFailed;
    }
};
const Fails = struct {
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, ctx: anytype) !void {
        return ctx.fail("invalid version '{s}'", .{"\x1b]52;c;payload\x07"});
    }
};
const Cleanup = struct {
    pub fn onFinish(_: anytype, _: bool) !void {
        return error.CleanupFailed;
    }
};
test "renderer and cleanup failures preserve primary outcome without partial output" {
    const App = zcli.Registry.init(.{ .app_name = "test", .app_version = "1", .app_description = "", .failure_policy = BrokenRenderer })
        .register("fail", Fails).registerPlugin(Cleanup).build();
    var app = App.init();
    var capture: Capture = undefined;
    capture.init();
    defer capture.deinit();
    var result = try capture.invoke(&app, &.{"fail"});
    defer result.deinit();
    try testing.expectEqual(error.CommandFailed, result.outcome.failure.cause);
    try testing.expectEqual(@as(usize, 2), result.secondary_errors.len);
    try testing.expectEqualStrings("invalid version ']52;c;payload'\n", capture.err.written());
}

fn FailingHook(comptime at: zcli.failure.Stage) type {
    return struct {
        pub const plugin_id = "broken";
        pub const ContextData = struct {};
        pub const global_options = [_]zcli.GlobalOption{zcli.option("trip", bool, .{})};
        pub fn initContextData(_: *ContextData, _: anytype) !void {
            if (at == .initialization) return error.HookFailed;
        }
        pub fn onStartup(_: anytype) !void {
            if (at == .startup) return error.HookFailed;
        }
        pub fn preParse(_: anytype, args: []const []const u8) ![]const []const u8 {
            if (at == .pre_parse) return error.HookFailed;
            return args;
        }
        pub fn handleGlobalOption(_: anytype, _: []const u8, _: anytype) !void {
            if (at == .global_options) return error.HookFailed;
        }
        pub fn transformArgs(_: anytype, args: []const []const u8) !zcli.TransformResult {
            if (at == .transform) return error.HookFailed;
            return .{ .args = args };
        }
        pub fn postParse(_: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs {
            if (at == .parsing) return error.HookFailed;
            return args;
        }
        pub fn handleInformation(_: anytype) !zcli.InvocationAction {
            if (at == .information) return error.HookFailed;
            return .proceed;
        }
        pub fn loadConfig(_: anytype) !void {
            if (at == .configuration) return error.HookFailed;
        }
        pub fn prepare(_: anytype) !void {
            if (at == .preparation) return error.HookFailed;
        }
        pub fn onFinish(_: anytype, _: bool) !void {
            if (at == .completion) return error.HookFailed;
        }
    };
}
const HookPolicy = struct {
    pub const error_codes = [_]zcli.failure.ErrorRule{.{ .cause = error.HookFailed, .code = 10, .plugin = "broken", .silent = true }};
};
test "every fallible hook uses the same scoped failure policy" {
    inline for (.{ zcli.failure.Stage.initialization, .startup, .pre_parse, .global_options, .transform, .parsing, .information, .configuration, .preparation, .completion }) |stage| {
        const App = zcli.Registry.init(.{ .app_name = "test", .app_version = "1", .app_description = "", .failure_policy = HookPolicy })
            .register("ok", Noop).registerPlugin(FailingHook(stage)).build();
        var app = App.init();
        var capture: Capture = undefined;
        capture.init();
        defer capture.deinit();
        var result = try capture.invoke(&app, &.{ "--trip", "ok" });
        defer result.deinit();
        try testing.expectEqual(@as(u8, 10), result.status);
        try testing.expectEqual(stage, result.outcome.failure.stage);
        try testing.expectEqualStrings("broken", result.outcome.failure.origin.plugin);
        try testing.expectEqual(error.HookFailed, result.outcome.failure.cause);
        try testing.expectEqual(@as(usize, 0), capture.err.written().len);
    }
}

test "classified failures outrank stream failure, successful output cannot hide a failed flush" {
    const App = zcli.Registry.init(.{ .app_name = "test", .app_version = "1", .app_description = "", .exit_codes = .{ .usage = 64 } }).register("ok", Noop).build();
    var app = App.init();
    var capture: Capture = undefined;
    capture.init();
    defer capture.deinit();
    // The recorded cause is the same state a buffered flush failure leaves.
    capture.stdio.stdout_override = null;
    capture.stdio.stdout_writer.err = error.NoSpaceLeft;
    var misuse = try capture.invoke(&app, &.{ "ok", "--bogus" });
    defer misuse.deinit();
    try testing.expectEqual(@as(u8, 64), misuse.status);
    var success = try capture.invoke(&app, &.{"ok"});
    defer success.deinit();
    try testing.expectEqual(@as(u8, 1), success.status);
    try testing.expectEqual(zcli.failure.Category.io, success.outcome.failure.category);
    capture.stdio.stdout_writer.err = error.BrokenPipe;
    var pipe = try capture.invoke(&app, &.{"ok"});
    defer pipe.deinit();
    try testing.expectEqual(@as(u8, 141), pipe.status);
}

test "later completion failures cannot replace first completion explanation" {
    const First = struct {
        pub fn onFinish(ctx: anytype, _: bool) !void {
            return ctx.failWith(error.FirstCleanup, "first cleanup", .{});
        }
    };
    const Second = struct {
        pub fn onFinish(ctx: anytype, _: bool) !void {
            return ctx.failWith(error.SecondCleanup, "second cleanup", .{});
        }
    };
    const App = zcli.Registry.init(.{ .app_name = "test", .app_version = "1", .app_description = "", .exit_codes = .{ .command_failed = 7 } })
        .register("ok", Noop).registerPlugin(First).registerPlugin(Second).build();
    var app = App.init();
    var capture: Capture = undefined;
    capture.init();
    defer capture.deinit();
    var result = try capture.invoke(&app, &.{"ok"});
    defer result.deinit();
    try testing.expectEqual(@as(u8, 7), result.status);
    try testing.expectEqual(error.FirstCleanup, result.outcome.failure.cause);
    try testing.expectEqualStrings("first cleanup", result.outcome.failure.message.?);
    try testing.expectEqualStrings("first cleanup\n", capture.err.written());
    try testing.expectEqual(error.SecondCleanup, result.secondary_errors[0]);
}

test "failure callbacks cannot replace primary message or diagnostic through context.fail" {
    const Corrupting = struct {
        pub fn describeFailure(ctx: anytype, _: zcli.Failure) !?zcli.failure.Description {
            ctx.diagnostic = null;
            return ctx.failWith(error.DescriptionFailed, "secondary description", .{});
        }
        pub fn renderFailure(ctx: anytype, _: zcli.Failure, _: u8) !void {
            ctx.diagnostic = null;
            try ctx.stderr().writeAll("partial");
            return ctx.failWith(error.RenderingFailed, "secondary renderer", .{});
        }
    };
    const App = zcli.Registry.init(.{ .app_name = "test", .app_version = "1", .app_description = "", .failure_policy = Corrupting })
        .register("fail", Fails).register("ok", Noop).build();
    var app = App.init();
    var capture: Capture = undefined;
    capture.init();
    defer capture.deinit();
    var fail_result = try capture.invoke(&app, &.{"fail"});
    defer fail_result.deinit();
    try testing.expectEqual(error.CommandFailed, fail_result.outcome.failure.cause);
    try testing.expectEqualStrings("invalid version ']52;c;payload'\n", capture.err.written());
    try testing.expectEqual(@as(usize, 2), fail_result.secondary_errors.len);
    capture.err.clearRetainingCapacity();
    var parse_result = try capture.invoke(&app, &.{ "ok", "--count", "bad" });
    defer parse_result.deinit();
    try testing.expectEqual(@as(u8, 2), parse_result.status);
    try testing.expectEqualStrings("bad", parse_result.outcome.failure.diagnostic.?.OptionInvalidValue.provided_value);
    try testing.expect(std.mem.startsWith(u8, capture.err.written(), "Error: Invalid value 'bad'"));
}

test "allocation failure while retaining diagnostics cannot replace classified status" {
    const Exhausted = struct {
        var exhausted_allocator: testing.FailingAllocator = undefined;
        pub const Args = struct {};
        pub const Options = struct {};
        pub fn execute(_: Args, _: Options, ctx: anytype) !void {
            exhausted_allocator = testing.FailingAllocator.init(ctx.allocator, .{ .fail_index = 0 });
            ctx.allocator = exhausted_allocator.allocator();
            return error.NotFound;
        }
    };
    const Mapped = struct {
        pub const error_codes = [_]zcli.failure.ErrorRule{.{ .cause = error.NotFound, .code = 9, .command = "run", .message = "missing" }};
    };
    const App = zcli.Registry.init(.{ .app_name = "test", .app_version = "1", .app_description = "", .failure_policy = Mapped }).register("run", Exhausted).build();
    var app = App.init();
    var capture: Capture = undefined;
    capture.init();
    defer capture.deinit();
    var result = try capture.invoke(&app, &.{"run"});
    defer result.deinit();
    try testing.expectEqual(@as(u8, 9), result.status);
    try testing.expectEqual(error.NotFound, result.outcome.failure.cause);
    try testing.expectEqualStrings("missing\n", capture.err.written());
}

test "aliases use canonical command policy and completion cannot retarget a primary failure" {
    const Aliased = struct {
        pub const meta = .{ .aliases = &.{"f"} };
        pub const Args = struct {};
        pub const Options = struct {};
        pub fn execute(_: Args, _: Options, _: anytype) !void {
            return error.ScopedFailure;
        }
    };
    const ScopedPolicy = struct {
        pub const error_codes = [_]zcli.failure.ErrorRule{.{ .cause = error.ScopedFailure, .code = 9, .command = "fail", .message = "mapped" }};
    };
    const RetargetingCleanup = struct {
        pub fn onFinish(ctx: anytype, _: bool) !void {
            ctx.command_path = &.{"wrong"};
            ctx.canonical_command_path = &.{"wrong"};
            ctx.command_arguments = &.{"wrong"};
            return error.CleanupFailed;
        }
    };
    const App = zcli.Registry.init(.{ .app_name = "test", .app_version = "1", .app_description = "", .failure_policy = ScopedPolicy })
        .register("fail", Aliased).registerPlugin(RetargetingCleanup).build();
    var app = App.init();
    inline for (.{ "fail", "f" }) |invoked| {
        var capture: Capture = undefined;
        capture.init();
        defer capture.deinit();
        var result = try capture.invoke(&app, &.{invoked});
        defer result.deinit();
        try testing.expectEqual(@as(u8, 9), result.status);
        try testing.expectEqual(error.ScopedFailure, result.outcome.failure.cause);
        try testing.expectEqualStrings(invoked, result.outcome.failure.command_path[0]);
        try testing.expectEqualStrings("mapped\n", capture.err.written());
        try testing.expectEqual(error.CleanupFailed, result.secondary_errors[0]);
    }
}
