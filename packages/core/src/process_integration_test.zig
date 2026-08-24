//! Integration tests for `process.zig`: everything that needs a real child.
//!
//! The child is `process_fixture.zig`, compiled once by `build.zig` and located
//! through the `fixture` build-options module. Cross-platform is a hard
//! requirement here — which is why the fixture exists at all instead of
//! `/bin/sh` — so tests that can only hold on one platform say so explicitly and
//! skip elsewhere rather than being quietly absent.

const std = @import("std");
const builtin = @import("builtin");
const process = @import("process.zig");

const Io = std.Io;
const testing = std.testing;
const is_windows = builtin.os.tag == .windows;

/// Absolute path to the compiled fixture, emitted by `build.zig`.
const fixture_exe = @import("fixture").exe_path;

fn fixture() process.Program {
    return .{ .path = fixture_exe };
}

/// An empty environment map. Tests that need entries put them in explicitly, so
/// nothing here depends on the developer's shell.
fn emptyEnv(a: std.mem.Allocator) std.process.Environ.Map {
    return .init(a);
}

fn filler(allocator: std.mem.Allocator, n: usize) ![]u8 {
    const buf = try allocator.alloc(u8, n);
    for (buf, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    return buf;
}

fn elapsedMs(io: Io, start: Io.Clock.Timestamp) i64 {
    return start.durationTo(Io.Clock.Timestamp.now(io, .boot)).raw.toMilliseconds();
}

/// Fails the process from *outside* the call under test if that call does not
/// return in time.
///
/// This is not a stylistic preference. Every "and then it terminated" assertion
/// in this file is written after the call it is about — and if the call hangs,
/// that assertion never executes. An elapsed-time check therefore cannot catch
/// the one failure it exists to catch; the test just stops, and the suite
/// reports a timeout somewhere with no idea which shape wedged. The watchdog
/// runs on its own task and names the shape when it fires.
const Watchdog = struct {
    io: Io,
    label: []const u8,
    limit_ms: i64,
    done: std.atomic.Value(bool) = .init(false),
    future: ?Io.Future(void) = null,

    fn arm(self: *Watchdog) !void {
        self.future = try self.io.concurrent(watch, .{self});
    }

    fn watch(self: *Watchdog) void {
        // Sliced rather than one long sleep so disarming returns promptly
        // instead of holding a pool thread for the whole budget.
        const slice_ms: i64 = 50;
        var waited: i64 = 0;
        while (waited < self.limit_ms) : (waited += slice_ms) {
            if (self.done.load(.acquire)) return;
            self.io.sleep(.fromMilliseconds(slice_ms), .boot) catch return;
        }
        if (self.done.load(.acquire)) return;
        std.debug.panic(
            "watchdog: '{s}' did not return within {d}ms — the run hung",
            .{ self.label, self.limit_ms },
        );
    }

    fn disarm(self: *Watchdog) void {
        self.done.store(true, .release);
        if (self.future) |*f| {
            _ = f.await(self.io);
            self.future = null;
        }
    }
};

// ---------------------------------------------------------------------------
// 1. The deadlock test
// ---------------------------------------------------------------------------

test "4 MiB in, echoed out, with 4 MiB of stderr alongside" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    const size = 4 * 1024 * 1024;
    const payload = try filler(a, size);
    defer a.free(payload);

    // Write stdin to completion before reading stdout and this wedges: the child
    // fills its stdout pipe and blocks, while the parent blocks feeding stdin.
    var result = try runner.run(fixture(), .{
        .args = &.{ "echo-both", "4194304" },
        .stdin = .{ .bytes = payload },
        .stdout = .{ .capture = .{ .limit = 16 << 20, .overflow = .fail } },
        .stderr = .{ .capture = .{ .limit = 16 << 20, .overflow = .fail } },
    });
    defer result.deinit();

    try testing.expect(result.ok());
    try testing.expectEqual(@as(usize, size), result.stdout.len);
    try testing.expectEqualSlices(u8, payload, result.stdout.bytes());
    try testing.expectEqual(@as(usize, size), result.stderr.len);
    try testing.expect(!result.orphaned);
}

// ---------------------------------------------------------------------------
// 2. Pipe-quota boundaries
// ---------------------------------------------------------------------------

test "stdin payloads straddling both platforms' pipe quotas round-trip exactly" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // 4096 is the Windows backend's `CreatePipeOptions.quota` exactly; 65536 is
    // the common POSIX pipe buffer. Both ±1, because "equal to the buffer" and
    // "one past it" are different code paths in every implementation that got
    // this wrong.
    for ([_]usize{ 0, 1, 4095, 4096, 4097, 65535, 65536, 65537 }) |n| {
        const payload = try filler(a, n);
        defer a.free(payload);

        var result = try runner.run(fixture(), .{
            .args = &.{"echo"},
            .stdin = .{ .bytes = payload },
        });
        defer result.deinit();

        try testing.expect(result.ok());
        try testing.expectEqualSlices(u8, payload, result.stdout.bytes());
    }
}

// ---------------------------------------------------------------------------
// 3-6. Caps and overflow
// ---------------------------------------------------------------------------

test "truncate keeps the first limit bytes and still observes the exit status" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var result = try runner.run(fixture(), .{
        .args = &.{ "flood", "100000" },
        .stdout = .{ .capture = .{ .limit = 1000, .overflow = .truncate } },
    });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1000), result.stdout.len);
    try testing.expect(result.stdout.truncated);
    try testing.expectEqual(@as(u64, 99_000), result.stdout.dropped);
    // Draining continued past the cap, so the child never blocked and its exit
    // status is real rather than a guess.
    try testing.expect(result.ok());
}

