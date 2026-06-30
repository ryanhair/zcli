const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Say hello to someone",
    .examples = &.{
        "hello World",
        "hello Alice --loud",
    },
};

pub const Args = struct {
    name: []const u8,
};

pub const Options = struct {
    loud: bool = false,
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    const greeting = if (options.loud) "HELLO" else "Hello";
    try context.stdout().print("{s}, {s}!\n", .{ greeting, args.name });
}
