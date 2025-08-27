const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Show the working tree status",
    .examples = &.{
        "status",
        "status --short",
        "status --porcelain",
    },
    .options = .{
        .short = .{ .desc = "Give the output in the short-format", .short = 's' },
        .porcelain = .{ .desc = "Give the output in an easy-to-parse format" },
    },
};

pub const Args = struct {};

pub const Options = struct {
    short: bool = false,
    porcelain: bool = false,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    _ = args;

    if (options.porcelain or options.short) {
        try context.stdout().print("M  main.zig\n", .{});
        try context.stdout().print("A  new-file.zig\n", .{});
        try context.stdout().print("?? untracked.txt\n", .{});
    } else {
        try context.stdout().print("On branch main\n", .{});
        try context.stdout().print("Changes to be committed:\n", .{});
        try context.stdout().print("  (use \"git reset HEAD <file>...\" to unstage)\n\n", .{});
        try context.stdout().print("\tnew file:   new-file.zig\n\n", .{});

        try context.stdout().print("Changes not staged for commit:\n", .{});
        try context.stdout().print("  (use \"git add <file>...\" to update what will be committed)\n", .{});
        try context.stdout().print("  (use \"git checkout -- <file>...\" to discard changes)\n\n", .{});
        try context.stdout().print("\tmodified:   main.zig\n\n", .{});

        try context.stdout().print("Untracked files:\n", .{});
        try context.stdout().print("  (use \"git add <file>...\" to include in what will be committed)\n\n", .{});
        try context.stdout().print("\tuntracked.txt\n\n", .{});
    }
}
