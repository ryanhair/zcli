//! `Prompts.password` — masked input; the typed characters are never echoed.

const std = @import("std");
const prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: prompts.Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    const secret = p.password(.{
        .message = "Enter a password:",
        .mask = '*',
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };
    defer init.gpa.free(secret);

    // Don't print the secret back — just prove we captured it.
    try t.w().print("\nGot a password of {d} character(s).\n", .{secret.len});
}
