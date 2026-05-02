const std = @import("std");
const store = @import("store");

pub const meta = .{
    .description = "List all tasks",
    .examples = &.{ "list", "list --status todo", "list --output json", "ls" },
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

pub fn execute(_: Args, options: Options, context: anytype) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator);
    defer parsed.deinit();
    const data = parsed.value;

    if (data.tasks.len == 0) {
        try context.stdout().writeAll("No tasks yet. Run 'tasks add' to create one.\n");
        return;
    }

    const status_filter: ?store.Status = if (options.status) |s| store.statusFromString(s) else null;

    try context.stdout().writeAll("\n");
    try context.stdout().print("  \x1b[1m{s}\x1b[0m\n\n", .{data.name});
    try context.stdout().writeAll("  \x1b[2mID   Status        Priority  Title\x1b[0m\n");
    try context.stdout().writeAll("  \x1b[2m───  ────────────  ────────  ─────────────────────────\x1b[0m\n");

    var shown: usize = 0;
    for (data.tasks) |task| {
        if (status_filter) |filter| {
            if (task.status != filter) continue;
        } else if (!options.all and task.status == .done) {
            continue;
        }

        // Use plain labels with fixed widths, apply color around them
        const pri_color: []const u8 = switch (task.priority) {
            .low => "\x1b[2m",
            .medium => "",
            .high => "\x1b[33m",
            .critical => "\x1b[31m",
        };
        const pri_reset: []const u8 = if (pri_color.len > 0) "\x1b[0m" else "";
        try context.stdout().print("  {s}{d:<3}\x1b[0m  {s}{s:<12}\x1b[0m  {s}{s:<8}{s}  {s}\n", .{
            task.status.color(),
            task.id,
            task.status.color(),
            task.status.label(),
            pri_color,
            task.priority.label(),
            pri_reset,
            task.title,
        });
        shown += 1;
    }

    if (shown == 0) {
        try context.stdout().writeAll("  \x1b[2mNo matching tasks.\x1b[0m\n");
    }
    try context.stdout().writeAll("\n");
}
