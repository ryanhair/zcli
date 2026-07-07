const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const prompts = zcli.prompts;
const themed = zcli.theme.styled;

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
    if (std.Io.Dir.cwd().access(context.io, "tasks.json", .{})) |_| {
        try writer.writeAll("\r\n  Project already initialized in this directory.\r\n  Run 'tasks list' to see your tasks.\r\n\r\n");
        return;
    } else |_| {}

    try writer.writeAll("\r\n  ");
    try themed("Project Setup").bold().render(writer, &context.theme);
    try writer.writeAll("\r\n\r\n");

    const name = try prompts.text(writer, reader, allocator, .{
        .message = "Project name:",
        .default = "my-project",
    });
    defer allocator.free(name);

    const description = try prompts.text(writer, reader, allocator, .{
        .message = "Description:",
    });
    defer allocator.free(description);

    const method_idx = try prompts.select(writer, reader, .{
        .message = "Methodology:",
        .choices = &.{ "Kanban", "Scrum", "None" },
    });
    _ = method_idx;

    const create_samples = try prompts.confirm(writer, reader, .{
        .message = "Create sample tasks?",
        .default = true,
    });

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

    try store.save(allocator, context.io, data);

    try writer.writeAll("\r\n  ");
    try themed("✔ Project initialized!").success().render(writer, &context.theme);
    try writer.writeAll("\r\n\r\n");
}
