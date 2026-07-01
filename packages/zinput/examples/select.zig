//! `zinput.select` — choose one item from a list with the arrow keys and Enter.

const std = @import("std");
const zinput = @import("zinput");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const fruits = [_][]const u8{ "Apple", "Banana", "Cherry", "Dragonfruit", "Elderberry" };

    const idx = zinput.select(t.w(), t.r(), .{
        .message = "Pick a fruit:",
        .choices = &fruits,
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };

    try t.w().print("\nYou picked: {s}\n", .{fruits[idx]});
}
