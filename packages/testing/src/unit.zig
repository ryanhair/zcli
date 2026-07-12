//! In-process command testing utilities for zcli.
//!
//! Runs a command's execute() function directly without spawning a subprocess,
//! capturing stdout and stderr output for assertions. Includes a virtual
//! terminal (VTerm) for testing colors, formatting, and cursor positioning.
//!
//! Exposed as its own module (`zcli_testing_unit`, imported as `zcli-testing` in
//! scaffolded command tests) rather than folded into `zcli_testing`, so the
//! subprocess/PTY tiers stay free of the zcli/vterm dependencies below.
//!
//! ```zig
//! const testing = @import("zcli-testing");
//!
//! test "add command" {
//!     var result = try testing.runCommand(AddCommand, .{
//!         .args = .{ .name = "widget" },
//!         .options = .{ .verbose = true },
//!     });
//!     defer result.deinit();
//!
//!     // Assert on raw text
//!     try std.testing.expectEqualStrings("Added widget\n", result.stdout);
//!
//!     // Assert on rendered terminal output (colors, formatting)
//!     try std.testing.expect(result.term.containsText("Added widget"));
//! }
//! ```

const std = @import("std");
const zcli = @import("zcli");
const vterm = @import("vterm");

/// Result of running a command in-process.
pub const CommandResult = struct {
    /// Raw stdout text including ANSI escape sequences.
    stdout: []const u8,
    /// Raw stderr text including ANSI escape sequences.
    stderr: []const u8,
    /// Whether execute() returned without error.
    success: bool,
    /// The error if execute() failed.
    err: ?anyerror = null,
    /// Virtual terminal with stdout rendered — use for asserting on
    /// colors, text positioning, bold/italic, and formatted output.
    term: vterm.VTerm,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CommandResult) void {
        self.term.deinit();
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// True when every field of `T` has a default value, so `T{}` compiles.
fn isDefaultConstructible(comptime T: type) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.default_value_ptr == null) return false;
    }
    return true;
}

/// Field attributes for a `runCommand` `args`/`options` field: it carries a
/// default (so the caller may omit it) only when `T` is default-constructible.
/// When `T` has a required field, the config field is required too — so
/// omitting `.args`/`.options` for such a command is a plain "missing struct
/// field" compile error at the call site, not a cryptic one inside a default.
fn fieldAttrs(comptime T: type) std.builtin.Type.StructField.Attributes {
    const default_ptr: ?*const anyopaque = if (isDefaultConstructible(T)) blk: {
        const value: T = .{};
        break :blk &value;
    } else null;
    return .{ .default_value_ptr = default_ptr };
}

/// The Context type a `runCommand` builds for `Command`, derived from the
/// concrete `context: *Context` parameter of `Command.execute` (a scaffolded
/// command). The project's plugins are already in scope on that Context, so a
/// test can set their state via `.plugins`. A `context: anytype` command has no
/// recoverable Context type and cannot be tested this way.
fn ContextTypeFor(comptime Command: type) type {
    return contextParamType(Command) orelse @compileError(
        "runCommand needs a command with a concrete `context: *Context` (a scaffolded command); " ++
            "`context: anytype` commands can't be tested this way — give it a concrete " ++
            "`*zcli.TestContext(&.{...})`.",
    );
}

/// The concrete type behind `execute`'s context parameter, or null when it is
/// generic (`anytype`).
fn contextParamType(comptime Command: type) ?type {
    const params = @typeInfo(@TypeOf(Command.execute)).@"fn".params;
    const param = params[params.len - 1].type orelse return null;
    return switch (@typeInfo(param)) {
        .pointer => |ptr| ptr.child,
        else => param,
    };
}

/// The `config` parameter type for `runCommand`, tailored to `Command`: `args`/
/// `options` are only optional-to-pass when default-constructible, and `plugins`
/// sets the command's plugin state (`.plugins = .{ .verbose = .{ .enabled = true } }`).
fn RunConfig(comptime Command: type) type {
    const default_alloc: std.mem.Allocator = std.testing.allocator;
    const PluginData = @FieldType(ContextTypeFor(Command), "plugins");
    const default_plugins: PluginData = .{};
    const names = [_][]const u8{ "args", "options", "allocator", "plugins" };
    const field_types = [_]type{ Command.Args, Command.Options, std.mem.Allocator, PluginData };
    const attrs = [_]std.builtin.Type.StructField.Attributes{
        fieldAttrs(Command.Args),
        fieldAttrs(Command.Options),
        .{ .default_value_ptr = &default_alloc },
        .{ .default_value_ptr = &default_plugins },
    };
    return @Struct(.auto, null, &names, &field_types, &attrs);
}

