const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Record changes to the repository",
    .usage = "commit [--message <msg>] [--amend] [--all]",
    .examples = &.{
        "commit --message \"Add new feature\"",
        "commit -m \"Fix bug in parser\"",
        "commit --amend",
        "commit --all --message \"Update all files\"",
    },
    .options = .{
        .message = .{ .desc = "Use the given message as the commit message", .short = 'm' },
        .amend = .{ .desc = "Replace the tip of the current branch" },
        .all = .{ .desc = "Automatically stage modified and deleted files", .short = 'a' },
    },
};

pub const Args = struct {};

pub const Options = struct {
    message: ?[]const u8 = null,
    amend: bool = false,
    all: bool = false,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    _ = args;
    
    if (options.all) {
        try context.stdout().print("Staging all modified and deleted files\n", .{});
    }
    
    const commit_msg = options.message orelse "Default commit message";
    
    if (options.amend) {
        try context.stdout().print("Amending previous commit with message: \"{s}\"\n", .{commit_msg});
    } else {
        try context.stdout().print("Created commit with message: \"{s}\"\n", .{commit_msg});
        try context.stdout().print("Commit hash: a1b2c3d4e5f6\n", .{});
    }
}