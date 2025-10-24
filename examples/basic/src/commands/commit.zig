const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Record changes to the repository",
    .examples = &.{
        "commit --message \"Add new feature\"",
        "commit -m \"Fix bug in parser\"",
        "commit --amend",
        "commit --all --message \"Update all files\"",
    },
    .options = .{
        .message = .{ .description = "Use the given message as the commit message", .short = 'm' },
        .amend = .{ .description = "Replace the tip of the current branch" },
        .all = .{ .description = "Automatically stage modified and deleted files", .short = 'a' },
    },
};

pub const Args = zcli.NoArgs;

pub const Options = struct {
    message: ?[]const u8 = null,
    amend: bool = false,
    all: bool = false,
};

pub fn execute(_: Args, options: Options, context: *zcli.Context) !void {
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
