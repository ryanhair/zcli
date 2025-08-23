const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Manage containers",
    .usage = "container COMMAND",
    .examples = &.{
        "container ls",
        "container run ubuntu",
        "container stop my-container",
        "container rm old-container",
    },
    .subcommands = .{
        .ls = "List containers",
        .run = "Run a command in a new container",
        .stop = "Stop one or more running containers",
        .start = "Start one or more stopped containers",
        .restart = "Restart one or more containers",
        .rm = "Remove one or more containers",
        .exec = "Run a command in a running container",
        .logs = "Fetch the logs of a container",
        .inspect = "Display detailed information on one or more containers",
    },
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    _ = args;
    _ = options;

    try context.stdout().print("Container management commands:\n\n", .{});
    try context.stdout().print("  ls        List containers\n", .{});
    try context.stdout().print("  run       Run a command in a new container\n", .{});
    try context.stdout().print("  stop      Stop one or more running containers\n", .{});
    try context.stdout().print("  start     Start one or more stopped containers\n", .{});
    try context.stdout().print("  restart   Restart one or more containers\n", .{});
    try context.stdout().print("  rm        Remove one or more containers\n", .{});
    try context.stdout().print("  exec      Run a command in a running container\n", .{});
    try context.stdout().print("  logs      Fetch the logs of a container\n", .{});
    try context.stdout().print("  inspect   Display detailed information on containers\n", .{});
    try context.stdout().print("\nRun 'dockr container COMMAND --help' for more information on a command.\n", .{});
}
