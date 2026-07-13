const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const themed = zcli.theme.styled;

pub const meta = .{
    .description = "List all tasks",
    .examples = &.{ "list", "list --status todo", "ls" },
    .options = .{
        .status = .{ .short = 's', .description = "Filter by status: todo, in_progress, done" },
        .all = .{ .short = 'a', .description = "Show all tasks including done" },
    },
    .aliases = &.{"ls"},
};

pub const Args = struct {};

pub const Options = struct {
    status: ?[]const u8 = null,
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

    const status_filter: ?store.Status = if (options.status) |s| store.statusFromString(s) else null;

    const w = context.stdout();
    const theme = &context.theme;

    try w.writeAll("\n  ");
    try themed(data.name).bold().render(w, theme);
    try w.writeAll("\n\n  ");
    try themed("ID   Status        Priority  Title").dim().render(w, theme);
    try w.writeAll("\n  ");
    try themed("───  ────────────  ────────  ─────────────────────────").dim().render(w, theme);
    try w.writeAll("\n");

    var shown: usize = 0;
    for (data.tasks) |task| {
        if (status_filter) |filter| {
            if (task.status != filter) continue;
        } else if (!options.all and task.status == .done) {
            continue;
        }

        // Pad each cell to a fixed width, then apply the semantic color.
        var id_buf: [16]u8 = undefined;
        var status_buf: [16]u8 = undefined;
        var pri_buf: [16]u8 = undefined;
        const id_cell = try std.fmt.bufPrint(&id_buf, "{d:<3}", .{task.id});
        const status_cell = try std.fmt.bufPrint(&status_buf, "{s:<12}", .{task.status.label()});
        const pri_cell = try std.fmt.bufPrint(&pri_buf, "{s:<8}", .{task.priority.label()});

        try w.writeAll("  ");
        try task.status.themed(id_cell).render(w, theme);
        try w.writeAll("  ");
        try task.status.themed(status_cell).render(w, theme);
        try w.writeAll("  ");
        try task.priority.themed(pri_cell).render(w, theme);
        try w.print("  {s}\n", .{task.title});
        shown += 1;
    }

    if (shown == 0) {
        try w.writeAll("  ");
        try themed("No matching tasks.").dim().render(w, theme);
        try w.writeAll("\n");
    }
    try w.writeAll("\n");
}