test "exactly limit bytes is not an overflow, under either policy" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // Overflow is observing byte `limit + 1`, not reaching `limit`.
    for ([_]process.Overflow{ .truncate, .fail }) |policy| {
        var result = try runner.run(fixture(), .{
            .args = &.{ "flood", "4096" },
            .stdout = .{ .capture = .{ .limit = 4096, .overflow = policy } },
        });
        defer result.deinit();

        try testing.expect(result.ok());
        try testing.expectEqual(@as(usize, 4096), result.stdout.len);
        try testing.expect(!result.stdout.truncated);
        try testing.expectEqual(@as(u64, 0), result.stdout.dropped);
    }
}

test "fail overflow returns OutputTooLarge in the capture phase, with the child reaped" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var diag: process.Diagnostic = .{};
    try testing.expectError(error.OutputTooLarge, runner.run(fixture(), .{
        .args = &.{ "flood", "100000" },
        .stdout = .{ .capture = .{ .limit = 1000, .overflow = .fail } },
        .diagnostic = &diag,
    }));
    try testing.expectEqual(process.Phase.capture, diag.phase);
    try expectNoZombies();
}

test "caps are per stream: one trips, the other does not" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var result = try runner.run(fixture(), .{
        .args = &.{ "flood-both", "50000", "100" },
        .stdout = .{ .capture = .{ .limit = 1000, .overflow = .truncate } },
        .stderr = .{ .capture = .{ .limit = 1000, .overflow = .truncate } },
    });
    defer result.deinit();

    try testing.expect(result.stdout.truncated);
    try testing.expect(!result.stderr.truncated);
    try testing.expectEqual(@as(usize, 100), result.stderr.len);
}

// ---------------------------------------------------------------------------
// 7-8. Termination fidelity
// ---------------------------------------------------------------------------

test "a nonzero exit is a Result, not an error" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var result = try runner.run(fixture(), .{ .args = &.{ "exit", "3" } });
    defer result.deinit();

    try testing.expect(!result.ok());
    try testing.expectEqual(@as(u8, 3), result.exitCode());
    try testing.expectEqual(process.Termination{ .exited = 3 }, result.term);
    try testing.expectError(error.CommandFailed, result.expectOk());
}

test "signal death keeps its kind" {
    // Windows has no signals, so `.signaled` is unreachable there and a crash
    // cannot be told from an exit by kind. That is a platform fact, not a gap in
    // this module — see the module docs.
    if (is_windows) return error.SkipZigTest;

    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var result = try runner.run(fixture(), .{
        .args = &.{"signal-self"},
        .stderr = .ignore,
    });
    defer result.deinit();

    try testing.expect(result.term == .signaled);
    try testing.expectEqual(@as(u32, 11), @intFromEnum(result.term.signaled));
    try testing.expectEqual(@as(u8, 139), result.exitCode());
}

// ---------------------------------------------------------------------------
// 11. stdin
// ---------------------------------------------------------------------------

test "stdin .ignore gives the child an immediate EOF" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var result = try runner.run(fixture(), .{ .args = &.{"echo"}, .stdin = .ignore });
    defer result.deinit();

    try testing.expect(result.ok());
    try testing.expectEqual(@as(usize, 0), result.stdout.len);
    try testing.expect(result.stdout.captured);
}

test "stdin closes the moment the payload is written, so a cat-shaped child exits on its own" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // Large enough to keep the writer busy for a while: the bug this guards
    // against deferred the close to teardown, which a few bytes would hide
    // because the write finishes before anything else happens.
    const payload = try filler(a, 2 * 1024 * 1024);
    defer a.free(payload);

    // No timeout and no kill: the child must reach EOF and exit by itself, or
    // this test hangs — which is the assertion.
    var result = try runner.run(fixture(), .{
        .args = &.{"echo"},
        .stdin = .{ .bytes = payload },
        .stdout = .{ .capture = .{ .limit = 8 << 20, .overflow = .fail } },
    });
    defer result.deinit();

    try testing.expect(result.ok());
    try testing.expectEqual(payload.len, result.stdout.len);
}

test "a child that closes stdin early keeps its exit status and its captures" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // Bigger than any platform's pipe buffer, so the write cannot possibly
    // complete before the child — which never reads stdin — exits. The parent's
    // write therefore breaks against a closed read end on both platforms
    // (`EPIPE` / `STATUS_PIPE_BROKEN`), which is the case under test.
    const payload = try filler(a, 4 * 1024 * 1024);
    defer a.free(payload);

    // A broken stdin write is NOT the run's failure: the child said what it
    // thought on stderr and chose an exit code, and a caller who classifies by
    // those two (`zcli_secrets`' backends do) must still be able to. Raising the
    // write error would replace the child's account of the run with the runner's.
    var result = try runner.run(fixture(), .{
        .args = &.{ "reject", "3" },
        .stdin = .{ .bytes = payload },
    });
    defer result.deinit();

    try testing.expect(!result.ok());
    try testing.expectEqual(@as(u8, 3), result.exitCode());
    try testing.expectEqualStrings("rejected", result.stderr.bytes());
    // Recorded rather than raised — the caller can still see what happened.
    try testing.expect(result.stdin_closed_early);
}

// ---------------------------------------------------------------------------
// 12-13, 15, 18. Timeouts
// ---------------------------------------------------------------------------

fn timeout(ms: i64) Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .boot } };
}

test "a sleeping child with captured output times out" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    const start: Io.Clock.Timestamp = .now(io, .boot);
    var diag: process.Diagnostic = .{};
    try testing.expectError(error.Timeout, runner.run(fixture(), .{
        .args = &.{ "sleep", "60000" },
        .timeout = timeout(300),
        .diagnostic = &diag,
    }));
    const took = elapsedMs(io, start);

    try testing.expectEqual(process.Phase.stop, diag.phase);
    try testing.expect(took >= 250);
    try testing.expect(took < 10_000);
    try expectNoZombies();
}

