//! Progress bar — determinate progress over a known total.
//!
//! Unlike the spinner, a bar is caller-driven: there's no background task. Each
//! `update` (or `increment`) paints exactly one frame, so you drive it from your
//! own work loop. The bar computes percentage, ETA, elapsed time, and rate from
//! the wall clock — all opt-in via `ProgressBarConfig`.
//!
//! On a pipe the bar stays completely silent until `finish`, which emits one
//! summary line ("<message> N/N (100%)") — perfect for CI logs that shouldn't
//! be flooded with carriage returns.

const std = @import("std");
const Progress = @import("progress");
const common = @import("common.zig");

// Indicators hide the cursor, so a panic must restore the terminal.
pub const panic = Progress.panic;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out: common.Io = .{};
    out.init(io);
    defer out.flush();

    const p: Progress = .{ .writer = out.w(), .io = io, .allocator = init.gpa };

    const total: usize = 60;

    // Turn on every stat so the example doubles as a reference for the config.
    var bar = try p.progressBar(.{
        .total = total,
        .width = 30, // bar body width, excluding brackets + stats
        .prefix = "Downloading ",
        .show_percentage = true, // "  50%"
        .show_eta = true, // "ETA: 3s" (hidden at 0% and 100%)
        .show_elapsed = true, // "[1m2s]"
        .show_rate = true, // "1.5/s"
    });
    defer bar.deinit();

    for (0..total) |i| {
        common.sleepMs(io, 40); // simulate a chunk of work

        // `update` sets the absolute value and (optionally) the message shown
        // before the bar. Passing null keeps the current message.
        if (i == total / 3) {
            bar.update(i + 1, "second file");
        } else {
            bar.update(i + 1, null);
        }
    }

    // `finish` snaps to 100% and, by default, leaves the final frame on screen
    // (set `.clear_on_finish = true` to erase it instead). Use
    // `finishWithMessage` to swap in a completion label.
    bar.finishWithMessage("download complete");
}
