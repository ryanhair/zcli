//! In-process command testing utilities for zcli.
//!
//! Runs a command's execute() function directly without spawning a subprocess,
//! capturing stdout and stderr output for assertions. Includes a virtual
//! terminal (VTerm) for testing colors, formatting, and cursor positioning.
//!
//! ```zig
//! const test_utils = zcli.test_utils;
//!
//! test "add command" {
//!     var result = try test_utils.runCommand(AddCommand, &.{}, .{
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
const zcli = @import("zcli.zig");
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

    // Internal state for cleanup
    _stdout_file: std.fs.File,
    _stderr_file: std.fs.File,
    _tmp_dir: std.testing.TmpDir,

    pub fn deinit(self: *CommandResult) void {
        self.term.deinit();
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self._stdout_file.close();
        self._stderr_file.close();
        self._tmp_dir.cleanup();
    }
};

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

    // Create temp files for capturing output
    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    var stdout_file = try tmp_dir.dir.createFile("stdout", .{ .read = true });
    errdefer stdout_file.close();
    var stderr_file = try tmp_dir.dir.createFile("stderr", .{ .read = true });
    errdefer stderr_file.close();

    // Create IO with temp file writers
    var io = zcli.IO{
        .stdout_writer = stdout_file.writer(&.{}),
        .stderr_writer = stderr_file.writer(&.{}),
        .stdin_reader = std.fs.File.stdin().reader(&.{}),
    };

    // Create context with plugins
    const Ctx = zcli.TestContext(plugins);
    var context = Ctx{
        .allocator = allocator,
        .io = &io,
        .environment = zcli.Environment.init(allocator),
    };
    defer context.deinit();

    // Execute the command
    var success = true;
    var err: ?anyerror = null;
    Command.execute(config.args, config.options, &context) catch |e| {
        success = false;
        err = e;
    };

    // Flush writers
    io.stdout().flush() catch {};
    io.stderr().flush() catch {};

    // Read captured output
    try stdout_file.seekTo(0);
    const stdout_content = try stdout_file.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(stdout_content);

    try stderr_file.seekTo(0);
    const stderr_content = try stderr_file.readToEndAlloc(allocator, 1024 * 1024);
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
        ._stdout_file = stdout_file,
        ._stderr_file = stderr_file,
        ._tmp_dir = tmp_dir,
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
