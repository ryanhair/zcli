const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Say hello to someone",
    .aliases = &.{"hi"},
    .examples = &.{
        "hello World",
        "hello Alice --loud",
    },
    .options = .{
        .loud = .{ .short = 'l', .description = "Shout the greeting" },
    },
};

pub const Args = struct {
    name: []const u8,
    times: u32 = 1,
    extra: [][]const u8,
};

pub const Options = struct {
    loud: bool = false,
    repeat: ?u32 = null,
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    const greeting = if (options.loud) "HELLO" else "Hello";
    try context.stdout().print("{s}, {s}!\n", .{ greeting, args.name });
}
