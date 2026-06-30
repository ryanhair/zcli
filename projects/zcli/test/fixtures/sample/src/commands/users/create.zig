const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Create a new user",
    .examples = &.{
        "users create alice",
    },
};

pub const Args = struct {
    username: []const u8,
};

pub const Options = struct {
    admin: bool = false,
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    _ = options;
    try context.stdout().print("Created {s}\n", .{args.username});
}
