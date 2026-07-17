const std = @import("std");

/// How a child process terminated.
///
/// A clean `exited 1` and a death by SIGSEGV both used to collapse to
/// `exit_code == 1`, so a test couldn't tell them apart. This distinguishes
/// them: `Result.exit_code` is *derived* from this via `exitCode()` (signal
/// deaths map to the conventional `128 + signum`), while the raw kind stays
/// available for assertions like "was this killed, and by which signal?".
pub const Termination = union(enum) {
    /// Normal exit with this status code.
    exited: u8,
    /// Killed by this POSIX signal number (e.g. 11 = SIGSEGV, 6 = SIGABRT).
    signaled: u8,
    /// Stopped, or an unknown termination — neither a clean exit nor a kill.
    unknown,

    /// Translate a std child termination into this portable kind.
    pub fn fromChild(term: std.process.Child.Term) Termination {
        return switch (term) {
            .exited => |code| .{ .exited = code },
            .signal => |sig| .{ .signaled = @intCast(@intFromEnum(sig)) },
            .stopped, .unknown => .unknown,
        };
    }

    /// The conventional exit code for this termination: the real status for a
    /// clean exit, `128 + signum` for a signal death (the shell convention, so
    /// `expectExitCode(r, 139)` matches a SIGSEGV), and `1` otherwise.
    pub fn exitCode(self: Termination) u8 {
        return switch (self) {
            .exited => |code| code,
            .signaled => |sig| 128 +| sig,
            .unknown => 1,
        };
    }
};

