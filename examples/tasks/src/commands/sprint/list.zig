const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const themed = zcli.theme.styled;

pub const meta = .{
    .description = "List all sprints",
    .examples = &.{"sprint list"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator, context.io);
    defer parsed.deinit();

    if (parsed.value.sprints.len == 0) {
        try context.stdout().writeAll("No sprints yet. Run 'tasks sprint create' to create one.\n");
        return;
    }

    try context.stdout().writeAll("\n  ");
    try themed("Sprints").bold().render(context.stdout(), &context.theme);
    try context.stdout().writeAll("\n\n");
    for (parsed.value.sprints, 1..) |sprint, i| {
        try context.stdout().print("  {d}. {s}\n", .{ i, sprint });
    }
    try context.stdout().writeAll("\n");
}
