const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const prompts = zcli.prompts;
const themed = zcli.theme.styled;

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

pub fn execute(args: Args, options: Options, context: *Context) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator, context.io);
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
        const writer = context.stdout();
        const reader = context.stdin();

        title_owned = try prompts.text(writer, reader, allocator, .{
            .message = "Task title:",
        });
        title = title_owned.?;

        const priority_idx = try prompts.select(writer, reader, .{
            .message = "Priority:",
            .choices = &.{ "low", "medium", "high", "critical" },
            .theme = context.theme,
        });
        priority = switch (priority_idx) {
            0 => .low,
            1 => .medium,
            2 => .high,
            3 => .critical,
            else => .medium,
        };

        const pts = try prompts.number(writer, reader, .{
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
    var tasks_list = std.ArrayList(store.Task).empty;
    defer tasks_list.deinit(allocator);
    try tasks_list.appendSlice(allocator, data.tasks);
    try tasks_list.append(allocator, new_task);

    data.tasks = tasks_list.items;
    data.next_id += 1;
    try store.save(allocator, context.io, data);

    try themed("✔").success().render(context.stdout(), &context.theme);
    try context.stdout().print(" Added task #{d}: {s}\n", .{ new_task.id, title });
}