/// Result of running a CLI command
pub const Result = struct {
    stdout: []const u8,
    stderr: []const u8,
    /// Conventional exit code: the child's real status for a clean exit, or
    /// `128 + signum` for a signal death. Derived from `term.exitCode()`.
    exit_code: u8,
    /// How the child terminated (exited / signaled / unknown), so a test can
    /// distinguish a real `exited 1` from a kill and assert on the signal.
    term: Termination,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// Optional overrides for `runSubprocess`.
pub const RunOptions = struct {
    /// Environment for the child. `null` (the default) inherits the harness's
    /// environment; supply a map to test env-driven behavior (e.g. `NO_COLOR`)
    /// without escalating to the PTY e2e tier. Threaded through explicitly —
    /// no ambient/C-level environ.
    env: ?*const std.process.Environ.Map = null,
    /// Bytes to feed the child on stdin, then close (giving it EOF). `null`
    /// (the default) inherits the harness's stdin, preserving prior behavior.
    /// Suited to modest input that fits the OS pipe buffer (~64 KiB): the bytes
    /// are written in full before the output pipes are drained.
    stdin: ?[]const u8 = null,
};

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

/// Run a command as a subprocess (for external binaries).
///
/// `options` optionally overrides the child's environment and pipes bytes to
/// its stdin — so env-driven behavior (`NO_COLOR`) and stdin-reading commands
/// are testable here, without escalating to the PTY e2e tier.
pub fn runSubprocess(
    allocator: std.mem.Allocator,
    io: std.Io,
    exe_path: []const u8,
    args: []const []const u8,
    options: RunOptions,
) !Result {
    // Prepare arguments
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, args);

    // Spawn the subprocess with piped stdout/stderr. Stdin is a pipe only when
    // the caller supplies bytes to feed; otherwise it inherits (prior behavior).
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = options.env,
        .stdin = if (options.stdin != null) .pipe else .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Feed stdin (if any) to EOF before draining output. The child's stdout is
    // piped and drained below, so a child that echoes as it reads won't deadlock
    // us for modest input; oversized input that fills the OS pipe before the
    // child reads any is out of scope for this tier (documented on RunOptions).
    if (options.stdin) |input| {
        var stdin_file = child.stdin.?;
        stdin_file.writeStreamingAll(io, input) catch {};
        stdin_file.close(io);
        child.stdin = null;
    }

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
    //
    // If the drain errors (e.g. `error.StreamTooLong` past the `max_output`
    // cap), reap the child before propagating so it doesn't linger as a zombie.
    const stderr = (if (stderr_future) |*f|
        f.await(io)
    else
        drainPipe(io, child.stderr.?, shared)) catch |err| {
        _ = child.wait(io) catch {};
        return err;
    };
    errdefer allocator.free(stderr);

    const term = Termination.fromChild(try child.wait(io));

    return Result{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = term.exitCode(),
        .term = term,
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

    var result = runSubprocess(allocator, io, "/bin/sh", &.{ "-c", program }, .{}) catch |err| {
        // Spawning may be restricted in some sandboxes; don't fail the suite.
        std.log.warn("runSubprocess skipped: {any}", .{err});
        return;
    };
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("STDOUT_OK", result.stdout);
    try std.testing.expectEqual(@as(usize, 200000), result.stderr.len);
}

test "runSubprocess reaps the child when the stderr drain errors" {
    // Regression for #572: when the child floods stderr past the `max_output`
    // cap, the stderr drain fails with `error.StreamTooLong`. The error must
    // propagate *after* the child is reaped (`child.wait`), otherwise the child
    // lingers as a zombie. We can't observe the zombie directly, but we assert
    // the error surfaces without hanging — the reap happens on the same path.
    if (@import("builtin").os.tag == .windows) return; // uses /bin/sh

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Write just over the 10 MiB stderr cap (by 4 KiB — small enough that the
    // final bytes fit in the OS pipe buffer, so the child still exits instead of
    // blocking on a pipe we stop draining), then some stdout. The stdout drain
    // succeeds; the stderr drain trips the limit and returns an error.
    const over_cap = max_output + 4096;
    const program = std.fmt.comptimePrint(
        "yes zzzzzzzz | head -c {d} 1>&2; printf STDOUT_OK",
        .{over_cap},
    );

    if (runSubprocess(allocator, io, "/bin/sh", &.{ "-c", program }, .{})) |res| {
        var r = res;
        r.deinit();
        return error.ExpectedStreamTooLong;
    } else |err| switch (err) {
        error.StreamTooLong => {}, // expected: cap tripped and child reaped
        // Spawning may be restricted in some sandboxes; don't fail the suite.
        else => std.log.warn("runSubprocess skipped: {any}", .{err}),
    }
}

test "Result deinitialization" {
    const allocator = std.testing.allocator;

    var result = Result{
        .stdout = try allocator.dupe(u8, "test output"),
        .stderr = try allocator.dupe(u8, "test error"),
        .exit_code = 0,
        .term = .{ .exited = 0 },
        .allocator = allocator,
    };
    defer result.deinit();

    try std.testing.expectEqualStrings("test output", result.stdout);
    try std.testing.expectEqualStrings("test error", result.stderr);
}

test "Termination maps signal deaths to 128 + signum" {
    // #682: a signal death is no longer collapsed to exit_code 1 — it maps to
    // the shell-conventional 128 + signum, and the raw kind stays inspectable.
    try std.testing.expectEqual(@as(u8, 0), (Termination{ .exited = 0 }).exitCode());
    try std.testing.expectEqual(@as(u8, 1), (Termination{ .exited = 1 }).exitCode());
    try std.testing.expectEqual(@as(u8, 139), (Termination{ .signaled = 11 }).exitCode()); // SIGSEGV
    try std.testing.expectEqual(@as(u8, 130), (Termination{ .signaled = 2 }).exitCode()); // SIGINT
    try std.testing.expectEqual(@as(u8, 1), (@as(Termination, .unknown)).exitCode());
}

test "runSubprocess env overrides the child environment" {
    // #681: env-driven behavior is testable at the integration tier — no PTY.
    if (@import("builtin").os.tag == .windows) return; // uses /bin/sh

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("ZCLI_TEST_VAR", "from-env");

    var result = runSubprocess(allocator, io, "/bin/sh", &.{ "-c", "printf %s \"$ZCLI_TEST_VAR\"" }, .{ .env = &env }) catch |err| {
        std.log.warn("runSubprocess skipped: {any}", .{err});
        return;
    };
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("from-env", result.stdout);
}

test "runSubprocess feeds stdin to the child" {
    // #681: stdin-reading commands are testable at the integration tier — no PTY.
    if (@import("builtin").os.tag == .windows) return; // uses /bin/cat

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var result = runSubprocess(allocator, io, "/bin/cat", &.{}, .{ .stdin = "piped input\n" }) catch |err| {
        std.log.warn("runSubprocess skipped: {any}", .{err});
        return;
    };
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("piped input\n", result.stdout);
}

test "runSubprocess surfaces a signal death as termination kind and 128 + signum" {
    // #682: a child killed by a signal reports `.signaled` with the number, and
    // its exit_code is 128 + signum rather than a misleading 1.
    if (@import("builtin").os.tag == .windows) return; // uses /bin/sh

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // The shell kills itself with SIGSEGV (11); the process is reaped as signaled.
    var result = runSubprocess(allocator, io, "/bin/sh", &.{ "-c", "kill -SEGV $$" }, .{}) catch |err| {
        std.log.warn("runSubprocess skipped: {any}", .{err});
        return;
    };
    defer result.deinit();

    try std.testing.expectEqual(Termination{ .signaled = 11 }, result.term);
    try std.testing.expectEqual(@as(u8, 139), result.exit_code);
}
