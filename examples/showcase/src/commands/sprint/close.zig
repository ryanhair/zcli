const std = @import("std");
const zcli = @import("zcli");
const store = @import("store");
const zinput = zcli.zinput;
const ztheme = zcli.ztheme;

pub const meta = .{
    .description = "Close a sprint",
    .examples = &.{"sprint close"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: anytype) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator, context.io.io);
    defer parsed.deinit();
    var data = parsed.value;

    if (data.sprints.len == 0) {
        try context.stdout().writeAll("No sprints to close.\n");
        return;
    }

        const writer = context.stdout();
        const reader = context.stdin();

    const idx = try zinput.select(writer, reader, .{
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
    try store.save(allocator, context.io.io, data);

    try ztheme.theme("✔").success().render(context.stdout(), &context.theme);
    try context.stdout().print(" Closed sprint: {s}\n", .{name});
}
