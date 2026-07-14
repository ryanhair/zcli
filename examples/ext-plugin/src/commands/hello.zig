const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Print a greeting",
    .examples = &.{
        "hello",
        "hello Ada",
        "--greet hello Ada", // the external plugin's global flag
    },
    .args = .{ .name = "Who to greet (default: world)" },
};

pub const Args = struct {
    name: ?[]const u8 = null,
};

pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    try context.stdout().print("Hello, {s}!\n", .{args.name orelse "world"});
    try context.stdout().flush();
}
