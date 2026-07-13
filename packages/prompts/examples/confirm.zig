//! `Prompts.confirm` — a yes/no question.
//!
//! Options shown here:
//!   * `default`        — chosen when the user just presses Enter. It also picks
//!                        the highlighted letter in the hint: `(Y/n)` vs `(y/N)`.
//!   * `interrupt_keys` — Esc aborts with `error.Interrupted` (distinct from a
//!                        "no" answer — the caller decides what cancelling means).

const std = @import("std");
const Prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    const ok = p.confirm(.{
        .message = "Deploy to production?",
        .default = false, // Enter means "no" here, and the hint shows (y/N)
        .interrupt_keys = &.{.escape},
    }) catch |err| switch (err) {
        error.Interrupted => {
            try t.w().writeAll("\n(cancelled — nothing happened)\n");
            return;
        },
        else => return err,
    };

    try t.w().print("\n{s}\n", .{if (ok) "Deploying." else "Cancelled."});
}
