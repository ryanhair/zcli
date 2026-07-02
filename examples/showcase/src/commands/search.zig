const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const zinput = zcli.zinput;
const ztheme = zcli.ztheme;

pub const meta = .{
    .description = "Search tasks by title",
    .examples = &.{"search"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator, context.io.io);
    defer parsed.deinit();
    const data = parsed.value;

    if (data.tasks.len == 0) {
        try context.stdout().writeAll("No tasks to search.\n");
        return;
    }

    // Build choices from task titles
    var titles = std.ArrayList([]const u8).empty;
    defer titles.deinit(allocator);
    for (data.tasks) |task| {
        const label = try std.fmt.allocPrint(allocator, "#{d} {s}", .{ task.id, task.title });
        try titles.append(allocator, label);
    }
    defer for (titles.items) |t| allocator.free(t);

    const writer = context.stdout();
    const reader = context.stdin();

    const idx = try zinput.search(writer, reader, allocator, .{
        .message = "Search tasks:",
        .choices = titles.items,
    });

    const task = data.tasks[idx];
    const w = context.stdout();
    const theme = &context.theme;
    var head_buf: [32]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "Task #{d}", .{task.id});
    try w.writeAll("\n  ");
    try ztheme.theme(head).bold().render(w, theme);
    try w.print(" — {s}\n  Status: ", .{task.title});
    try task.status.themed(task.status.label()).render(w, theme);
    try w.writeAll("  Priority: ");
    try task.priority.themed(task.priority.label()).render(w, theme);
    try w.writeAll("\n\n");
}
