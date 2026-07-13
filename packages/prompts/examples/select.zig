//! `Prompts.select` — choose one item from a list with the arrow keys and Enter.
//!
//! Extras shown here:
//!   * `interrupt_keys` — Esc aborts with `error.Interrupted`.
//!   * `.theme`         — every prompt instance carries a `ThemeContext` that
//!                        controls how the selected row (and other tokens) are
//!                        styled. It defaults to the app theme; here we override
//!                        it with a custom accent colour to show the seam. In a
//!                        zcli command you'd instead pass `context.theme`.
//!   * `unicode`        — pick the arrow glyph vs an ASCII `>` (see the comment).

const std = @import("std");
const Prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    // A custom theme: paint the highlighted choice in a bright magenta accent.
    // (The prompts read the `selected` token from whatever theme they're given.)
    const my_theme = Prompts.Theme{
        .palette = .{ .accent = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 0, .b = 200 } } } },
    };
    const styled: Prompts.ThemeContext = .{
        .theme = &my_theme,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    };

    const p: Prompts = .{
        .writer = t.w(),
        .reader = t.r(),
        .allocator = init.gpa,
        .theme = styled, // omit this to use the default app theme
    };

    const fruits = [_][]const u8{ "Apple", "Banana", "Cherry", "Dragonfruit", "Elderberry" };

    const idx = p.select(.{
        .message = "Pick a fruit:",
        .choices = &fruits,
        .unicode = true, // set false for an ASCII cursor on limited terminals
        .interrupt_keys = &.{.escape}, // Esc = go back
    }) catch |err| switch (err) {
        error.Interrupted => {
            try t.w().writeAll("\n(no fruit for you)\n");
            return;
        },
        else => return err,
    };

    try t.w().print("\nYou picked: {s}\n", .{fruits[idx]});
}
