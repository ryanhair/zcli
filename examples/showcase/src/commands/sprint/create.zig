const std = @import("std");
const zcli = @import("zcli");
const store = @import("store");
const zinput = zcli.zinput;

pub const meta = .{
    .description = "Create a new sprint",
    .examples = &.{ "sprint create", "sprint create \"Sprint 1\"" },
    .args = .{ .name = "Sprint name (omit for interactive)" },
};

pub const Args = struct {
    name: ?[]const u8 = null,
};
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: anytype) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator);
    defer parsed.deinit();
    var data = parsed.value;

    const name = if (args.name) |n| n else blk: {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const writer = &stdout_writer.interface;
        var stdin_reader = std.fs.File.stdin().reader(&.{});
        const reader = &stdin_reader.interface;
        break :blk try zinput.text(writer, reader, allocator, .{
            .message = "Sprint name:",
            .default = try std.fmt.allocPrint(allocator, "Sprint {d}", .{data.sprints.len + 1}),
        });
    };

    var sprints = std.ArrayList([]const u8){};
    defer sprints.deinit(allocator);
    try sprints.appendSlice(allocator, data.sprints);
    try sprints.append(allocator, name);
    data.sprints = sprints.items;
    try store.save(allocator, data);

    try context.stdout().print("\x1b[32m✔\x1b[0m Created sprint: {s}\n", .{name});
}
