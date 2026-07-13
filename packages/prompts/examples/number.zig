//! `Prompts.number` — integer (`i64`) input with an optional default and bounds.
//!
//! Only digits (and a leading `-`) are accepted as you type. `default` is
//! returned on an empty Enter; `min`/`max` are enforced — an out-of-range value
//! shows an inline error and re-prompts rather than returning. (No default plus
//! empty/invalid input on a non-TTY yields `error.InvalidNumber`.)

const std = @import("std");
const Prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    const n = p.number(.{
        .message = "Pick a number (1-100)",
        .default = 42, // Enter with no input returns this
        .min = 1,
        .max = 100,
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };

    try t.w().print("\nYou entered: {d}\n", .{n});
}