test "a run with no captured streams still times out" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // Nothing to poll: the batch is empty from the outset, so the deadline can
    // only be honoured by the loop's own clock check. An earlier design assigned
    // this case to a primitive that could not carry it, and it hung forever.
    const start: Io.Clock.Timestamp = .now(io, .boot);
    try testing.expectError(error.Timeout, runner.run(fixture(), .{
        .args = &.{ "sleep", "60000" },
        .stdout = .ignore,
        .stderr = .ignore,
        .timeout = timeout(300),
    }));
    try testing.expect(elapsedMs(io, start) < 10_000);
    try expectNoZombies();
}

test "the timeout is strict even while the child floods stdout" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // Past its deadline the backend keeps returning ready completions rather
    // than reporting a timeout, so a runner that infers the deadline from that
    // return value never stops this child.
    const start: Io.Clock.Timestamp = .now(io, .boot);
    try testing.expectError(error.Timeout, runner.run(fixture(), .{
        .args = &.{"flood-forever"},
        // A modest cap under `.truncate`: past it the runner keeps reading and
        // discarding, so completions keep arriving for the whole run without the
        // test retaining a gigabyte to prove it.
        .stdout = .{ .capture = .{ .limit = 1 << 20, .overflow = .truncate } },
        .timeout = timeout(500),
    }));
    try testing.expect(elapsedMs(io, start) < 10_000);
    try expectNoZombies();
}

test "captured streams closing early does not end the run while the child lives" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // The loop exits on the reap, never on the pipes. A runner that returned
    // when the pipes hit EOF would report a bogus success here, with the child
    // still running and no `Term` to report.
    const start: Io.Clock.Timestamp = .now(io, .boot);
    try testing.expectError(error.Timeout, runner.run(fixture(), .{
        .args = &.{ "quiet-then-sleep", "60000" },
        .timeout = timeout(300),
    }));
    try testing.expect(elapsedMs(io, start) >= 250);

    // Same shape, but the child does eventually exit: the run must wait for it
    // and report the status it chose.
    var result = try runner.run(fixture(), .{ .args = &.{ "quiet-then-sleep", "150" } });
    defer result.deinit();
    try testing.expect(result.ok());

    // And again with a stdin payload in flight, so the stdin close is exercised
    // against a child that is not reading its own outputs.
    const payload = try filler(a, 1024);
    defer a.free(payload);
    var with_stdin = try runner.run(fixture(), .{
        .args = &.{ "quiet-then-sleep", "150" },
        .stdin = .{ .bytes = payload },
    });
    defer with_stdin.deinit();
    try testing.expect(with_stdin.ok());
}

// ---------------------------------------------------------------------------
// 14. Orphan linger
// ---------------------------------------------------------------------------

test "an orphaned output handle bounds the run instead of hanging it" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // The grandchild holds stdout and writes *nothing*. A chatty one would keep
    // waking the drain by accident and pass even with no linger implemented at
    // all, which is why silence is the point.
    const start: Io.Clock.Timestamp = .now(io, .boot);
    var result = try runner.run(fixture(), .{
        .args = &.{ "spawn-orphan", fixture_exe, "5000" },
        .orphan_linger = .fromMilliseconds(300),
    });
    defer result.deinit();
    const took = elapsedMs(io, start);

    try testing.expect(result.orphaned);
    try testing.expect(result.ok());
    // The honest bound: the child's exit, plus up to one poll tick of detection
    // latency, plus the linger. No deterministic cutoff against the child's true
    // exit time — the detection latency is polling latency.
    try testing.expect(took < 10_000);
}

// ---------------------------------------------------------------------------
// 16. No busy-spin on the stdin endgame
// ---------------------------------------------------------------------------

test "feeding a slow reader does not peg a core" {
    if (is_windows) return error.SkipZigTest;

    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // The child closes both outputs and reads stdin slowly, so the stdin write
    // is the only operation in the batch. With a nonblocking descriptor and no
    // deadline the backend would bypass `poll` entirely, `writev` would return
    // `WouldBlock`, and the loop would re-arm at full speed.
    const payload = try filler(a, 256 * 1024);
    defer a.free(payload);

    const before = cpuMs();
    const start: Io.Clock.Timestamp = .now(io, .boot);
    var result = try runner.run(fixture(), .{
        .args = &.{ "slow-read", "5" },
        .stdin = .{ .bytes = payload },
    });
    defer result.deinit();
    const wall = elapsedMs(io, start);
    const cpu = cpuMs() - before;

    try testing.expect(result.ok());
    try testing.expect(wall > 100); // the child really was slow
    // A pegged core spends ~100% of wall time; anything under a third is not
    // spinning. Coarse on purpose — this catches a busy loop, not a regression
    // of a few percent.
    try testing.expect(cpu * 3 < wall + 50);
}

/// Total CPU milliseconds this process has consumed, user + system.
fn cpuMs() i64 {
    if (is_windows) return 0;
    // RUSAGE_SELF is 0 on every POSIX platform; `std.posix` exposes no constant.
    const ru = std.posix.getrusage(0);
    const user = @as(i64, ru.utime.sec) * 1000 + @divTrunc(@as(i64, ru.utime.usec), 1000);
    const sys = @as(i64, ru.stime.sec) * 1000 + @divTrunc(@as(i64, ru.stime.usec), 1000);
    return user + sys;
}

// ---------------------------------------------------------------------------
// 17, 19, 25. Single-reaper invariants, cleanup, and the abort race
// ---------------------------------------------------------------------------

