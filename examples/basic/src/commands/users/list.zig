const std = @import("std");
const zcli = @import("zcli");

pub const meta = .{
    .description = "List all users",
    .usage = "users list [--format <json|table>] [--limit <n>]",
    .examples = &.{
        "users list",
        "users list --format json",
        "users list --limit 5",
    },
};

pub const Args = struct {};

pub const Options = struct {
    format: enum { json, table } = .table,
    limit: ?u32 = null,
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    _ = args;

    const users = [_]struct { name: []const u8, email: []const u8 }{
        .{ .name = "Alice", .email = "alice@example.com" },
        .{ .name = "Bob", .email = "bob@example.com" },
        .{ .name = "Charlie", .email = "charlie@example.com" },
    };

    const limit = options.limit orelse users.len;
    const actual_limit = @min(limit, users.len);

    switch (options.format) {
        .json => {
            try context.stdout.print("[\n", .{});
            for (users[0..actual_limit], 0..) |user, i| {
                try context.stdout.print("  {{\"name\": \"{s}\", \"email\": \"{s}\"}}", .{ user.name, user.email });
                if (i < actual_limit - 1) try context.stdout.print(",", .{});
                try context.stdout.print("\n", .{});
            }
            try context.stdout.print("]\n", .{});
        },
        .table => {
            try context.stdout.print("Name     | Email\n", .{});
            try context.stdout.print("---------|------------------\n", .{});
            for (users[0..actual_limit]) |user| {
                try context.stdout.print("{s:<8} | {s}\n", .{ user.name, user.email });
            }
        },
    }
}
