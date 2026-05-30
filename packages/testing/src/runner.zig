const std = @import("std");

/// Result of running a CLI command
pub const Result = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// Run a command using the actual compiled binary
///
/// This function runs the actual CLI binary as a subprocess, ensuring we test
/// the real implementation rather than mocks or stubs. This is the most reliable
/// way to test CLI applications as it tests the full stack including argument
/// parsing, command routing, and output generation.
///
/// The RegistryType parameter is kept for API compatibility but isn't used
/// since we're running the actual binary rather than calling registry methods.
pub fn runInProcess(allocator: std.mem.Allocator, io: std.Io, comptime RegistryType: type, args: []const []const u8) !Result {
    _ = RegistryType; // Not used in subprocess approach

    // Determine the binary path based on the registry type
    // For now, we'll use a hardcoded path, but this could be made configurable
    const exe_path = "./zig-out/bin/example-cli";

    // Check if the binary exists
    std.Io.Dir.cwd().access(io, exe_path, .{}) catch |err| {
        // If binary doesn't exist, return a helpful error
        std.debug.print("Error: CLI binary not found at '{s}'\n", .{exe_path});
        std.debug.print("Please run 'zig build' first to compile the CLI\n", .{});
        return err;
    };

    // Run the actual binary
    return runSubprocess(allocator, io, exe_path, args);
}

/// Run a command as a subprocess (for external binaries)
pub fn runSubprocess(allocator: std.mem.Allocator, io: std.Io, exe_path: []const u8, args: []const []const u8) !Result {
    // Prepare arguments
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, args);

    // Spawn the subprocess with piped stdout/stderr
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Read all output before waiting (avoid deadlock on big outputs)
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stdout = try stdout_reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024));
    errdefer allocator.free(stdout);
    const stderr = try stderr_reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024));
    errdefer allocator.free(stderr);

    const term = try child.wait(io);
    const exit_code: u8 = switch (term) {
        .exited => |code| @intCast(code),
        else => 1,
    };

    return Result{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
        .allocator = allocator,
    };
}

test "Result deinitialization" {
    const allocator = std.testing.allocator;

    var result = Result{
        .stdout = try allocator.dupe(u8, "test output"),
        .stderr = try allocator.dupe(u8, "test error"),
        .exit_code = 0,
        .allocator = allocator,
    };
    defer result.deinit();

    try std.testing.expectEqualStrings("test output", result.stdout);
    try std.testing.expectEqualStrings("test error", result.stderr);
}
