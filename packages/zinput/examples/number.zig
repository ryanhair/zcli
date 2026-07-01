//! `zinput.number` — integer input with an optional default and min/max bounds.

const std = @import("std");
const zinput = @import("zinput");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const n = zinput.number(t.w(), t.r(), .{
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
