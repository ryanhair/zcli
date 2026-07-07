//! `prompts.editor` — capture multi-line input by launching an external editor.
//!
//! Pressing Enter opens the editor (`editor_cmd`, default `vi`) on a temporary
//! file seeded with `default`; whatever is saved is returned.

const std = @import("std");
const prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const message = prompts.editor(t.w(), t.r(), init.gpa, .{
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
