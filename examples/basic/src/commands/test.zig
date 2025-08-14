const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Test command to verify dynamic discovery",
    .usage = "example-cli test",
    .examples = &.{
        "example-cli test",
    },
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    _ = args;
    _ = options;

    try context.stdout().print("This is a dynamically discovered test command!\n", .{});
}
