//! `prompts.text` — free-form single-line text input with an optional default.

const std = @import("std");
const prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const name = prompts.text(t.w(), t.r(), init.gpa, .{
        .message = "What's your name?",
        .default = "Anonymous",
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };
    defer init.gpa.free(name);

    try t.w().print("\nHello, {s}!\n", .{name});
}