/// A follow-up wildcard reap must find nothing: any zombie the runner left
/// behind shows up here.
fn expectNoZombies() !void {
    if (is_windows) return;
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const rc = std.posix.system.waitpid(-1, &status, std.posix.W.NOHANG);
    switch (std.posix.errno(rc)) {
        // No children at all — the expected answer.
        .CHILD => {},
        // Children exist but none is reapable. Also fine: the test harness's own
        // machinery, not a corpse of ours.
        .SUCCESS => try testing.expect(toSignedRc(rc) == 0),
        else => {},
    }
}

fn toSignedRc(rc: anytype) isize {
    return switch (@typeInfo(@TypeOf(rc)).int.signedness) {
        .signed => @intCast(rc),
        .unsigned => @bitCast(rc),
    };
}

/// Number of open file descriptors, where the platform makes that cheap to ask.
fn openHandleCount(io: Io) ?usize {
    const path = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => "/dev/fd",
        .linux => "/proc/self/fd",
        else => return null,
    };
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch return null) |_| count += 1;
    return count;
}

test "aborted runs leak no handle, no zombie, and no double close" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    const before = openHandleCount(io);

    // Both abort shapes, repeatedly. The count is bounded so the suite stays
    // fast; the invariants are per-iteration, so a leak shows up as drift rather
    // than needing a large sample.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try testing.expectError(error.Timeout, runner.run(fixture(), .{
            .args = &.{ "sleep", "60000" },
            .timeout = timeout(30),
        }));
        try testing.expectError(error.OutputTooLarge, runner.run(fixture(), .{
            .args = &.{ "flood", "200000" },
            .stdout = .{ .capture = .{ .limit = 100, .overflow = .fail } },
        }));
    }
    try expectNoZombies();

    if (before) |b| {
        const after = openHandleCount(io).?;
        // A handful of slack for whatever the Io implementation opened along the
        // way; a per-run leak over 40 runs would be far larger.
        try testing.expect(after <= b + 8);
    }
}

test "a child that exits just as the timeout fires is handled cleanly, whichever wins" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // A race, so no run count can guarantee both orderings — the deterministic
    // assertion is the branch-logic unit test in process.zig. This asserts only
    // that whichever orderings occur are clean, and reports what it saw.
    var timed_out: usize = 0;
    var exited: usize = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (runner.run(fixture(), .{
            .args = &.{ "sleep", "50" },
            .timeout = timeout(50),
        })) |res| {
            var r = res;
            defer r.deinit();
            try testing.expect(r.term == .exited);
            exited += 1;
        } else |err| {
            try testing.expectEqual(error.Timeout, err);
            timed_out += 1;
        }
        try expectNoZombies();
    }
    try testing.expectEqual(@as(usize, 20), timed_out + exited);
}

// ---------------------------------------------------------------------------
// 21, 24. Stopping, escalation, and the external reaper
// ---------------------------------------------------------------------------

test "a child ignoring SIGTERM is gone after the grace" {
    if (is_windows) return error.SkipZigTest;

    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    const start: Io.Clock.Timestamp = .now(io, .boot);
    try testing.expectError(error.Timeout, runner.run(fixture(), .{
        .args = &.{ "ignore-sigterm", "60000" },
        .timeout = timeout(100),
        .stop_grace = .fromMilliseconds(200),
    }));
    const took = elapsedMs(io, start);

    // TERM is ignored, so only the escalation to KILL can end this.
    try testing.expect(took >= 300);
    try testing.expect(took < 10_000);
    try expectNoZombies();
}

test "a child reaped by something else reports the wait phase instead of hanging" {
    // POSIX only: this needs a disposition that makes the kernel auto-reap, and
    // Windows has no equivalent (its process handle is a stable identity, so the
    // hazard does not exist there).
    if (is_windows) return error.SkipZigTest;

    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // Violate the documented exclusive-reaping precondition on purpose, and
    // assert the weakened guarantee the module promises for that case: report
    // it, send no further signal, and return rather than hang.
    var ignore_child: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(.CHLD, &ignore_child, &previous);
    defer std.posix.sigaction(.CHLD, &previous, null);

    var diag: process.Diagnostic = .{};
    const start: Io.Clock.Timestamp = .now(io, .boot);
    const outcome = runner.run(fixture(), .{
        .args = &.{ "exit", "0" },
        .diagnostic = &diag,
    });
    try testing.expect(elapsedMs(io, start) < 10_000);

    if (outcome) |res| {
        // Some kernels still let our `waitpid` win the race; that outcome is
        // correct too, and the point of the test is that neither hangs.
        var r = res;
        r.deinit();
    } else |err| {
        try testing.expectEqual(error.ChildReapedElsewhere, err);
        try testing.expectEqual(process.Phase.wait, diag.phase);
        try testing.expect(diag.term == null);
    }
}

// ---------------------------------------------------------------------------
// 20, 22, 23. Windows-specific paths
// ---------------------------------------------------------------------------

test "an abort while the writer is blocked still terminates" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // The child never reads stdin, so the parent's writer fills the pipe and
    // stops. On Windows that writer is parked inside a synchronous `NtWriteFile`
    // and only `future.cancel` releases it — awaiting it because the direct child
    // exited is exactly the hang this forbids, since a descendant may hold the
    // read end. On POSIX the write is nonblocking and lives in the batch, so
    // there is no task to unblock; the assertion is the same either way.
    const payload = try filler(a, 4 * 1024 * 1024);
    defer a.free(payload);

    var dog: Watchdog = .{ .io = io, .label = "abort with a blocked writer", .limit_ms = 20_000 };
    try dog.arm();
    defer dog.disarm();

    const start: Io.Clock.Timestamp = .now(io, .boot);
    var diag: process.Diagnostic = .{};
    try testing.expectError(error.Timeout, runner.run(fixture(), .{
        .args = &.{ "no-read", "60000" },
        .stdin = .{ .bytes = payload },
        .timeout = timeout(300),
        .diagnostic = &diag,
    }));
    try testing.expect(elapsedMs(io, start) < 15_000);

    // Teardown-induced errors must not displace the primary failure: the caller
    // needs `Timeout`, not `.stdin`/`Canceled`.
    try testing.expectEqual(process.Phase.stop, diag.phase);
    try expectNoZombies();
}

