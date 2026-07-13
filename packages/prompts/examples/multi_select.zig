//! `Prompts.multiSelect` — toggle several items with Space, confirm with Enter.
//!
//! `defaults` pre-checks items (a `[]const bool` aligned with `choices`); the
//! returned slice is the selected indices, owned by the caller. `unicode`
//! controls the checkbox/cursor glyphs (default true; false → ASCII `[x]`/`[ ]`).

const std = @import("std");
const Prompts = @import("prompts");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    const toppings = [_][]const u8{ "Cheese", "Pepperoni", "Mushrooms", "Onions", "Pineapple" };

    const picks = p.multiSelect(.{
        .message = "Choose your toppings:",
        .choices = &toppings,
        // Pre-check "Cheese"; the rest start unchecked.
        .defaults = &.{ true, false, false, false, false },
        .unicode = true,
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };
    defer init.gpa.free(picks); // caller owns the returned index slice

    try t.w().writeAll("\nYou selected:\n");
    if (picks.len == 0) try t.w().writeAll("  (nothing)\n");
    for (picks) |i| try t.w().print("  - {s}\n", .{toppings[i]});
}
