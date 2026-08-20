//! Searchable `Prompts.multiSelect` — type to filter, toggle several items
//! with Space, and confirm with Enter.
//!
//! Selections are retained when filtering hides them. `defaults` pre-checks
//! items (a `[]const bool` aligned with `choices`); the returned slice is the
//! selected indices, owned by the caller.

const std = @import("std");
const Prompts = @import("prompts");
const common = @import("common.zig");

// Prompts hide the cursor and drive raw mode, so a panic must restore the terminal.
pub const panic = Prompts.panic;
// Segfaults bypass `panic` entirely (#759), so install the fault hook too.
pub const debug = Prompts.debug;

pub fn main(init: std.process.Init) !void {
    var t: common.Io = .{};
    t.init(init.io);
    defer t.flush();

    const p: Prompts = .{ .writer = t.w(), .reader = t.r(), .allocator = init.gpa };

    const toppings = [_][]const u8{ "Cheese", "Pepperoni", "Mushrooms", "Onions", "Pineapple" };

    const picks = p.multiSelect(.{
        .message = "Choose your toppings (type to filter):",
        .choices = &toppings,
        .defaults = &.{ true, false, false, false, false },
        .search = true,
        .unicode = true,
    }) catch |err| {
        try t.w().print("\n({s})\n", .{@errorName(err)});
        return;
    };
    defer init.gpa.free(picks);

    try t.w().writeAll("\nYou selected:\n");
    if (picks.len == 0) try t.w().writeAll("  (nothing)\n");
    for (picks) |i| try t.w().print("  - {s}\n", .{toppings[i]});
}