test "an abort terminates even when a descendant holds stdin and the child is gone" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // The variant that matters. The direct child hands stdin's read end to a
    // grandchild and exits immediately, so stopping the child does *not* break
    // the pipe — the parent's writer is still blocked against a process the
    // runner never spawned and cannot see. On Windows that is precisely the case
    // where awaiting the writer (because the direct child exited) hangs forever,
    // and only `future.cancel` reaching the blocked `NtWriteFile` releases it.
    const payload = try filler(a, 4 * 1024 * 1024);
    defer a.free(payload);

    var dog: Watchdog = .{ .io = io, .label = "descendant holds stdin", .limit_ms = 30_000 };
    try dog.arm();
    defer dog.disarm();

    // The run ends one way or the other — the child is gone, so the only
    // question is whether teardown releases the writer. What it must not do is
    // hang, which is what the watchdog is here to catch.
    if (runner.run(fixture(), .{
        .args = &.{ "spawn-stdin-holder", fixture_exe, "5000" },
        .stdin = .{ .bytes = payload },
        .timeout = timeout(1000),
    })) |res| {
        var r = res;
        r.deinit();
    } else |err| {
        try testing.expect(err == error.Timeout or err == error.BrokenPipe);
    }
    try expectNoZombies();
}

test "orphan-linger expiry releases an unfinished writer instead of awaiting it" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // Both halves at once: a silent grandchild holds stdout open (so the streams
    // never reach EOF and the orphan linger is what ends the run) while the
    // parent still has megabytes of stdin outstanding to a child that never read
    // any of it. On expiry the writer has not published `done`, so teardown must
    // *cancel* it. Awaiting it there — on the strength of the direct child having
    // exited — is the hang this asserts against, and it is a successful return,
    // so the cancellation must not be reported as a `.stdin` failure either.
    const payload = try filler(a, 4 * 1024 * 1024);
    defer a.free(payload);

    var dog: Watchdog = .{ .io = io, .label = "orphan linger with a live writer", .limit_ms = 30_000 };
    try dog.arm();
    defer dog.disarm();

    var diag: process.Diagnostic = .{};
    if (runner.run(fixture(), .{
        .args = &.{ "spawn-orphan", fixture_exe, "5000" },
        .stdin = .{ .bytes = payload },
        .orphan_linger = .fromMilliseconds(300),
        .diagnostic = &diag,
    })) |res| {
        var r = res;
        defer r.deinit();
        try testing.expect(r.orphaned);
    } else |err| {
        // A broken pipe is a legitimate outcome (the child never read stdin);
        // a cancellation we caused ourselves is not.
        try testing.expect(err != error.Canceled);
        try testing.expectEqual(error.BrokenPipe, err);
    }
    try expectNoZombies();
}

test "a writer still running when the child exits is joined before the run returns" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // The child reads a little and exits; the parent still has megabytes to
    // write. The write cannot complete, so the run must observe that, close
    // stdin, and finish — and it must not scrub a borrowed `.secret` payload
    // until every task that could still be reading it has been joined.
    const payload = try filler(a, 2 * 1024 * 1024);
    defer a.free(payload);

    if (runner.run(fixture(), .{
        .args = &.{ "read-limited", "1024" },
        .stdin = .{ .secret = .{ .bytes = payload, .scrub_source = true } },
    })) |res| {
        var result = res;
        defer result.deinit();
        try testing.expect(result.ok());
    } else |err| {
        // A broken pipe on the normal path is reported as such, and that is a
        // legitimate outcome for this shape; either way the run terminated
        // rather than waiting forever on a write that can never complete.
        try testing.expectEqual(error.BrokenPipe, err);
    }
}

test "a forced Windows stop reports no synthetic Term" {
    // Windows-only: `NtTerminateProcess` sets the exit status to the code the
    // runner passed, so a status read back afterwards is one *we* invented. POSIX
    // has no equivalent problem — after `SIGKILL` the status genuinely says
    // `.signaled = .KILL`, which is real information and is reported.
    if (!is_windows) return error.SkipZigTest;

    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var diag: process.Diagnostic = .{};
    try testing.expectError(error.Timeout, runner.run(fixture(), .{
        .args = &.{ "sleep", "60000" },
        .timeout = timeout(300),
        .diagnostic = &diag,
    }));
    try testing.expectEqual(process.Phase.stop, diag.phase);
    try testing.expect(diag.term == null);
}

test "a Windows crash reports the full NTSTATUS, not a truncated exit code" {
    // The positive counterpart: on the *normal* path the runner reads the raw
    // `ExitStatus` itself, so an access violation comes back whole. `std`'s
    // `Child.wait` truncates `0xC0000005` to `u8`, which is exit code 5 —
    // indistinguishable from a deliberate `exit(5)`.
    if (!is_windows) return error.SkipZigTest;

    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var result = try runner.run(fixture(), .{ .args = &.{"access-violation"} });
    defer result.deinit();

    try testing.expect(!result.ok());
    try testing.expect(result.term == .unknown);
    try testing.expectEqual(@as(u32, 0xC0000005), result.term.unknown);
}

