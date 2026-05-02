const std = @import("std");
const store = @import("store");

pub const meta = .{
    .description = "Show task details",
    .examples = &.{"show 1"},
    .args = .{ .id = "Task ID" },
};

pub const Args = struct { id: u32 };
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: anytype) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator);
    defer parsed.deinit();

    const task = store.findById(parsed.value.tasks, args.id) orelse {
        try context.stderr().print("Error: Task #{d} not found\n", .{args.id});
        return;
    };

    const w = context.stdout();
    try w.writeAll("\n");
    try w.print("  \x1b[1mTask #{d}\x1b[0m\n\n", .{task.id});
    try w.print("  Title:    {s}\n", .{task.title});
    try w.print("  Status:   {s}{s}\x1b[0m\n", .{ task.status.color(), task.status.label() });
    try w.print("  Priority: {s}\n", .{task.priority.badge()});
    if (task.points) |pts| {
        try w.print("  Points:   {d}\n", .{pts});
    }
    if (task.description.len > 0) {
        try w.print("  \n  {s}\n", .{task.description});
    }
    try w.writeAll("\n");
}
