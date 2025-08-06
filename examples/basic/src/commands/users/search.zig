const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "Search for users by name",
    .usage = "users search <query> [files...] [--case-sensitive]",
    .examples = &.{
        "users search alice",
        "users search bob --case-sensitive",
        "users search john file1.csv file2.csv",
    },
};

pub const Args = struct {
    query: []const u8,
    files: [][]const u8 = &.{},
};

pub const Options = struct {
    case_sensitive: bool = false,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const users = [_]struct { name: []const u8, email: []const u8 }{
        .{ .name = "Alice", .email = "alice@example.com" },
        .{ .name = "Bob", .email = "bob@example.com" },
        .{ .name = "Charlie", .email = "charlie@example.com" },
        .{ .name = "alice", .email = "alice2@example.com" },
    };

    try context.stdout.print("Searching for: {s}\n", .{args.query});
    if (args.files.len > 0) {
        try context.stdout.print("In files: ", .{});
        for (args.files, 0..) |file, i| {
            if (i > 0) try context.stdout.print(", ", .{});
            try context.stdout.print("{s}", .{file});
        }
        try context.stdout.print("\n", .{});
    }
    try context.stdout.print("Case sensitive: {}\n\n", .{options.case_sensitive});

    var found = false;
    for (users) |user| {
        const matches = if (options.case_sensitive)
            std.mem.indexOf(u8, user.name, args.query) != null
        else
            std.ascii.indexOfIgnoreCase(user.name, args.query) != null;

        if (matches) {
            try context.stdout.print("Found: {s} ({s})\n", .{ user.name, user.email });
            found = true;
        }
    }

    if (!found) {
        try context.stdout.print("No users found matching '{s}'\n", .{args.query});
    }
}
