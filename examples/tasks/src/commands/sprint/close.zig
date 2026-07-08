const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const themed = zcli.theme.styled;

pub const meta = .{
    .description = "Close a sprint",
    .examples = &.{"sprint close"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator, context.io);
    defer parsed.deinit();
    var data = parsed.value;

    if (data.sprints.len == 0) {
        try context.stdout().writeAll("No sprints to close.\n");
        return;
    }

    const p = context.prompts();

    const idx = try p.select(.{
        .message = "Close which sprint?",
        .choices = data.sprints,
    });

    const name = data.sprints[idx];

    var remaining = std.ArrayList([]const u8).empty;
    defer remaining.deinit(allocator);
    for (data.sprints, 0..) |s, i| {
        if (i != idx) try remaining.append(allocator, s);
    }
    data.sprints = remaining.items;
    try store.save(allocator, context.io, data);

    try themed("✔").success().render(context.stdout(), &context.theme);
    try context.stdout().print(" Closed sprint: {s}\n", .{name});
}
