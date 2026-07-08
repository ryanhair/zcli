//! `Prompts.confirm` — a yes/no question with a default (Enter accepts it).

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
        .default = false,
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };

    try t.w().print("\n{s}\n", .{if (ok) "Deploying." else "Cancelled."});
}
