//! log_appender.zig — a worker *process* for src/log_multiprocess_test.zig.
//!
//!   log-appender <title> <count>
//!
//! waits for a start signal, then appends `count` records to the log in the
//! current directory and exits. That is the whole program: the test spawns
//! several of these at once, all pointed at one log, and checks that every
//! record arrived intact.
//!
//! The start signal is end-of-file on stdin, which makes contention real rather
//! than hoped for. Spawning is slow and uneven: without a barrier the first
//! child can finish all its appends before the last one has started, and a lock
//! that did nothing at all would still pass the test. Blocking every child here
//! lets the parent release them together. (Run by hand from a terminal, that
//! means it waits for Ctrl-D before doing anything.)
//!
//! It exists because threads cannot stand in for processes here. An advisory
//! lock is owned by an open file description and released by the kernel when
//! the process holding it dies, so "the lock is dropped on exit" and "a killed
//! writer's fragment is repaired by the next one" are properties only separate
//! processes actually exercise. Not installed — `zig build` builds it so the
//! test has something to race, and nothing ships it.

const std = @import("std");
const log = @import("log");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;

    const title = args[1];
    const count = try std.fmt.parseInt(usize, args[2], 10);

    waitForStart(init.io);

    for (0..count) |_| {
        try log.append(std.Io.Dir.cwd(), init.io, .{ .action = "add", .title = title });
    }
}

/// Block until stdin reaches end-of-file — the parent closing our stdin is the
/// "go" every sibling is waiting for too.
///
/// Any read failure also means go: this is a barrier, not a channel, and
/// hanging forever on a broken pipe would turn a test failure into a timeout.
fn waitForStart(io: std.Io) void {
    const stdin = std.Io.File.stdin();
    var scratch: [1]u8 = undefined;
    while (true) {
        _ = stdin.readStreaming(io, &.{&scratch}) catch return;
    }
}