/// Installs `SIGCHLD = SIG_IGN` partway through a run, so the kernel auto-reaps
/// the child — but only *after* the runner has spawned it and acquired its
/// pidfd. Reaping before that point would be testing a guarantee the design
/// explicitly does not make (acquisition is itself pid-keyed), so the ordering is
/// the whole point of the fixture.
///
/// The ordering is a handshake in both directions, not a delay. A sleep long
/// enough to "probably" outlast the spawn fails silently in both directions: too
/// short and the disposition lands before acquisition, asserting a guarantee the
/// design does not make; too long and the child can be reaped normally first, so
/// the test passes without ever reaching the path. Here the reaper waits to be
/// told acquisition happened, and the run waits to be told the disposition is
/// installed — so by the time the child exits, the kernel is certain to be the
/// one that reaps it, and `ECHILD` is the required outcome rather than one of
/// two acceptable ones.
const LateReaper = struct {
    io: Io,
    previous: std.posix.Sigaction = undefined,
    acquired: std.atomic.Value(bool) = .init(false),
    installed: std.atomic.Value(bool) = .init(false),

    /// Neither side of the handshake waits forever: a run that never reaches
    /// acquisition (a spawn failure) would otherwise hang the join in the test's
    /// `defer`, and a reaper task that died would hang the run. Both give up and
    /// let the test fail on its assertions instead.
    const handshake_limit_ms: i64 = 30_000;

    fn waitFor(self: *LateReaper, flag: *const std.atomic.Value(bool)) void {
        var waited_ms: i64 = 0;
        while (!flag.load(.acquire)) : (waited_ms += 1) {
            if (waited_ms >= handshake_limit_ms) return;
            self.io.sleep(.fromMilliseconds(1), .boot) catch return;
        }
    }

    /// The reaper's own task: wait for acquisition, then take over reaping.
    fn run(self: *LateReaper) void {
        self.waitFor(&self.acquired);
        if (!self.acquired.load(.acquire)) return;
        var ignore: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.CHLD, &ignore, &self.previous);
        self.installed.store(true, .release);
    }

    /// Called by the runner, on the run's own task, the instant the pidfd is
    /// held. Publishes that and blocks until the disposition is actually in
    /// place, so the run cannot reach its first probe before the external reaper
    /// exists.
    fn onAcquired(self: *LateReaper) void {
        self.acquired.store(true, .release);
        self.waitFor(&self.installed);
    }

    fn restore(self: *LateReaper) void {
        if (self.installed.load(.acquire)) std.posix.sigaction(.CHLD, &self.previous, null);
    }
};

/// The hook is a bare function pointer, so the reaper under test is reached
/// through here. One test uses it at a time — Zig runs tests sequentially — and
/// it is cleared before the test returns.
var late_reaper: ?*LateReaper = null;

fn lateReaperHook() void {
    if (late_reaper) |r| r.onAcquired();
}

test "an external reap after pidfd acquisition is reported, never signalled through" {
    // Linux-gated: it needs both the `pidfd` hardening and the `SIG_IGN`
    // auto-reap semantics. What a pidfd actually buys is that *after* it is held,
    // no later signal can land on a recycled pid — so the reap has to be
    // coordinated to happen after acquisition, which is what `LateReaper` does.
    // A test that reaped before acquisition would be asserting a guarantee the
    // design deliberately does not claim.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var reaper: LateReaper = .{ .io = io };
    late_reaper = &reaper;
    process.identity_acquired_hook = &lateReaperHook;
    var reaper_future = try io.concurrent(LateReaper.run, .{&reaper});
    defer {
        process.identity_acquired_hook = null;
        late_reaper = null;
        _ = reaper_future.await(io);
        reaper.restore();
    }

    var dog: Watchdog = .{ .io = io, .label = "external reap after acquisition", .limit_ms = 30_000 };
    try dog.arm();
    defer dog.disarm();

    var diag: process.Diagnostic = .{};
    // `SIGCHLD = SIG_IGN` is in place before the run's first probe and the child
    // sleeps well past it, so the child is auto-reaped on exit and can never
    // become a zombie this runner could collect: the reap must come back
    // `ECHILD`. Accepting an ordinary success here would let the test pass
    // without exercising the path it exists for.
    if (runner.run(fixture(), .{ .args = &.{ "sleep", "300" }, .diagnostic = &diag })) |res| {
        var r = res;
        r.deinit();
        return error.TestExpectedExternalReapToBeReported;
    } else |err| {
        try testing.expectEqual(error.ChildReapedElsewhere, err);
        try testing.expectEqual(process.Phase.wait, diag.phase);
        try testing.expect(diag.term == null);
    }
}

// ---------------------------------------------------------------------------
// 26-27. Scrubbing
// ---------------------------------------------------------------------------

// The wipe itself cannot be observed from outside the module:
// `std.mem.Allocator.free` paints every released block with `undefined` before
// the allocator's own `free` ever sees it, so a wrapping allocator cannot tell
// a scrubbed buffer from an unscrubbed one. The sensitivity table is therefore
// asserted directly against the function both exit paths call, in process.zig.
// What is observable end to end — and asserted here — is the part that lives in
// caller-owned memory, plus the allocation shape a sensitive capture is
// promised.
test "a sensitive capture is allocated at its cap, so no realloc can strand a copy" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var result = try runner.run(fixture(), .{
        .args = &.{ "flood", "64" },
        .stdout = .{ .capture = .{ .limit = 4096, .overflow = .truncate, .sensitive = true } },
    });
    defer result.deinit();

    // 64 bytes retained, but the whole 4 KiB was taken up front — growing it
    // would have copied secret bytes into a new block and freed the old one
    // unzeroed, which is why `File.MultiReader` is not used for these.
    try testing.expectEqual(@as(usize, 64), result.stdout.len);
    try testing.expectEqual(@as(usize, 4096), result.stdout.buf.len);
    try testing.expect(result.stdout.sensitive);

    // The non-sensitive stream, by contrast, is grown as needed and its
    // `sensitive` flag is stored per stream — `deinit` has to be able to wipe
    // one and not the other.
    try testing.expect(!result.stderr.sensitive);
}