/// Run a command's execute() function in-process with captured I/O.
///
/// The command must have Args, Options, and an `execute` taking a concrete
/// `context: *Context` — the Context (with the project's plugins) is derived
/// from it. Set plugin state via `.plugins = .{ .<id> = .{ ... } }`.
///
/// Pass `.args`/`.options` to drive the command. They may be omitted only
/// when the command's Args/Options are default-constructible (every field has
/// a default); a command with a required positional or option must be given
/// `.args`/`.options` or the call fails to compile with "missing struct field".
pub fn runCommand(
    comptime Command: type,
    config: RunConfig(Command),
) !CommandResult {
    const allocator = config.allocator;
    const args = config.args;
    const options = config.options;

    // Capture output using allocating writers
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer stderr_aw.deinit();

    // Create the standard-stream holder with overrides for capturing
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    stdio.stdout_override = &stdout_aw.writer;
    stdio.stderr_override = &stderr_aw.writer;

    // Arena-per-command allocator: mirror the runtime (Registry.execute) so a
    // command written to never free is leak-free under unit tests too, not just
    // in production. Command-body allocations are reclaimed when the arena is
    // dropped; the capture writers and vterm below stay on `allocator` so the
    // testing allocator still catches harness leaks.
    // See docs/adr/0001-arena-per-command-allocator.md.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Build the command's own Context (so a scaffolded command's project plugins
    // are in scope), with an empty environment; commands that read env vars
    // should take them as options instead.
    const test_environ = std.process.Environ.Map.init(allocator);
    const Ctx = ContextTypeFor(Command);
    var context = Ctx{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .stdio = &stdio,
        .environ = &test_environ,
        .plugins = config.plugins,
    };
    defer context.deinit();

    // Execute the command
    var success = true;
    var err: ?anyerror = null;
    Command.execute(args, options, &context) catch |e| {
        success = false;
        err = e;
    };

    // Get captured output
    var stdout_al = stdout_aw.toArrayList();
    const stdout_content = try stdout_al.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_content);
    var stderr_al = stderr_aw.toArrayList();
    const stderr_content = try stderr_al.toOwnedSlice(allocator);
    errdefer allocator.free(stderr_content);

    // Feed stdout through virtual terminal for rich assertions
    var term = try vterm.VTerm.init(allocator, 80, 24);
    errdefer term.deinit();
    term.write(stdout_content);

    return .{
        .stdout = stdout_content,
        .stderr = stderr_content,
        .success = success,
        .err = err,
        .term = term,
        .allocator = allocator,
    };
}

// Tests
test "runCommand captures stdout" {
    const Ctx = zcli.TestContext(&.{});
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: *Ctx) !void {
            const writer = context.stdout();
            try writer.writeAll("hello world\n");
        }
    };

    var result = try runCommand(TestCommand, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings("hello world\n", result.stdout);
    try std.testing.expect(result.stderr.len == 0);
    try std.testing.expect(result.success);
}

test "runCommand captures stderr" {
    const Ctx = zcli.TestContext(&.{});
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: *Ctx) !void {
            const writer = context.stderr();
            try writer.writeAll("error occurred\n");
        }
    };

    var result = try runCommand(TestCommand, .{});
    defer result.deinit();

    try std.testing.expect(result.stdout.len == 0);
    try std.testing.expectEqualStrings("error occurred\n", result.stderr);
}

test "runCommand captures error" {
    const Ctx = zcli.TestContext(&.{});
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, _: *Ctx) !void {
            return error.TestError;
        }
    };

    var result = try runCommand(TestCommand, .{});
    defer result.deinit();

    try std.testing.expect(!result.success);
    try std.testing.expect(result.err != null);
    try std.testing.expectEqual(error.TestError, result.err.?);
}

