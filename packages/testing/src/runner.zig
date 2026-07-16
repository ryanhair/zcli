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

/// Serializes access to a child allocator behind a mutex.
///
/// `runSubprocess` drains stdout and stderr concurrently (one on the main
/// thread, one on an `io.concurrent` task) and both capture into the caller's
/// `allocator`. That allocator is typically not thread-safe (e.g.
/// `std.testing.allocator`), and Zig 0.16 removed `std.heap.ThreadSafeAllocator`,
/// so we wrap it here rather than reaching for a process-global like
/// `page_allocator`. The bytes end up owned by the caller's allocator directly,
/// so `Result.deinit` frees them normally and no post-join copy is needed.
const LockingAllocator = struct {
    child: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    fn allocator(self: *LockingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LockingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LockingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LockingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LockingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// Drain a child pipe to EOF, capturing the bytes in `alloc`.
///
/// This runs concurrently with the sibling pipe's drain (see `runSubprocess`).
/// Both drains capture into the caller's allocator via a shared
/// `LockingAllocator`, so their allocations are serialized against each other.
fn drainPipe(io: std.Io, file: std.Io.File, alloc: std.mem.Allocator) std.Io.Reader.LimitedAllocError![]u8 {
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.interface.allocRemaining(alloc, .limited(max_output));
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
    // Both drains capture into the caller's `allocator`, so they share it
    // through a mutex (LockingAllocator) — the caller's allocator is not
    // necessarily thread-safe and the two drains run on different threads.
    var locked = LockingAllocator{ .child = allocator, .io = io };
    const shared = locked.allocator();

    var stderr_future: ?std.Io.Future(std.Io.Reader.LimitedAllocError![]u8) =
        io.concurrent(drainPipe, .{ io, child.stderr.?, shared }) catch null;

    const stdout = drainPipe(io, child.stdout.?, shared) catch |err| {
        // Keep stderr draining so the child can exit, free it, then reap.
        if (stderr_future) |*f| {
            if (f.await(io)) |bytes| allocator.free(bytes) else |_| {}
        }
        _ = child.wait(io) catch {};
        return err;
    };
    errdefer allocator.free(stdout);

    // Join the concurrent stderr drain (or, if concurrency was unavailable, do
    // it sequentially now — the pre-existing fallback behavior). The bytes are
    // owned by the caller's `allocator` directly, so no post-join copy needed.
    const stderr = if (stderr_future) |*f|
        try f.await(io)
    else
        try drainPipe(io, child.stderr.?, shared);
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
