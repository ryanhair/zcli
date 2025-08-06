const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Example CLI application built with zcli",
    .usage = "example-cli [GLOBAL OPTIONS] <COMMAND> [ARGS]",
    .examples = &.{
        "example-cli --help",
        "example-cli users list",
        "example-cli hello World",
    },
};

// Root command takes no arguments
pub const Args = struct {};

// Root command takes no options
pub const Options = struct {};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    _ = args;
    _ = options;

    try context.stdout.print("Welcome to the example CLI!\n\n", .{});
    try context.stdout.print("This is a demonstration of the zcli framework.\n", .{});
    try context.stdout.print("Run 'example-cli --help' to see available commands.\n", .{});
}