test "Scrub.on_failure hands back live bytes on success" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // The captured stdout *is* the value the caller wanted (`pass show`,
    // `op read`): scrubbing it on the way out would return zeros, which is
    // obviously not the intent.
    var result = try runner.run(fixture(), .{
        .args = &.{ "flood", "64" },
        .stdout = .{ .capture = .{ .limit = 4096, .overflow = .truncate, .sensitive = true } },
        .scrub = .on_failure,
    });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 64), result.stdout.len);
    try testing.expect(result.stdout.bytes()[0] != 0);
}

test "scrub_source zeroes the caller's secret once the last byte is handed over" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    const secret = try filler(a, 4096);
    defer a.free(secret);

    var result = try runner.run(fixture(), .{
        .args = &.{"echo"},
        .stdin = .{ .secret = .{ .bytes = secret, .scrub_source = true } },
    });
    defer result.deinit();

    try testing.expect(result.ok());
    // The child received the real bytes...
    try testing.expectEqual(@as(usize, 4096), result.stdout.len);
    try testing.expect(result.stdout.bytes()[0] != 0);
    // ...and the caller's copy is gone.
    for (secret) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "scrub_source follows the staging column, not the capture column" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // Staging is wiped under `.on_failure` even on a *successful* run: nothing is
    // ever handed back from it, so there is no success case in which the payload
    // is still wanted. This is the one cell of the sensitivity table that is
    // visible from outside the module, because the buffer is the caller's.
    {
        const secret = try filler(a, 256);
        defer a.free(secret);
        var r = try runner.run(fixture(), .{
            .args = &.{"echo"},
            .stdin = .{ .secret = .{ .bytes = secret, .scrub_source = true } },
            .scrub = .on_failure,
        });
        defer r.deinit();
        try testing.expect(r.ok());
        for (secret) |b| try testing.expectEqual(@as(u8, 0), b);
    }

    // `.never` really means never — the flag is proven to do something by the
    // case where it does nothing.
    {
        const secret = try filler(a, 256);
        defer a.free(secret);
        var r = try runner.run(fixture(), .{
            .args = &.{"echo"},
            .stdin = .{ .secret = .{ .bytes = secret, .scrub_source = true } },
            .scrub = .never,
        });
        defer r.deinit();
        try testing.expect(r.ok());
        try testing.expect(secret[0] != 0);
    }

    // And without `scrub_source` the payload is left alone regardless.
    {
        const secret = try filler(a, 256);
        defer a.free(secret);
        var r = try runner.run(fixture(), .{
            .args = &.{"echo"},
            .stdin = .{ .secret = .{ .bytes = secret } },
        });
        defer r.deinit();
        try testing.expect(r.ok());
        try testing.expect(secret[0] != 0);
    }
}

// ---------------------------------------------------------------------------
// 28-30. Diagnostics and the environment
// ---------------------------------------------------------------------------

test "the reported program path survives the runner's teardown" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var program_buf: [std.fs.max_path_bytes]u8 = undefined;
    var diag: process.Diagnostic = .{ .program_buf = &program_buf };

    // A failing run, so the diagnostic is written; the path it reports lives in
    // the caller's buffer, which is exactly why it is still readable here.
    try testing.expectError(error.OutputTooLarge, runner.run(fixture(), .{
        .args = &.{ "flood", "5000" },
        .stdout = .{ .capture = .{ .limit = 10, .overflow = .fail } },
        .diagnostic = &diag,
    }));
    const reported = diag.program().?;
    try testing.expect(std.fs.path.isAbsolute(reported));
    try testing.expect(std.mem.indexOf(u8, reported, "process-fixture") != null);
}

test "env policies reach the child, and .replace inherits nothing" {
    const a = testing.allocator;
    const io = testing.io;

    var env = emptyEnv(a);
    defer env.deinit();
    try env.put("ZCLI_KEEP", "keep");
    try env.put("ZCLI_DROP", "drop");
    var runner = process.Runner.init(a, io, &env);

    {
        var r = try runner.run(fixture(), .{
            .args = &.{ "env", "ZCLI_KEEP" },
            .env = .{ .policy = .{ .allow = &.{"ZCLI_KEEP"} } },
        });
        defer r.deinit();
        try testing.expectEqualStrings("keep", r.stdout.bytes());
    }
    {
        var r = try runner.run(fixture(), .{
            .args = &.{ "env", "ZCLI_DROP" },
            .env = .{ .policy = .{ .allow = &.{"ZCLI_KEEP"} } },
        });
        defer r.deinit();
        try testing.expectEqualStrings("", r.stdout.bytes());
    }
    {
        var r = try runner.run(fixture(), .{
            .args = &.{ "env", "ZCLI_DROP" },
            .env = .{ .policy = .{ .deny = &.{"ZCLI_DROP"} } },
        });
        defer r.deinit();
        try testing.expectEqualStrings("", r.stdout.bytes());
    }
    {
        var r = try runner.run(fixture(), .{
            .args = &.{ "env", "ZCLI_ADDED" },
            .env = .{ .add = &.{.{ .name = "ZCLI_ADDED", .value = "added" }} },
        });
        defer r.deinit();
        try testing.expectEqualStrings("added", r.stdout.bytes());
    }
    {
        // `.replace` inherits nothing, so the child sees exactly one variable.
        var r = try runner.run(fixture(), .{
            .args = &.{"env-count"},
            .env = .{ .policy = .{ .replace = &.{.{ .name = "ONLY", .value = "1" }} } },
        });
        defer r.deinit();
        try testing.expectEqualStrings("1", r.stdout.bytes());
    }
}

