//! The child process the `process.zig` integration tests drive.
//!
//! Cross-platform is a hard requirement for those tests, which rules out
//! `/bin/sh` as the only child — so the behaviours they need (echo a payload,
//! flood a stream, exit with a code, ignore SIGTERM, strand a grandchild on the
//! output pipe) are spelled once here and selected by `argv[1]`. It is declared
//! in `build.zig` as a test dependency, so it is compiled once by the build
//! rather than by each test at runtime.
//!
//! Every mode is deliberately dumb: no allocation beyond the argument slice, no
//! buffering layer, one `io.operate` per read and write. A fixture with its own
//! cleverness would make a failing test ambiguous about which side broke.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const is_windows = builtin.os.tag == .windows;

/// The `signal-self` mode exists to die of SIGSEGV so the runner has a
/// `.signaled` termination to report. Zig installs a segfault handler in Debug
/// builds, which turns that into a panic and an abort — SIGABRT, not SIGSEGV —
/// so the fixture opts out. Nothing else here depends on it.
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

/// Filler pattern for the flood modes. Non-uniform so a test that round-trips
/// it can catch a misaligned re-arm, which a run of identical bytes would hide.
fn fillerByte(i: u64) u8 {
    return @intCast('A' + (i % 26));
}

const chunk_len = 64 * 1024;

fn writeAll(io: Io, file: Io.File, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        var iov: [1][]const u8 = .{remaining};
        const result = try io.operate(.{ .file_write_streaming = .{ .file = file, .data = &iov } });
        const n = try result.file_write_streaming;
        remaining = remaining[n..];
    }
}

/// Returns 0 at end of stream.
fn readSome(io: Io, file: Io.File, buf: []u8) !usize {
    var iov: [1][]u8 = .{buf};
    const result = try io.operate(.{ .file_read_streaming = .{ .file = file, .data = &iov } });
    return result.file_read_streaming catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| e,
    };
}

/// Write `total` filler bytes to `file`, `chunk_len` at a time.
fn flood(io: Io, file: Io.File, total: u64) !void {
    var buf: [chunk_len]u8 = undefined;
    var written: u64 = 0;
    while (written < total) {
        const n: usize = @intCast(@min(@as(u64, chunk_len), total - written));
        for (buf[0..n], 0..) |*b, i| b.* = fillerByte(written + i);
        try writeAll(io, file, buf[0..n]);
        written += n;
    }
}

