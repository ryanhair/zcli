const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const themed = zcli.theme.theme;

pub const meta = .{
    .description = "Mark a task as complete",
    .examples = &.{"done 1"},
    .args = .{ .id = "Task ID" },
};

pub const Args = struct { id: u32 };
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator, context.io);
    defer parsed.deinit();
    const data = parsed.value;

    for (data.tasks) |*task| {
        if (task.id == args.id) {
            task.status = .done;
            try store.save(allocator, context.io, data);
            try themed("✔").success().render(context.stdout(), &context.theme);
            try context.stdout().print(" Task #{d} marked as done: {s}\n", .{ task.id, task.title });
            return;
        }
    }

    try context.stderr().print("Error: Task #{d} not found\n", .{args.id});
}