test "runCommand passes args and options" {
    const Ctx = zcli.TestContext(&.{});
    const TestCommand = struct {
        pub const Args = struct {
            name: []const u8 = "default",
        };
        pub const Options = struct {
            count: u32 = 1,
        };

        pub fn execute(args: Args, options: Options, context: *Ctx) !void {
            const writer = context.stdout();
            try writer.print("{s}: {d}\n", .{ args.name, options.count });
        }
    };

    var result = try runCommand(TestCommand, .{
        .args = .{ .name = "widget" },
        .options = .{ .count = 5 },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("widget: 5\n", result.stdout);
}

test "runCommand with a required (no-default) arg" {
    const Ctx = zcli.TestContext(&.{});
    const TestCommand = struct {
        pub const Args = struct {
            name: []const u8,
        };
        pub const Options = struct {};

        pub fn execute(args: Args, _: Options, context: *Ctx) !void {
            try context.stdout().print("hello {s}\n", .{args.name});
        }
    };

    var result = try runCommand(TestCommand, .{ .args = .{ .name = "Ada" } });
    defer result.deinit();

    try std.testing.expectEqualStrings("hello Ada\n", result.stdout);
}

test "runCommand captures context.fail as a failure with the message" {
    const Ctx = zcli.TestContext(&.{});
    const TestCommand = struct {
        pub const Args = struct { name: []const u8 };
        pub const Options = struct {};

        pub fn execute(args: Args, _: Options, context: *Ctx) !void {
            return context.fail("no such thing: {s}", .{args.name});
        }
    };

    var result = try runCommand(TestCommand, .{ .args = .{ .name = "widget" } });
    defer result.deinit();

    // context.fail() is a returned error, not a process exit — so a unit test
    // can assert on it: the command failed, and its message reached stderr.
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(error.CommandFailed, result.err.?);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "no such thing: widget") != null);
}

test "runCommand with plugin data" {
    const MockPlugin = struct {
        pub const plugin_id = "mock";
        pub const ContextData = struct {
            enabled: bool = false,
        };
    };

    const Ctx = zcli.TestContext(&.{MockPlugin});
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: *Ctx) !void {
            if (context.plugins.mock.enabled) {
                try context.stdout().writeAll("enabled\n");
            } else {
                try context.stdout().writeAll("disabled\n");
            }
        }
    };

    var result = try runCommand(TestCommand, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings("disabled\n", result.stdout);
}

test "runCommand sets plugin state for a command with a concrete context" {
    // A scaffolded command takes a concrete `context: *Context` whose plugins
    // come from the project (the command_registry stub). runCommand derives that
    // Context from the command, so the plugin field is in scope and a test drives
    // it via `.plugins` — no `@hasField` guard needed.
    const FlagPlugin = struct {
        pub const plugin_id = "flag";
        pub const ContextData = struct { on: bool = false };
    };
    const Ctx = zcli.TestContext(&.{FlagPlugin});
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: *Ctx) !void {
            try context.stdout().writeAll(if (context.plugins.flag.on) "flag on\n" else "flag off\n");
        }
    };

    // Default: the plugin's ContextData default (Context is derived).
    {
        var r = try runCommand(TestCommand, .{});
        defer r.deinit();
        try std.testing.expectEqualStrings("flag off\n", r.stdout);
    }
    // Set the plugin state via `.plugins`.
    {
        var r = try runCommand(TestCommand, .{ .plugins = .{ .flag = .{ .on = true } } });
        defer r.deinit();
        try std.testing.expectEqualStrings("flag on\n", r.stdout);
    }
}

test "runCommand vterm contains text" {
    const Ctx = zcli.TestContext(&.{});
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: *Ctx) !void {
            try context.stdout().writeAll("Hello World\n");
        }
    };

    var result = try runCommand(TestCommand, .{});
    defer result.deinit();

    try std.testing.expect(result.term.containsText("Hello World"));
    try std.testing.expect(!result.term.containsText("Goodbye"));
}

test "runCommand arena reclaims allocations for a command that never frees" {
    // The arena-per-command contract: business logic can allocate via
    // context.allocator and never call free. runCommand uses
    // std.testing.allocator, which panics on leak, so this test fails if the
    // arena is removed. See docs/adr/0001-arena-per-command-allocator.md.
    const Ctx = zcli.TestContext(&.{});
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: *Ctx) !void {
            // Several allocations of different sizes, none freed.
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                const buf = try context.allocator.alloc(u8, 64 * (i + 1));
                @memset(buf, 'x');
            }
            const dup = try context.allocator.dupe(u8, "leaked-on-purpose");
            try context.stdout().print("allocated {d} bytes\n", .{dup.len});
        }
    };

    var result = try runCommand(TestCommand, .{});
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expect(result.term.containsText("allocated 17 bytes"));
}

test "runCommand vterm detects ANSI formatting" {
    const Ctx = zcli.TestContext(&.{});
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: *Ctx) !void {
            try context.stdout().writeAll("\x1b[1mBold text\x1b[0m\n");
        }
    };

    var result = try runCommand(TestCommand, .{});
    defer result.deinit();

    // VTerm parses ANSI — text is there without escape codes
    try std.testing.expect(result.term.containsText("Bold text"));
    // The cell at the start of "Bold text" should have bold attribute
    try std.testing.expect(result.term.hasAttribute(0, 0, .bold));
}
