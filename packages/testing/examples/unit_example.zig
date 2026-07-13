//! Example: the **unit tier** — `runCommand`.
//!
//! `runCommand` executes a command's `execute()` in-process (no subprocess, no
//! compiled binary) and captures stdout/stderr plus a `vterm` screen. It is the
//! fastest test loop and what `zcli init` scaffolds into a command's own tests.
//!
//! This file is a runnable, commented sample: `zig build examples` compiles and
//! runs every `test` block below. It imports the unit tier under the alias
//! `zcli-testing` — the same import name scaffolded command tests use — so what
//! you read here is exactly what you'd write in a real project.
//!
//! A "command" is just a struct with `Args`, `Options`, and an `execute` taking
//! a concrete `context: *Context`. The examples define tiny inline commands; in
//! a real project these are your `src/commands/*.zig` files.

const std = @import("std");
const testing = @import("zcli-testing");

// ---------------------------------------------------------------------------
// 1. The basics: run a command, assert on its captured stdout.
// ---------------------------------------------------------------------------

test "captures stdout" {
    // `TestContext(&.{})` is a Context with no plugins. `runCommand` derives the
    // Context type from the command's `execute` signature, so the command and
    // the context agree by construction.
    const Ctx = zcli.TestContext(&.{});
    const Greet = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: *Ctx) !void {
            try context.stdout().writeAll("hello world\n");
        }
    };

    // `.{}` is the empty config: default (empty) args/options, the testing
    // allocator, default plugin state. `result` owns heap memory — always
    // `defer result.deinit()`.
    var result = try testing.runCommand(Greet, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings("hello world\n", result.stdout);
    try std.testing.expect(result.stderr.len == 0);
    try std.testing.expect(result.success); // execute() returned without error
}

// ---------------------------------------------------------------------------
// 2. Driving args and options.
// ---------------------------------------------------------------------------

test "passes args and options" {
    const Ctx = zcli.TestContext(&.{});
    const Repeat = struct {
        pub const Args = struct {
            // A required positional: no default value.
            name: []const u8,
        };
        pub const Options = struct {
            // An option with a default.
            count: u32 = 1,
        };

        pub fn execute(args: Args, options: Options, context: *Ctx) !void {
            var i: u32 = 0;
            while (i < options.count) : (i += 1) {
                try context.stdout().print("{s}\n", .{args.name});
            }
        }
    };

    // Because `name` has no default, `.args` is REQUIRED here — omitting it is a
    // plain "missing struct field" compile error at this call site. `.options`
    // is optional because every Options field has a default.
    var result = try testing.runCommand(Repeat, .{
        .args = .{ .name = "widget" },
        .options = .{ .count = 3 },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("widget\nwidget\nwidget\n", result.stdout);
}

// ---------------------------------------------------------------------------
// 3. Asserting on failure — errors and `context.fail`.
// ---------------------------------------------------------------------------

test "captures a returned error" {
    const Ctx = zcli.TestContext(&.{});
    const Boom = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, _: *Ctx) !void {
            return error.Boom;
        }
    };

    var result = try testing.runCommand(Boom, .{});
    defer result.deinit();

    // A failing command does NOT fail `runCommand`; the error is captured so you
    // can assert on it.
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(error.Boom, result.err.?);
}

test "captures context.fail message on stderr" {
    const Ctx = zcli.TestContext(&.{});
    const Reject = struct {
        pub const Args = struct { name: []const u8 };
        pub const Options = struct {};

        pub fn execute(args: Args, _: Options, context: *Ctx) !void {
            // `context.fail` is the idiomatic "user-facing failure": it prints a
            // message to stderr and returns error.CommandFailed. In a real run it
            // sets the process exit code; under runCommand it's just a captured
            // error, so tests can assert on both the error and the message.
            return context.fail("no such thing: {s}", .{args.name});
        }
    };

    var result = try testing.runCommand(Reject, .{ .args = .{ .name = "widget" } });
    defer result.deinit();

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(error.CommandFailed, result.err.?);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "no such thing: widget") != null);
}

// ---------------------------------------------------------------------------
// 4. Rendered-output assertions via the virtual terminal.
// ---------------------------------------------------------------------------

test "asserts on rendered terminal output" {
    const Ctx = zcli.TestContext(&.{});
    const Styled = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: *Ctx) !void {
            // Bold "Done", then reset.
            try context.stdout().writeAll("\x1b[1mDone\x1b[0m\n");
        }
    };

    var result = try testing.runCommand(Styled, .{});
    defer result.deinit();

    // `result.term` is a vterm that has parsed the ANSI stream. You assert on the
    // *visible* text (no escape codes) and on cell attributes — great for
    // verifying colors/formatting without brittle escape-sequence string matches.
    try std.testing.expect(result.term.containsText("Done"));
    try std.testing.expect(!result.term.containsText("Goodbye"));
    // Cell (row 0, col 0) — the "D" of "Done" — carries the bold attribute.
    try std.testing.expect(result.term.hasAttribute(0, 0, .bold));
}

// ---------------------------------------------------------------------------
// 5. Setting plugin state.
// ---------------------------------------------------------------------------

test "drives plugin context data" {
    // A plugin contributes a `ContextData` struct, reachable at
    // `context.plugins.<plugin_id>`. Tests set it via `.plugins`.
    const VerbosePlugin = struct {
        pub const plugin_id = "verbose";
        pub const ContextData = struct { enabled: bool = false };
    };

    const Ctx = zcli.TestContext(&.{VerbosePlugin});
    const Report = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: *Ctx) !void {
            if (context.plugins.verbose.enabled) {
                try context.stdout().writeAll("verbose: on\n");
            } else {
                try context.stdout().writeAll("verbose: off\n");
            }
        }
    };

    // Default plugin state (enabled = false).
    {
        var r = try testing.runCommand(Report, .{});
        defer r.deinit();
        try std.testing.expectEqualStrings("verbose: off\n", r.stdout);
    }
    // Override just the field(s) you care about.
    {
        var r = try testing.runCommand(Report, .{ .plugins = .{ .verbose = .{ .enabled = true } } });
        defer r.deinit();
        try std.testing.expectEqualStrings("verbose: on\n", r.stdout);
    }
}

// `zcli` is available in this example module because the `examples` build step
// wires it in (the unit tier already depends on it). Real projects import their
// own commands instead of defining them inline like these samples do.
const zcli = @import("zcli");
