const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const progress = zcli.progress;
const themed = zcli.theme.styled;

pub const meta = .{
    .description = "Import tasks from a JSON file",
    .examples = &.{"import tasks-backup.json"},
    .args = .{ .file = "JSON file to import" },
};

pub const Args = struct { file: []const u8 };
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;

    // Read import file
    const content = std.Io.Dir.cwd().readFileAlloc(context.io, args.file, allocator, .limited(1024 * 1024)) catch {
        try context.stderr().print("Error: Could not read file '{s}'\n", .{args.file});
        return;
    };
    defer allocator.free(content);

    const imported = std.json.parseFromSlice(struct { tasks: []store.Task }, allocator, content, .{
        .allocate = .alloc_always,
    }) catch {
        try context.stderr().print("Error: Invalid JSON in '{s}'\n", .{args.file});
        return;
    };
    defer imported.deinit();

    // Load existing data
    var parsed = try store.load(allocator, context.io);
    defer parsed.deinit();
    var data = parsed.value;

    // Import with progress bar
    var bar = try progress.progressBar(context.allocator, context.io, .{
        .total = imported.value.tasks.len,
        .show_eta = true,
        .theme = context.theme,
    });

    var tasks_list = std.ArrayList(store.Task).empty;
    defer tasks_list.deinit(allocator);
    try tasks_list.appendSlice(allocator, data.tasks);

    for (imported.value.tasks, 0..) |task, i| {
        var new_task = task;
        new_task.id = data.next_id;
        data.next_id += 1;
        try tasks_list.append(allocator, new_task);
        bar.update(i + 1, null);
        context.io.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {}; // Simulate processing
    }
    bar.finish();

    data.tasks = tasks_list.items;
    try store.save(allocator, context.io, data);

    try themed("✔").success().render(context.stdout(), &context.theme);
    try context.stdout().print(" Imported {d} tasks from {s}\n", .{ imported.value.tasks.len, args.file });
}
