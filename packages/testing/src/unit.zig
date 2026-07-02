//! In-process command testing utilities for zcli.
//!
//! Runs a command's execute() function directly without spawning a subprocess,
//! capturing stdout and stderr output for assertions. Includes a virtual
//! terminal (VTerm) for testing colors, formatting, and cursor positioning.
//!
//! ```zig
//! const testing = @import("testing");
//!
//! test "add command" {
//!     var result = try testing.runCommand(AddCommand, &.{}, .{
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

/// True if the command has an argument with no default (a required positional),
/// i.e. its `Args` is not default-constructible. The scaffolded co-located test
/// uses this to guard `runCommand(cmd, &.{}, .{})`: it auto-runs while every arg
/// is optional and comptime-compiles-away once a required arg is added (at which
/// point the author supplies real `.args`). Options are always defaulted, so
/// only `Args` needs checking.
pub fn hasRequiredArgs(comptime Command: type) bool {
    if (!@hasDecl(Command, "Args")) return false;
    for (@typeInfo(Command.Args).@"struct".fields) |field| {
        if (field.default_value_ptr == null) return true;
    }
    return false;
}

/// Run a command's execute() function in-process with captured I/O.
///
/// The command module must have Args, Options, and execute declarations.
/// Plugins can be provided to populate context.plugins.
pub fn runCommand(
    comptime Command: type,
    comptime plugins: []const type,
    config: struct {
        args: Command.Args = .{},
        options: Command.Options = .{},
        allocator: std.mem.Allocator = std.testing.allocator,
    },
) !CommandResult {
    const allocator = config.allocator;

    // Capture output using allocating writers
    var stdout_aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer stdout_aw.deinit();
    var stderr_aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer stderr_aw.deinit();

    // Create IO with overrides for capturing
    var io = zcli.IO.init(std.testing.io);
    io.stdout_override = &stdout_aw.writer;
    io.stderr_override = &stderr_aw.writer;

    // Arena-per-command allocator: mirror the runtime (Registry.execute) so a
    // command written to never free is leak-free under unit tests too, not just
    // in production. Command-body allocations are reclaimed when the arena is
    // dropped; the capture writers and vterm below stay on `allocator` so the
    // testing allocator still catches harness leaks.
    // See docs/adr/0001-arena-per-command-allocator.md.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Create context with plugins
    const Ctx = zcli.TestContext(plugins);
    var context = Ctx{
        .allocator = arena.allocator(),
        .io = &io,
    };
    defer context.deinit();

    // Execute the command
    var success = true;
    var err: ?anyerror = null;
    Command.execute(config.args, config.options, &context) catch |e| {
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
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: anytype) !void {
            const writer = context.stdout();
            try writer.writeAll("hello world\n");
        }
    };

    var result = try runCommand(TestCommand, &.{}, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings("hello world\n", result.stdout);
    try std.testing.expect(result.stderr.len == 0);
    try std.testing.expect(result.success);
}

test "runCommand captures stderr" {
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: anytype) !void {
            const writer = context.stderr();
            try writer.writeAll("error occurred\n");
        }
    };

    var result = try runCommand(TestCommand, &.{}, .{});
    defer result.deinit();

    try std.testing.expect(result.stdout.len == 0);
    try std.testing.expectEqualStrings("error occurred\n", result.stderr);
}

test "runCommand captures error" {
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, _: anytype) !void {
            return error.TestError;
        }
    };

    var result = try runCommand(TestCommand, &.{}, .{});
    defer result.deinit();

    try std.testing.expect(!result.success);
    try std.testing.expect(result.err != null);
    try std.testing.expectEqual(error.TestError, result.err.?);
}

test "runCommand passes args and options" {
    const TestCommand = struct {
        pub const Args = struct {
            name: []const u8 = "default",
        };
        pub const Options = struct {
            count: u32 = 1,
        };

        pub fn execute(args: Args, options: Options, context: anytype) !void {
            const writer = context.stdout();
            try writer.print("{s}: {d}\n", .{ args.name, options.count });
        }
    };

    var result = try runCommand(TestCommand, &.{}, .{
        .args = .{ .name = "widget" },
        .options = .{ .count = 5 },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("widget: 5\n", result.stdout);
}

test "runCommand with plugin data" {
    const MockPlugin = struct {
        pub const plugin_id = "mock";
        pub const ContextData = struct {
            enabled: bool = false,
        };
    };

    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: anytype) !void {
            if (context.plugins.mock.enabled) {
                try context.stdout().writeAll("enabled\n");
            } else {
                try context.stdout().writeAll("disabled\n");
            }
        }
    };

    var result = try runCommand(TestCommand, &.{MockPlugin}, .{});
    defer result.deinit();

    try std.testing.expectEqualStrings("disabled\n", result.stdout);
}

test "runCommand vterm contains text" {
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: anytype) !void {
            try context.stdout().writeAll("Hello World\n");
        }
    };

    var result = try runCommand(TestCommand, &.{}, .{});
    defer result.deinit();

    try std.testing.expect(result.term.containsText("Hello World"));
    try std.testing.expect(!result.term.containsText("Goodbye"));
}

test "runCommand arena reclaims allocations for a command that never frees" {
    // The arena-per-command contract: business logic can allocate via
    // context.allocator and never call free. runCommand uses
    // std.testing.allocator, which panics on leak, so this test fails if the
    // arena is removed. See docs/adr/0001-arena-per-command-allocator.md.
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: anytype) !void {
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

    var result = try runCommand(TestCommand, &.{}, .{});
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expect(result.term.containsText("allocated 17 bytes"));
}

test "runCommand vterm detects ANSI formatting" {
    const TestCommand = struct {
        pub const Args = struct {};
        pub const Options = struct {};

        pub fn execute(_: Args, _: Options, context: anytype) !void {
            try context.stdout().writeAll("\x1b[1mBold text\x1b[0m\n");
        }
    };

    var result = try runCommand(TestCommand, &.{}, .{});
    defer result.deinit();

    // VTerm parses ANSI — text is there without escape codes
    try std.testing.expect(result.term.containsText("Bold text"));
    // The cell at the start of "Bold text" should have bold attribute
    try std.testing.expect(result.term.hasAttribute(0, 0, .bold));
}
