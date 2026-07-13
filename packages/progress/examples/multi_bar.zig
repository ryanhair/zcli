//! Multi-bar — stacked labelled bars for parallel work.
//!
//! `multiBar` renders one row per tracked item: a label column, a bar, and a
//! percentage. It's the right tool for concurrent downloads or a fan-out of
//! jobs. `add` returns a handle you use with `set`/`increment`; both are
//! thread-safe, so worker threads can report progress on their own bar while the
//! frame repaints as a unit.
//!
//! This example spawns a worker per item with `io.concurrent`, each ticking its
//! own bar at a different rate. Piped output is silent (log your own lines when
//! not a TTY); on a terminal you see all bars advancing together.

const std = @import("std");
const Progress = @import("progress");
const common = @import("common.zig");

const Job = struct {
    mb: *Progress.MultiBar,
    io: std.Io,
    handle: usize,
    total: usize,
    step_ms: u64,

    fn run(self: *Job) void {
        var done: usize = 0;
        while (done < self.total) {
            common.sleepMs(self.io, self.step_ms);
            done += 1;
            // `set` is thread-safe: many workers, one repainting frame.
            self.mb.set(self.handle, done);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out: common.Io = .{};
    out.init(io);
    defer out.flush();

    const p: Progress = .{ .writer = out.w(), .io = io, .allocator = init.gpa };

    var mb = try p.multiBar(.{ .width = 54, .show_percent = true });
    defer mb.deinit();

    // Register three parallel downloads. `add(label, total)` → a bar handle.
    var jobs = [_]Job{
        .{ .mb = &mb, .io = io, .handle = try mb.add("api.tar.gz", 100), .total = 100, .step_ms = 18 },
        .{ .mb = &mb, .io = io, .handle = try mb.add("assets.zip", 60), .total = 60, .step_ms = 30 },
        .{ .mb = &mb, .io = io, .handle = try mb.add("docs.tgz", 40), .total = 40, .step_ms = 45 },
    };

    // Kick off a worker per bar. `io.concurrent` returns a future we join below.
    var futures: [jobs.len]?std.Io.Future(void) = .{ null, null, null };
    for (&jobs, &futures) |*job, *fut| {
        fut.* = io.concurrent(Job.run, .{job}) catch null;
    }

    // Wait for every worker to finish before we tear the bars down.
    for (&futures) |*fut| {
        if (fut.*) |*f| _ = f.await(io);
    }

    // `finish` persists the final frame (all bars at 100%) into scrollback.
    mb.finish();

    try out.w().print("all downloads complete\n", .{});
}
