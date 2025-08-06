const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "File management commands",
    .usage = "files <SUBCOMMAND>",
    .examples = &.{
        "files upload --files file1.txt file2.txt",
    },
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *zcli.Context) !void {
    try context.stdout.print("File management\n\n", .{});
    try context.stdout.print("Available subcommands:\n", .{});
    try context.stdout.print("  upload  Upload files\n\n", .{});
    try context.stdout.print("Run 'files <subcommand> --help' for more information.\n", .{});
}
