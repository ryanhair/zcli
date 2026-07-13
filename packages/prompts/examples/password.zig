//! `Prompts.password` — masked input; typed characters are never echoed.
//!
//! Options: `mask` sets the glyph shown per typed *grapheme* (default `*`;
//! set it to something like `0` or a bullet). The prompt itself does no
//! validation — do that at the call site. This example re-prompts (up to
//! `max_tries`) until the input meets a minimum length. The retry cap matters
//! for the non-TTY fallback: there, exhausted (EOF) input reads back as empty
//! every time, so an unbounded loop would spin — the cap makes it give up
//! cleanly instead.

const std = @import("std");
const Prompts = @import("prompts");
const common = @import("common.zig");

const min_len = 8;
const max_tries = 3;

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    var tries: usize = 0;
    while (tries < max_tries) : (tries += 1) {
        const secret = p.password(.{
            .message = "Choose a password:",
            .mask = '*', // try '0' or a bullet for a different look
        }) catch |err| {
            try t.w().print("\n({s})\n", .{@errorName(err)});
            return;
        };
        defer init.gpa.free(secret);

        if (secret.len < min_len) {
            try t.w().print("\n  Too short — need at least {d} characters. Try again.\n", .{min_len});
            continue;
        }

        // Don't print the secret back — just prove we captured it.
        try t.w().print("\nGot a password of {d} character(s).\n", .{secret.len});
        return;
    }

    try t.w().writeAll("\nGave up after too many attempts.\n");
}
