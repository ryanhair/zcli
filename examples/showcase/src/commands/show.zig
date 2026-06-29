const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const ztheme = zcli.ztheme;

pub const meta = .{
    .description = "Show task details",
    .examples = &.{"show 1"},
    .args = .{ .id = "Task ID" },
};

pub const Args = struct { id: u32 };
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator, context.io.io);
    defer parsed.deinit();

    const task = store.findById(parsed.value.tasks, args.id) orelse {
        try context.stderr().print("Error: Task #{d} not found\n", .{args.id});
        return;
    };

    const w = context.stdout();
    const theme = &context.theme;
    var head_buf: [32]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "Task #{d}", .{task.id});
    try w.writeAll("\n  ");
    try ztheme.theme(head).bold().render(w, theme);
    try w.writeAll("\n\n");
    try w.print("  Title:    {s}\n", .{task.title});
    try w.writeAll("  Status:   ");
    try task.status.themed(task.status.label()).render(w, theme);
    try w.writeAll("\n  Priority: ");
    try task.priority.themed(task.priority.label()).render(w, theme);
    try w.writeAll("\n");
    if (task.points) |pts| {
        try w.print("  Points:   {d}\n", .{pts});
    }
    if (task.description.len > 0) {
        try w.print("  \n  {s}\n", .{task.description});
    }
    try w.writeAll("\n");
}
