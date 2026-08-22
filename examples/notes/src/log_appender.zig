//! log_appender.zig — a worker *process* for src/log_multiprocess_test.zig.
//!
//!   log-appender <title> <count>
//!
//! appends `count` records to the log in the current directory and exits. That
//! is the whole program: the test spawns several of these at once, all pointed
//! at one log, and checks that every record arrived intact.
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

    for (0..count) |_| {
        try log.append(std.Io.Dir.cwd(), init.io, .{ .action = "add", .title = title });
    }
}
