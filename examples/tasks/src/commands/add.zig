const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
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
        .priority = .{ .short = 'p', .description = "Priority: low, medium, high, critical", .complete = completePriority },
        .points = .{ .description = "Story points" },
    },
};

/// Dynamic completion for `--priority` (ADR-0026). The field is a plain string,
/// not an enum, so its choices can't be baked in statically — a hook offers them.
fn completePriority(req: *zcli.completion.Request) !zcli.completion.Result {
    const choices = [_][]const u8{ "low", "medium", "high", "critical" };
    var out: std.ArrayList(zcli.completion.Candidate) = .empty;
    for (choices) |ch| {
        if (!std.mem.startsWith(u8, ch, req.partial)) continue;
        try out.append(req.allocator, .{ .value = ch });
    }
    return .{ .candidates = try out.toOwnedSlice(req.allocator) };
}

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
        const p = context.prompts();

        title_owned = try p.text(.{
            .message = "Task title:",
        });
        title = title_owned.?;

        const priority_idx = try p.select(.{
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

        const pts = try p.number(.{
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
