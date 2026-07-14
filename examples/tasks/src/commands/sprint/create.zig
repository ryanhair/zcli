const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const themed = zcli.theme.styled;

pub const meta = .{
    .description = "Create a new sprint",
    .examples = &.{ "sprint create", "sprint create \"Sprint 1\"" },
    .args = .{ .name = "Sprint name (omit for interactive)" },
};

pub const Args = struct {
    name: ?[]const u8 = null,
};
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator, context.io);
    defer parsed.deinit();
    var data = parsed.value;

    const name = if (args.name) |n| n else blk: {
        const p = context.prompts();
        break :blk p.text(.{
            .message = "Sprint name:",
            .default = try std.fmt.allocPrint(allocator, "Sprint {d}", .{data.sprints.len + 1}),
        }) catch |err| switch (err) {
            error.EndOfStream => return context.fail("sprint create requires an interactive terminal (stdin closed).", .{}),
            else => return err,
        };
    };

    var sprints = std.ArrayList([]const u8).empty;
    defer sprints.deinit(allocator);
    try sprints.appendSlice(allocator, data.sprints);
    try sprints.append(allocator, name);
    data.sprints = sprints.items;
    try store.save(allocator, context.io, data);

    try themed("✔").success().render(context.stdout(), &context.theme);
    try context.stdout().print(" Created sprint: {s}\n", .{name});
}
