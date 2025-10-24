const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Initialize a new Git repository",
    .examples = &.{
        "init",
        "init my-project",
        "init --bare bare-repo.git",
    },
    .args = .{
        .directory = "Directory to initialize (defaults to current directory)",
    },
    .options = .{
        .bare = .{ .description = "Create a bare repository" },
    },
};

pub const Args = struct {
    directory: ?[]const u8 = null,
};

pub const Options = struct {
    bare: bool = false,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const dir = args.directory orelse ".";
    const repo_type = if (options.bare) "bare repository" else "repository";

    try context.stdout().print("Initialized empty Git {s} in {s}\n", .{ repo_type, dir });

    if (options.bare) {
        try context.stdout().print("Note: This is a bare repository with no working directory\n", .{});
    }
}
