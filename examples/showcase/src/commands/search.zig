const std = @import("std");
const zcli = @import("zcli");
const store = @import("store");
const zinput = zcli.zinput;

pub const meta = .{
    .description = "Search tasks by title",
    .examples = &.{"search"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: anytype) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator);
    defer parsed.deinit();
    const data = parsed.value;

    if (data.tasks.len == 0) {
        try context.stdout().writeAll("No tasks to search.\n");
        return;
    }

    // Build choices from task titles
    var titles = std.ArrayList([]const u8){};
    defer titles.deinit(allocator);
    for (data.tasks) |task| {
        const label = try std.fmt.allocPrint(allocator, "#{d} {s}", .{ task.id, task.title });
        try titles.append(allocator, label);
    }
    defer for (titles.items) |t| allocator.free(t);

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const writer = &stdout_writer.interface;
    var stdin_reader = std.fs.File.stdin().reader(&.{});
    const reader = &stdin_reader.interface;

    const idx = try zinput.search(writer, reader, allocator, .{
        .message = "Search tasks:",
        .choices = titles.items,
    });

    const task = data.tasks[idx];
    const w = context.stdout();
    try w.print("\n  \x1b[1mTask #{d}\x1b[0m — {s}\n", .{ task.id, task.title });
    try w.print("  Status: {s}{s}\x1b[0m  Priority: {s}\n\n", .{ task.status.color(), task.status.label(), task.priority.badge() });
}
