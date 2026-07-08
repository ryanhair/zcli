//! `Prompts.search` — type to fuzzy-filter a list, arrow keys to pick, Enter to select.

const std = @import("std");
const prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: prompts.Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    const languages = [_][]const u8{
        "Zig",    "Rust",       "Go",         "C",       "C++",
        "Python", "JavaScript", "TypeScript", "Haskell", "OCaml",
    };

    const idx = p.search(.{
        .message = "Search languages (type to filter):",
        .choices = &languages,
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };

    try t.w().print("\nYou chose: {s}\n", .{languages[idx]});
}
