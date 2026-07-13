//! Spinner styles — the nine built-in animations, and the finish states.
//!
//! `SpinnerStyle` ships nine looks, each with a tuned frame interval:
//!   dots, dots2, dots3, line, arrow, bounce, clock, moon, simple
//! This example runs each one briefly, then demonstrates the four themed
//! finish states plus `persist` (a custom symbol) and `stop` (leave nothing).
//!
//! Braille/emoji styles assume a Unicode terminal. Set `.unicode = false` in
//! the config (or run on a terminal without Unicode) and the result symbols
//! degrade to ASCII automatically.

const std = @import("std");
const Progress = @import("progress");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out: common.Io = .{};
    out.init(io);
    defer out.flush();

    const p: Progress = .{ .writer = out.w(), .io = io, .allocator = init.gpa };

    // Show each style for a moment, then persist a labelled line for it.
    inline for (.{
        .{ Progress.SpinnerStyle.dots, "dots" },
        .{ Progress.SpinnerStyle.dots2, "dots2" },
        .{ Progress.SpinnerStyle.dots3, "dots3" },
        .{ Progress.SpinnerStyle.line, "line" },
        .{ Progress.SpinnerStyle.arrow, "arrow" },
        .{ Progress.SpinnerStyle.bounce, "bounce" },
        .{ Progress.SpinnerStyle.clock, "clock" },
        .{ Progress.SpinnerStyle.moon, "moon" },
        .{ Progress.SpinnerStyle.simple, "simple" },
    }) |pair| {
        const style, const name = pair;
        var s = try p.spinner(.{ .style = style });
        s.start(name ++ " style");
        common.sleepMs(io, 700);
        // `persist` stops the animation and prints "<symbol> <message>" as a
        // static line — here a bullet, so styles list cleanly.
        s.persist("•", name ++ " style");
    }

    // The four themed finish states, each with its own symbol + palette role.
    var ok = try p.spinner(.{});
    ok.start("running checks");
    common.sleepMs(io, 500);
    ok.succeed("all checks passed"); // ✓ success

    var bad = try p.spinner(.{});
    bad.start("running checks");
    common.sleepMs(io, 500);
    bad.fail("2 checks failed"); // ✗ error

    var caution = try p.spinner(.{});
    caution.start("running checks");
    common.sleepMs(io, 500);
    caution.warn("1 check skipped"); // ⚠ warning

    var note = try p.spinner(.{});
    note.start("running checks");
    common.sleepMs(io, 500);
    note.info("cache was cold"); // ℹ info

    // `stop` ends the animation and clears the line — no result printed.
    var quiet = try p.spinner(.{});
    quiet.start("cleaning up (this line disappears)");
    common.sleepMs(io, 700);
    quiet.stop();

    try out.w().print("done — six finish states demonstrated\n", .{});
}
