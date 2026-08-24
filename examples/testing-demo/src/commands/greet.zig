const std = @import("std");
const zcli = @import("zcli");
const greeting = @import("greeting");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Print a greeting",
    .examples = &.{ "greet world", "greet world --loud" },
    .args = .{ .name = "Who to greet" },
    .options = .{
        .loud = .{ .description = "Shout the greeting" },
    },
};

pub const Args = struct { name: []const u8 };
pub const Options = struct { loud: bool = false };

pub fn execute(args: Args, options: Options, context: *Context) !void {
    // The wording lives in the `greeting` shared module, which carries its own
    // tests — `addCommandTests` runs those alongside the command tests below.
    const text = try greeting.render(context.allocator, args.name, options.loud);
    try context.stdout().print("{s}\n", .{text});
}

// ---------------------------------------------------------------------------
// Unit tier (`zcli-testing`'s `runCommand`): the exact idiom `addCommandTests`
// wires up for every command file — `@This()` is `greet` itself, and
// `runCommand` derives the right `TestContext` from `execute`'s signature.
// ---------------------------------------------------------------------------

test "greet prints a friendly hello" {
    const testing = @import("zcli-testing");

    var result = try testing.runCommand(@This(), .{ .args = .{ .name = "world" } });
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("Hello, world!\n", result.stdout);
}

test "greet --loud shouts" {
    const testing = @import("zcli-testing");

    var result = try testing.runCommand(@This(), .{
        .args = .{ .name = "world" },
        .options = .{ .loud = true },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("HELLO, WORLD!\n", result.stdout);
}
