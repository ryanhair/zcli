//! greeting.zig — the greeting text itself, shared by every command.
//!
//! A **shared module** (`zcli.SharedModule`, see `zcli guide sharing`): the
//! command is a thin shell that parses arguments and prints, and the logic
//! worth testing lives here. `addCommandTests` compiles every configured
//! shared module as a test root, so the `test` blocks below run under the
//! same `zig build test` as the command tests — the project wires the module
//! once, in `shared_modules`, and gets both.

const std = @import("std");

/// Render the greeting for `name`. `allocator` is the caller's arena (in a
/// command, `context.allocator`), so the result never needs freeing.
pub fn render(allocator: std.mem.Allocator, name: []const u8, loud: bool) ![]const u8 {
    if (!loud) return std.fmt.allocPrint(allocator, "Hello, {s}!", .{name});
    const shouted = try std.ascii.allocUpperString(allocator, name);
    defer allocator.free(shouted);
    return std.fmt.allocPrint(allocator, "HELLO, {s}!", .{shouted});
}

// ---------------------------------------------------------------------------
// The unit tier's other kind of test root: plain `std.testing` over the helper,
// no CLI in sight (the command file next door is the first kind). These run
// because `build.zig` lists this module in `shared_modules`.
// ---------------------------------------------------------------------------

test "render greets by name" {
    const text = try render(std.testing.allocator, "world", false);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Hello, world!", text);
}

test "render shouts when loud" {
    const text = try render(std.testing.allocator, "world", true);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("HELLO, WORLD!", text);
}
