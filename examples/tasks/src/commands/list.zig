const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const themed = zcli.theme.styled;

pub const meta = .{
    .description = "List all tasks",
    .examples = &.{ "list", "list --status todo", "ls" },
    .options = .{
        .status = .{ .short = 's', .description = "Filter by status" },
        .all = .{ .short = 'a', .description = "Show all tasks including done" },
    },
    .aliases = &.{"ls"},
};

pub const Args = struct {};

pub const Options = struct {
    status: ?store.Status = null,
    all: bool = false,
};

pub fn execute(_: Args, options: Options, context: *Context) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator, context.io);
    defer parsed.deinit();
    const data = parsed.value;

    if (data.tasks.len == 0) {
        try context.stdout().writeAll("No tasks yet. Run 'tasks add' to create one.\n");
        return;
    }

    const status_filter: ?store.Status = options.status;

    const w = context.stdout();
    const theme = &context.theme;

    try w.writeAll("\n  ");
    try themed(data.name).bold().render(w, theme);
    try w.writeAll("\n\n");

    var rows: std.ArrayList([]const []const u8) = .empty;
    defer rows.deinit(allocator);
    for (data.tasks) |task| {
        if (status_filter) |filter| {
            if (task.status != filter) continue;
        } else if (!options.all and task.status == .done) {
            continue;
        }

        try rows.append(allocator, try allocator.dupe([]const u8, &.{
            try std.fmt.allocPrint(allocator, "{d}", .{task.id}),
            task.status.label(),
            task.priority.label(),
            task.title,
        }));
    }

    if (rows.items.len == 0) {
        try w.writeAll("  ");
        try themed("No matching tasks.").dim().render(w, theme);
        try w.writeAll("\n");
    } else {
        try context.table().print(&.{
            .{ .header = "ID", .min_width = 2 },
            .{ .header = "Status", .min_width = 6 },
            .{ .header = "Priority", .min_width = 8 },
            .{ .header = "Title", .min_width = 8, .shrink_priority = 1 },
        }, rows.items);
    }
    try w.writeAll("\n");
}
