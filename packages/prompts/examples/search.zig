//! `Prompts.search` — type to filter a list, arrow keys to pick, Enter to select.
//!
//! The filter is a case-insensitive *substring* match (not fuzzy): typing "ta"
//! keeps "TypeScript" but not "Rust". Returns the index into the ORIGINAL
//! `choices` array, regardless of how the list was filtered. Best when the list
//! is long enough that plain `select` scrolling is awkward.

const std = @import("std");
const Prompts = @import("prompts");
const common = @import("common.zig");

// Prompts hide the cursor and drive raw mode, so a panic must restore the terminal.
pub const panic = Prompts.panic;

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    const languages = [_][]const u8{
        "Zig",    "Rust",       "Go",         "C",       "C++",
        "Python", "JavaScript", "TypeScript", "Haskell", "OCaml",
    };

    const idx = p.search(.{
        .message = "Search languages (type to filter):",
        .choices = &languages,
        .unicode = true, // set false for an ASCII cursor glyph
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };

    try t.w().print("\nYou chose: {s}\n", .{languages[idx]});
}
