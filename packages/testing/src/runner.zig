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
pub fn runInProcess(allocator: std.mem.Allocator, comptime RegistryType: type, args: []const []const u8) !Result {
    _ = RegistryType; // Not used in subprocess approach

    // Determine the binary path based on the registry type
    // For now, we'll use a hardcoded path, but this could be made configurable
    const exe_path = "./zig-out/bin/example-cli";

    // Check if the binary exists
    std.fs.cwd().access(exe_path, .{}) catch |err| {
        // If binary doesn't exist, return a helpful error
        std.debug.print("Error: CLI binary not found at '{s}'\n", .{exe_path});
        std.debug.print("Please run 'zig build' first to compile the CLI\n", .{});
        return err;
    };

    // Run the actual binary
    return runSubprocess(allocator, exe_path, args);
}

/// Run a command as a subprocess (for external binaries)
pub fn runSubprocess(allocator: std.mem.Allocator, exe_path: []const u8, args: []const []const u8) !Result {
    // Prepare arguments
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(exe_path);
    try argv.appendSlice(args);

    // Run the subprocess
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 10 * 1024 * 1024, // 10MB max
    });

    // Map term to exit code
    const exit_code: u8 = switch (result.term) {
        .Exited => |code| @intCast(code),
        else => 1, // Non-zero for any other termination
    };

    return Result{
        .stdout = result.stdout,
        .stderr = result.stderr,
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
