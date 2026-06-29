const std = @import("std");
const zcli = @import("zcli");
const store = @import("store");
const ztheme = zcli.ztheme;

pub const meta = .{
    .description = "List all sprints",
    .examples = &.{"sprint list"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: anytype) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator);
    defer parsed.deinit();

    if (parsed.value.sprints.len == 0) {
        try context.stdout().writeAll("No sprints yet. Run 'tasks sprint create' to create one.\n");
        return;
    }

    try context.stdout().writeAll("\n  ");
    try ztheme.theme("Sprints").bold().render(context.stdout(), &context.theme);
    try context.stdout().writeAll("\n\n");
    for (parsed.value.sprints, 1..) |sprint, i| {
        try context.stdout().print("  {d}. {s}\n", .{ i, sprint });
    }
    try context.stdout().writeAll("\n");
}
