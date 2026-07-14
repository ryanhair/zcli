//! `Prompts.text` — free-form single-line text input.
//!
//! Demonstrates the interesting knobs beyond the bare message:
//!   * `default`        — returned when the user just presses Enter.
//!   * `preview`        — a live line rendered *above* the input, repainted on
//!                        every keystroke (TTY only). Great for "you typed X,
//!                        this will become Y" feedback.
//!   * `interrupt_keys` — keys the prompt refuses to handle; pressing one aborts
//!                        with `error.Interrupted` so the caller can treat it as
//!                        "go back" / "cancel". Here Esc cancels.

const std = @import("std");
const Prompts = @import("prompts");
const common = @import("common.zig");

// Prompts hide the cursor and drive raw mode, so a panic must restore the terminal.
pub const panic = Prompts.panic;

/// A `preview` is a context pointer plus a render callback. The callback gets a
/// frame arena (do not free what you allocate from it) and the current input,
/// and returns one line of plain text — or null for no preview line.
fn slugify(_: *anyopaque, a: std.mem.Allocator, input: []const u8) anyerror!?[]const u8 {
    if (input.len == 0) return null;
    const slug = try a.alloc(u8, input.len);
    for (input, 0..) |c, i| {
        slug[i] = switch (c) {
            'A'...'Z' => c + 32, // lowercase
            'a'...'z', '0'...'9' => c,
            else => '-',
        };
    }
    return try std.fmt.allocPrint(a, "slug: {s}", .{slug});
}

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    var unused: u8 = 0; // the preview needs a context pointer; we don't use it
    const name = p.text(.{
        .message = "Repository name?",
        .default = "my-project",
        .preview = .{ .context = @ptrCast(&unused), .render = slugify },
        // Esc aborts with error.Interrupted instead of being typed.
        .interrupt_keys = &.{.escape},
    }) catch |err| switch (err) {
        error.Interrupted => {
            try t.w().writeAll("\n(cancelled)\n");
            return;
        },
        else => return err,
    };
    defer init.gpa.free(name);

    try t.w().print("\nCreating {s}...\n", .{name});
}
