const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Add file contents to the index",
    .usage = "add [--all] [--patch] <files>...",
    .examples = &.{
        "add file.txt",
        "add *.js",
        "add --all",
        "add --patch main.zig",
    },
    .args = .{
        .files = "Files to add to the index",
    },
    .options = .{
        .all = .{ .desc = "Add all modified and new files" },
        .patch = .{ .desc = "Interactively choose hunks to add" },
    },
};

pub const Args = struct {
    files: []const []const u8,
};

pub const Options = struct {
    all: bool = false,
    patch: bool = false,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    if (options.all) {
        try context.stdout().print("Adding all modified and new files to the index\n", .{});
        return;
    }

    if (args.files.len == 0) {
        try context.stderr().print("Error: No files specified\n", .{});
        try context.stderr().print("Use 'add --all' to add all files or specify files to add\n", .{});
        return;
    }

    for (args.files) |file| {
        if (options.patch) {
            try context.stdout().print("Interactively adding {s} (patch mode)\n", .{file});
        } else {
            try context.stdout().print("Added {s} to the index\n", .{file});
        }
    }
}
