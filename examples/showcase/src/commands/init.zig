const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const zinput = zcli.zinput;
const ztheme = zcli.ztheme;

pub const meta = .{
    .description = "Initialize a new task tracker project",
    .examples = &.{"init"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
        const writer = context.stdout();
        const reader = context.stdin();

    // Check if already initialized
    if (std.Io.Dir.cwd().access(context.io.io, "tasks.json", .{})) |_| {
        try writer.writeAll("\r\n  Project already initialized in this directory.\r\n  Run 'tasks list' to see your tasks.\r\n\r\n");
        return;
    } else |_| {}

    try writer.writeAll("\r\n  ");
    try ztheme.theme("Project Setup").bold().render(writer, &context.theme);
    try writer.writeAll("\r\n\r\n");

    const name = (try zinput.text(writer, reader, allocator, .{
        .message = "Project name:",
        .default = "my-project",
    })).value;
    defer allocator.free(name);

    const description = (try zinput.text(writer, reader, allocator, .{
        .message = "Description:",
    })).value;
    defer allocator.free(description);

    const method_idx = (try zinput.select(writer, reader, .{
        .message = "Methodology:",
        .choices = &.{ "Kanban", "Scrum", "None" },
    })).value;
    _ = method_idx;

    const create_samples = (try zinput.confirm(writer, reader, .{
        .message = "Create sample tasks?",
        .default = true,
    })).value;

    var data = store.ProjectData{
        .name = name,
        .description = description,
    };

    if (create_samples) {
        data.tasks = @constCast(&[_]store.Task{
            .{ .id = 1, .title = "Set up development environment", .priority = .high },
            .{ .id = 2, .title = "Write project documentation", .priority = .medium },
            .{ .id = 3, .title = "Add unit tests", .status = .todo, .points = 3 },
        });
        data.next_id = 4;
    }

    try store.save(allocator, context.io.io, data);

    try writer.writeAll("\r\n  ");
    try ztheme.theme("✔ Project initialized!").success().render(writer, &context.theme);
    try writer.writeAll("\r\n\r\n");
}
