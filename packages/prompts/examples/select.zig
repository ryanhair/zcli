//! `Prompts.select` — choose one item from a list with the arrow keys and Enter.

const std = @import("std");
const prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: prompts.Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    const fruits = [_][]const u8{ "Apple", "Banana", "Cherry", "Dragonfruit", "Elderberry" };

    const idx = p.select(.{
        .message = "Pick a fruit:",
        .choices = &fruits,
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };

    try t.w().print("\nYou picked: {s}\n", .{fruits[idx]});
}
