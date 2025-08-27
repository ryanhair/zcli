const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Manage images",
    .examples = &.{
        "image ls",
        "image build .",
        "image pull ubuntu:latest",
        "image push my-registry.com/my-app:latest",
    },
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    _ = args;
    _ = options;

    try context.stdout().print("Image management commands:\n\n", .{});
    try context.stdout().print("  build     Build an image from a Dockerfile\n", .{});
    try context.stdout().print("  ls        List images\n", .{});
    try context.stdout().print("  pull      Pull an image from a registry\n", .{});
    try context.stdout().print("  push      Push an image to a registry\n", .{});
    try context.stdout().print("  rm        Remove one or more images\n", .{});
    try context.stdout().print("  tag       Tag an image\n", .{});
    try context.stdout().print("  inspect   Display detailed information on images\n", .{});
    try context.stdout().print("  history   Show the history of an image\n", .{});
    try context.stdout().print("  save      Save images to a tar archive\n", .{});
    try context.stdout().print("  load      Load images from a tar archive\n", .{});
    try context.stdout().print("\nRun 'dockr image COMMAND --help' for more information on a command.\n", .{});
}
