const std = @import("std");
const zcli = @import("zcli");
const store = @import("store");
const zinput = zcli.zinput;
const ztheme = zcli.ztheme;

pub const meta = .{
    .description = "Remove a task",
    .examples = &.{ "remove 1", "rm 3" },
    .args = .{ .id = "Task ID" },
    .aliases = &.{"rm"},
};

pub const Args = struct { id: u32 };
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: anytype) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator);
    defer parsed.deinit();
    var data = parsed.value;

    const task = store.findById(data.tasks, args.id) orelse {
        try context.stderr().print("Error: Task #{d} not found\n", .{args.id});
        return;
    };

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const writer = &stdout_writer.interface;
    var stdin_reader = std.fs.File.stdin().reader(&.{});
    const reader = &stdin_reader.interface;

    const msg = try std.fmt.allocPrint(allocator, "Remove task #{d}: {s}?", .{ task.id, task.title });
    defer allocator.free(msg);

    const confirmed = zinput.confirm(writer, reader, .{
        .message = msg,
        .default = false,
    }) catch true; // Default to yes on non-interactive

    if (!confirmed) {
        try context.stdout().writeAll("Cancelled.\n");
        return;
    }

    // Filter out the task
    var remaining = std.ArrayList(store.Task){};
    defer remaining.deinit(allocator);
    for (data.tasks) |t| {
        if (t.id != args.id) try remaining.append(allocator, t);
    }
    data.tasks = remaining.items;
    try store.save(allocator, data);

    try ztheme.theme("✖").err().render(context.stdout(), &context.theme);
    try context.stdout().print(" Removed task #{d}\n", .{args.id});
}
