const std = @import("std");
const zcli = @import("zcli");
const store = @import("store");
const zinput = zcli.zinput;

pub const meta = .{
    .description = "Add a new task",
    .examples = &.{
        "add \"Fix login bug\"",
        "add \"Deploy v2\" --priority high --points 5",
        "add",
    },
    .args = .{ .title = "Task title (omit for interactive mode)" },
    .options = .{
        .priority = .{ .short = 'p', .description = "Priority: low, medium, high, critical" },
        .points = .{ .description = "Story points" },
    },
};

pub const Args = struct {
    title: ?[]const u8 = null,
};

pub const Options = struct {
    priority: []const u8 = "medium",
    points: ?u32 = null,
};

pub fn execute(args: Args, options: Options, context: anytype) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator);
    defer parsed.deinit();
    var data = parsed.value;

    var title: []const u8 = undefined;
    var title_owned: ?[]u8 = null;
    defer if (title_owned) |t| allocator.free(t);
    var priority: store.Priority = .medium;
    var points: ?u32 = options.points;

    if (args.title) |t| {
        // Flag mode
        title = t;
        priority = store.priorityFromString(options.priority) orelse .medium;
    } else {
        // Interactive mode
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const writer = &stdout_writer.interface;
        var stdin_reader = std.fs.File.stdin().reader(&.{});
        const reader = &stdin_reader.interface;

        title_owned = try zinput.text(writer, reader, allocator, .{
            .message = "Task title:",
        });
        title = title_owned.?;

        const priority_idx = try zinput.select(writer, reader, .{
            .message = "Priority:",
            .choices = &.{ "low", "medium", "high", "critical" },
        });
        priority = switch (priority_idx) {
            0 => .low,
            1 => .medium,
            2 => .high,
            3 => .critical,
            else => .medium,
        };

        const pts = try zinput.number(writer, reader, .{
            .message = "Story points:",
            .default = 1,
            .min = 0,
            .max = 100,
        });
        points = @intCast(pts);
    }

    const new_task = store.Task{
        .id = data.next_id,
        .title = title,
        .priority = priority,
        .points = points,
    };

    // Append task
    var tasks_list = std.ArrayList(store.Task){};
    defer tasks_list.deinit(allocator);
    try tasks_list.appendSlice(allocator, data.tasks);
    try tasks_list.append(allocator, new_task);

    data.tasks = tasks_list.items;
    data.next_id += 1;
    try store.save(allocator, data);

    try context.stdout().print("\x1b[32m✔\x1b[0m Added task #{d}: {s}\n", .{ new_task.id, title });
}
