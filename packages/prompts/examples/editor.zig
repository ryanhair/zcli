//! `Prompts.editor` — capture multi-line input by launching an external editor.
//!
//! Pressing Enter opens `editor_cmd` on a temp file seeded with `default`;
//! whatever is saved (trailing newlines trimmed) is returned. Options:
//!   * `editor_cmd` — the program to launch (default `vi`). Here we honour the
//!                    user's `$EDITOR`, falling back to `vi`.
//!   * `extension`  — temp-file suffix so the editor picks the right syntax
//!                    highlighting (`.md`, `.txt`, ...).
//!   * `io`         — the editor spawns a child process and does file I/O, so it
//!                    needs the process `std.Io` (unlike the other prompts).

const std = @import("std");
const Prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    // Respect the user's editor of choice; fall back to vi.
    const editor_cmd = init.environ_map.get("EDITOR") orelse "vi";

    const message = p.editor(.{
        .message = "Write a commit message",
        .default = "Summary line\n\nDetails go here.\n",
        .extension = ".md",
        .editor_cmd = editor_cmd,
        .io = init.io,
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };
    defer init.gpa.free(message);

    try t.w().print("\n--- captured ({d} bytes) ---\n{s}\n", .{ message.len, message });
}
