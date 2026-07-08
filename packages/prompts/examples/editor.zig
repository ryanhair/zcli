//! `Prompts.editor` — capture multi-line input by launching an external editor.
//!
//! Pressing Enter opens the editor (`editor_cmd`, default `vi`) on a temporary
//! file seeded with `default`; whatever is saved is returned.

const std = @import("std");
const Prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    const message = p.editor(.{
        .message = "Write a commit message",
        .default = "Summary line\n\nDetails go here.\n",
        .extension = ".md",
        .io = init.io,
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };
    defer init.gpa.free(message);

    try t.w().print("\n--- captured ({d} bytes) ---\n{s}\n", .{ message.len, message });
}
