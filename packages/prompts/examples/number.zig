//! `Prompts.number` — integer input with an optional default and min/max bounds.

const std = @import("std");
const prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: prompts.Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    const n = p.number(.{
        .message = "Pick a number",
        .default = 42,
        .min = 1,
        .max = 100,
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };

    try t.w().print("\nYou entered: {d}\n", .{n});
}