fn parse(s: []const u8) u64 {
    return std.fmt.parseInt(u64, s, 10) catch 0;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) std.process.exit(64);

    const mode = args[1];
    const stdout = Io.File.stdout();
    const stderr = Io.File.stderr();
    const stdin = Io.File.stdin();

    if (std.mem.eql(u8, mode, "exit")) {
        std.process.exit(@intCast(parse(args[2]) & 0xff));
    }

    if (std.mem.eql(u8, mode, "sleep")) {
        io.sleep(.fromMilliseconds(@intCast(parse(args[2]))), .boot) catch {};
        return;
    }

    // Copy stdin to stdout until EOF. The shape that deadlocks a runner which
    // writes stdin to completion before reading.
    if (std.mem.eql(u8, mode, "echo")) {
        var buf: [chunk_len]u8 = undefined;
        while (true) {
            const n = try readSome(io, stdin, &buf);
            if (n == 0) break;
            try writeAll(io, stdout, buf[0..n]);
        }
        return;
    }

    // Echo stdin while also producing `args[2]` bytes on stderr, interleaved —
    // so all three streams must make progress independently or nothing finishes.
    if (std.mem.eql(u8, mode, "echo-both")) {
        const err_total = parse(args[2]);
        var err_written: u64 = 0;
        var buf: [chunk_len]u8 = undefined;
        var err_buf: [chunk_len]u8 = undefined;
        while (true) {
            const n = try readSome(io, stdin, &buf);
            if (n == 0) break;
            try writeAll(io, stdout, buf[0..n]);
            if (err_written < err_total) {
                const m: usize = @intCast(@min(@as(u64, n), err_total - err_written));
                for (err_buf[0..m], 0..) |*b, i| b.* = fillerByte(err_written + i);
                try writeAll(io, stderr, err_buf[0..m]);
                err_written += m;
            }
        }
        while (err_written < err_total) {
            const m: usize = @intCast(@min(@as(u64, chunk_len), err_total - err_written));
            for (err_buf[0..m], 0..) |*b, i| b.* = fillerByte(err_written + i);
            try writeAll(io, stderr, err_buf[0..m]);
            err_written += m;
        }
        return;
    }

    if (std.mem.eql(u8, mode, "flood")) {
        try flood(io, stdout, parse(args[2]));
        return;
    }

    if (std.mem.eql(u8, mode, "flood-err")) {
        try flood(io, stderr, parse(args[2]));
        return;
    }

    if (std.mem.eql(u8, mode, "flood-both")) {
        try flood(io, stdout, parse(args[2]));
        try flood(io, stderr, parse(args[3]));
        return;
    }

    // Write to stdout until someone stops us. The strict-timeout regression: a
    // runner that infers its deadline from "the backend had nothing ready" never
    // stops this child.
    if (std.mem.eql(u8, mode, "flood-forever")) {
        var buf: [chunk_len]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = fillerByte(i);
        while (true) writeAll(io, stdout, &buf) catch return;
    }

    // Read exactly `args[2]` bytes and exit, leaving a writer with a broken pipe.
    if (std.mem.eql(u8, mode, "read-limited")) {
        const want = parse(args[2]);
        var got: u64 = 0;
        var buf: [chunk_len]u8 = undefined;
        while (got < want) {
            const room: usize = @intCast(@min(@as(u64, chunk_len), want - got));
            const n = try readSome(io, stdin, buf[0..room]);
            if (n == 0) break;
            got += n;
        }
        return;
    }

    // Never read stdin: say something on stderr and exit `args[2]`. The shape a
    // helper takes when it rejects a payload — the parent's write breaks against
    // a closed read end, while the exit status and the stderr message are the
    // account of the run that actually matters.
    if (std.mem.eql(u8, mode, "reject")) {
        try writeAll(io, stderr, "rejected");
        std.process.exit(@intCast(parse(args[2]) & 0xff));
    }

    // Never read stdin; just sit there. Fills the stdin pipe and blocks the
    // parent's writer, which is the Windows abort-handoff case.
    if (std.mem.eql(u8, mode, "no-read")) {
        io.sleep(.fromMilliseconds(@intCast(parse(args[2]))), .boot) catch {};
        return;
    }

    // Close both output streams, then keep running. A runner that exits when the
    // pipes reach EOF returns here with the child still alive and no `Term`.
    if (std.mem.eql(u8, mode, "quiet-then-sleep")) {
        stdout.close(io);
        stderr.close(io);
        io.sleep(.fromMilliseconds(@intCast(parse(args[2]))), .boot) catch {};
        return;
    }

    // Close the outputs, then drain stdin slowly. Leaves the parent's stdin
    // write as the only operation in flight — the shape that busy-spins if the
    // runner ever awaits a singleton operation with no deadline.
    if (std.mem.eql(u8, mode, "slow-read")) {
        stdout.close(io);
        stderr.close(io);
        const delay_ms: i64 = @intCast(parse(args[2]));
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try readSome(io, stdin, &buf);
            if (n == 0) break;
            io.sleep(.fromMilliseconds(delay_ms), .boot) catch {};
        }
        return;
    }

    // Hand our stdout to a grandchild that writes nothing, then exit. The parent
    // sees the child die while the pipe stays open — the orphan-linger case. A
    // *chatty* grandchild would keep waking the drain by accident and pass even
    // a runner with no linger at all, which is why this one is silent.
    if (std.mem.eql(u8, mode, "spawn-orphan")) {
        var grandchild = try std.process.spawn(io, .{
            .argv = &.{ args[2], "hold", args[3] },
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        // Deliberately not waited on: this process exits while the grandchild
        // holds the write end.
        _ = &grandchild;
        return;
    }

    // Hand our *stdin* to a grandchild that never reads it, then exit. This is
    // the shape that makes "terminate the direct child" insufficient: the pipe's
    // read end outlives the child we can see, so a parent still writing into it
    // stays blocked. Only cancelling the writer releases it.
    if (std.mem.eql(u8, mode, "spawn-stdin-holder")) {
        var grandchild = try std.process.spawn(io, .{
            .argv = &.{ args[2], "hold", args[3] },
            .stdin = .inherit,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = &grandchild;
        return;
    }

    if (std.mem.eql(u8, mode, "hold")) {
        io.sleep(.fromMilliseconds(@intCast(parse(args[2]))), .boot) catch {};
        return;
    }

    if (std.mem.eql(u8, mode, "env")) {
        if (init.environ_map.get(args[2])) |v| try writeAll(io, stdout, v);
        return;
    }

    if (std.mem.eql(u8, mode, "env-count")) {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{init.environ_map.count()}) catch "0";
        try writeAll(io, stdout, s);
        return;
    }

    if (std.mem.eql(u8, mode, "cwd")) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.process.currentPath(io, &buf);
        try writeAll(io, stdout, buf[0..n]);
        return;
    }

    if (is_windows) {
        // Die of an access violation, so the runner has an NTSTATUS that does not
        // fit `u8` to report. `std`'s `Child.wait` truncates this to exit code 5;
        // reading the status directly is what keeps a crash from masquerading as
        // a deliberate `exit(5)`.
        if (std.mem.eql(u8, mode, "access-violation")) {
            const p: *volatile u8 = @ptrFromInt(0x8);
            p.* = 1;
            return;
        }
    }

    if (!is_windows) {
        // Die of a signal, so the runner has something with a `.signaled` term to
        // report. Windows has no signals, so these two modes are POSIX-only and
        // the tests that use them skip there.
        if (std.mem.eql(u8, mode, "signal-self")) {
            std.posix.raise(.SEGV) catch {};
            return;
        }

        if (std.mem.eql(u8, mode, "ignore-sigterm")) {
            var act: std.posix.Sigaction = .{
                .handler = .{ .handler = std.posix.SIG.IGN },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(.TERM, &act, null);
            io.sleep(.fromMilliseconds(@intCast(parse(args[2]))), .boot) catch {};
            return;
        }
    }

    std.process.exit(64);
}
