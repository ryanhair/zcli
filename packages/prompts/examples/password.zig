//! `Prompts.password` — masked input; typed characters are never echoed.
//!
//! Options: `mask` sets the glyph shown per typed *grapheme* (default `*`;
//! set it to something like `0` or a bullet). The prompt itself does no
//! validation — do that at the call site. This example re-prompts until the
//! input meets a minimum length. The loop is unbounded and still safe on a
//! closed stdin: a prompt on exhausted (EOF) input returns `error.EndOfStream`
//! rather than an empty string, so the loop breaks instead of spinning.

const std = @import("std");
const Prompts = @import("prompts");
const common = @import("common.zig");

// Prompts hide the cursor and drive raw mode, so a panic must restore the terminal.
pub const panic = Prompts.panic;

const min_len = 8;

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    const secret = while (true) {
        const entry = p.password(.{
            .message = "Choose a password:",
            .mask = '*', // try '0' or a bullet for a different look
        }) catch |err| switch (err) {
            // Closed stdin or user abort: stop, don't re-prompt a dead stream.
            error.EndOfStream, error.Interrupted, error.UserAborted => {
                try t.w().print("\n({s})\n", .{@errorName(err)});
                return;
            },
            else => return err,
        };

        if (entry.len >= min_len) break entry;
        init.gpa.free(entry);
        try t.w().print("\n  Too short — need at least {d} characters. Try again.\n", .{min_len});
    };
    defer init.gpa.free(secret);

    // Don't print the secret back — just prove we captured it.
    try t.w().print("\nGot a password of {d} character(s).\n", .{secret.len});
}
