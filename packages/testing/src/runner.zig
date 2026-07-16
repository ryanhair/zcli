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

const max_output = 10 * 1024 * 1024;

/// Drain a child pipe to EOF, returning the bytes allocated in `arena`.
///
/// This runs concurrently with the sibling pipe's drain (see `runSubprocess`),
/// so it allocates only from its own arena — never the caller's `allocator`,
/// which the sibling drain is using at the same time on the main thread. Once
/// both drains have joined, the result is copied into the caller's allocator on
/// a single thread.
fn drainPipe(io: std.Io, file: std.Io.File, arena: std.mem.Allocator) std.Io.Reader.LimitedAllocError![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.interface.allocRemaining(arena, .limited(max_output));
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

    // Both pipes must drain simultaneously. Draining one to EOF before touching
    // the other deadlocks: a child that fills the un-drained pipe (>~64 KB, the
    // OS pipe buffer) blocks in write() and never exits, so the pipe we *are*
    // draining never reaches EOF. Read stderr concurrently while the main thread
    // drains stdout.
    //
    // The concurrent drain allocates from an isolated arena (page-backed, so it
    // shares no allocator state with the main thread's stdout drain); we copy
    // its bytes into `allocator` below, after joining, on a single thread.
    var stderr_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer stderr_arena.deinit();

    var stderr_future: ?std.Io.Future(std.Io.Reader.LimitedAllocError![]u8) =
        io.concurrent(drainPipe, .{ io, child.stderr.?, stderr_arena.allocator() }) catch null;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout = stdout_reader.interface.allocRemaining(allocator, .limited(max_output)) catch |err| {
        // Keep stderr draining so the child can exit, then reap before failing.
        if (stderr_future) |*f| _ = f.await(io) catch "";
        _ = child.wait(io) catch {};
        return err;
    };
    errdefer allocator.free(stdout);

    // Join the concurrent stderr drain (or, if concurrency was unavailable, do
    // it sequentially now — the pre-existing fallback behavior).
    const stderr_bytes = if (stderr_future) |*f|
        try f.await(io)
    else
        try drainPipe(io, child.stderr.?, stderr_arena.allocator());

    const stderr = try allocator.dupe(u8, stderr_bytes);
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

test "runSubprocess drains both pipes when the child floods stderr" {
    // Regression for #430: the child writes far more than one OS pipe buffer
    // (~64 KB) to stderr *before* writing stdout. If stderr isn't drained
    // concurrently, the child blocks in write() on the full stderr pipe, never
    // exits, stdout never reaches EOF, and this call hangs forever.
    if (@import("builtin").os.tag == .windows) return; // uses /bin/sh

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // yes(1) is truncated by head(1) to exactly 200 KB on stderr, then a known
    // marker is written to stdout. The order (stderr first) is what triggers
    // the deadlock on the old sequential drain.
    const program = "yes zzzzzzzz | head -c 200000 1>&2; printf STDOUT_OK";

    var result = runSubprocess(allocator, io, "/bin/sh", &.{ "-c", program }) catch |err| {
        // Spawning may be restricted in some sandboxes; don't fail the suite.
        std.log.warn("runSubprocess skipped: {any}", .{err});
        return;
    };
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("STDOUT_OK", result.stdout);
    try std.testing.expectEqual(@as(usize, 200000), result.stderr.len);
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
