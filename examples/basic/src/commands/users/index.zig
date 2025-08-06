const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "User management commands",
    .usage = "users <SUBCOMMAND>",
    .examples = &.{
        "users list",
        "users search john",
        "users create --name Alice --email alice@example.com",
    },
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *zcli.Context) !void {
    try context.stdout.print("User management\n\n", .{});
    try context.stdout.print("Available subcommands:\n", .{});
    try context.stdout.print("  list    List all users\n", .{});
    try context.stdout.print("  search  Search for users\n", .{});
    try context.stdout.print("  more    More user operations\n\n", .{});
    try context.stdout.print("Run 'users <subcommand> --help' for more information.\n", .{});
}