test "hermeticity: the test process's own environment does not reach the child" {
    const a = testing.allocator;
    const io = testing.io;

    // The runner's base map is the one threaded in, never the ambient
    // environment — nothing in the module calls `getenv`. PATH is set in the
    // real process environment of every developer and CI machine there is, so
    // its absence from the child is the assertion.
    var env = emptyEnv(a);
    defer env.deinit();
    try env.put("PATH", "/definitely/not/real");
    var runner = process.Runner.init(a, io, &env);

    var r = try runner.run(fixture(), .{
        .args = &.{ "env", "PATH" },
        .env = .{ .policy = .{ .replace = &.{.{ .name = "OTHER", .value = "x" }} } },
    });
    defer r.deinit();
    try testing.expectEqualStrings("", r.stdout.bytes());
}

test "the child's cwd is Options.cwd, not wherever the program path pointed" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try runner.run(fixture(), .{ .args = &.{"cwd"}, .cwd = .{ .dir = tmp.dir } });
    defer r.deinit();
    try testing.expect(r.ok());
    try testing.expect(r.stdout.len > 0);
    // The fixture lives in the build cache, so a child that had merely inherited
    // our cwd would not be reporting the temp directory.
    var expected_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expected_len = try tmp.dir.realPath(io, &expected_buf);
    try testing.expect(std.mem.endsWith(u8, r.stdout.trimmed(), std.fs.path.basename(expected_buf[0..expected_len])));
}

// ---------------------------------------------------------------------------
// 31. Concurrency
// ---------------------------------------------------------------------------

test "a timeout with no captured streams does not require concurrency" {
    const a = testing.allocator;
    var threaded: Io.Threaded = .init(a, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();

    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // The contract, asserted rather than assumed. A run with no captured streams
    // and no stdin payload enforces its deadline on a single task — clock check,
    // `probe`, `io.sleep` — so refusing it for want of a task pool would fail
    // something the mechanism can service. (An earlier revision of the design
    // raced a concurrent `Child.wait`, which genuinely did need one; ADR-0034
    // records why that sentence no longer applies.)
    // The watchdog runs on the *test's* Io, not the starved one under test —
    // arming it there would need the very capability the test withholds.
    var dog: Watchdog = .{ .io = testing.io, .label = "timeout without concurrency", .limit_ms = 20_000 };
    try dog.arm();
    defer dog.disarm();

    const start: Io.Clock.Timestamp = .now(io, .boot);
    try testing.expectError(error.Timeout, runner.run(fixture(), .{
        .args = &.{ "sleep", "60000" },
        .stdout = .ignore,
        .stderr = .ignore,
        .timeout = timeout(300),
    }));
    try testing.expect(elapsedMs(io, start) >= 250);
    try expectNoZombies();
}

test "draining is what needs concurrency, and says so rather than deadlocking" {
    if (is_windows) return error.SkipZigTest;

    const a = testing.allocator;
    var threaded: Io.Threaded = .init(a, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();

    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // On POSIX `awaitConcurrent` is `poll`-driven, so it satisfies its
    // concurrency requirement without a task pool at all — the drains and the
    // nonblocking stdin write still make independent progress, and the run
    // succeeds. An `Io` that genuinely cannot would surface
    // `error.ConcurrencyUnavailable` here rather than deadlocking, which is the
    // refusal the module promises. Either answer is correct; hanging is not.
    const payload = try filler(a, 256 * 1024);
    defer a.free(payload);

    var dog: Watchdog = .{ .io = testing.io, .label = "drain without a task pool", .limit_ms = 30_000 };
    try dog.arm();
    defer dog.disarm();

    var result = runner.run(fixture(), .{
        .args = &.{"echo"},
        .stdin = .{ .bytes = payload },
        .stdout = .{ .capture = .{ .limit = 1 << 20, .overflow = .fail } },
    }) catch |err| {
        try testing.expectEqual(error.ConcurrencyUnavailable, err);
        return;
    };
    defer result.deinit();
    try testing.expectEqualSlices(u8, payload, result.stdout.bytes());
}

// ---------------------------------------------------------------------------
// 35. Teardown errors do not mask the primary failure
// ---------------------------------------------------------------------------

test "a cap overflow reports OutputTooLarge, not the broken pipe it caused" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();
    var runner = process.Runner.init(a, io, &env);

    // The child floods stdout past the cap while the parent is still feeding it
    // megabytes of stdin. Stopping the child breaks that pipe, so the writer
    // reports `BrokenPipe` — which the runner caused while cleaning up and must
    // not report in place of the real failure.
    const payload = try filler(a, 4 * 1024 * 1024);
    defer a.free(payload);

    var diag: process.Diagnostic = .{};
    try testing.expectError(error.OutputTooLarge, runner.run(fixture(), .{
        .args = &.{ "flood", "1000000" },
        .stdin = .{ .bytes = payload },
        .stdout = .{ .capture = .{ .limit = 100, .overflow = .fail } },
        .diagnostic = &diag,
    }));
    try testing.expectEqual(process.Phase.capture, diag.phase);
    try expectNoZombies();
}

test "the convenience wrappers behave like run with defaults" {
    const a = testing.allocator;
    const io = testing.io;
    var env = emptyEnv(a);
    defer env.deinit();

    var runner = process.Runner.init(a, io, &env);
    var via_capture = try runner.capture(fixture(), &.{ "flood", "16" });
    defer via_capture.deinit();
    try testing.expectEqual(@as(usize, 16), via_capture.stdout.len);

    var via_free_fn = try process.run(a, io, &env, fixture(), .{ .args = &.{ "exit", "0" } });
    defer via_free_fn.deinit();
    try testing.expect(via_free_fn.ok());
}
