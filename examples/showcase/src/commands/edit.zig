const std = @import("std");
const zcli = @import("zcli");
const store = @import("store");
const zinput = zcli.zinput;
const ztheme = zcli.ztheme;

pub const meta = .{
    .description = "Edit a task description in your editor",
    .examples = &.{"edit 1"},
    .args = .{ .id = "Task ID" },
};

pub const Args = struct { id: u32 };
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: anytype) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator);
    defer parsed.deinit();
    const data = parsed.value;

    var found = false;
    for (data.tasks) |*task| {
        if (task.id == args.id) {
            found = true;

            var stdout_writer = std.fs.File.stdout().writer(&.{});
            const writer = &stdout_writer.interface;
            var stdin_reader = std.fs.File.stdin().reader(&.{});
            const reader = &stdin_reader.interface;

            const msg = try std.fmt.allocPrint(allocator, "Edit task #{d}:", .{task.id});
            defer allocator.free(msg);
            const content = try zinput.editor(writer, reader, allocator, .{
                .message = msg,
                .default = if (task.description.len > 0) task.description else task.title,
                .extension = ".md",
            });
            defer allocator.free(content);

            task.description = content;
            try store.save(allocator, data);
            try ztheme.theme("✔").success().render(context.stdout(), &context.theme);
            try context.stdout().print(" Updated task #{d}\n", .{task.id});
            return;
        }
    }

    if (!found) {
        try context.stderr().print("Error: Task #{d} not found\n", .{args.id});
    }
}
