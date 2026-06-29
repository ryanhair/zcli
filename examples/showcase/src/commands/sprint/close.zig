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
    var parsed = try store.load(allocator);
    defer parsed.deinit();
    var data = parsed.value;

    if (data.sprints.len == 0) {
        try context.stdout().writeAll("No sprints to close.\n");
        return;
    }

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const writer = &stdout_writer.interface;
    var stdin_reader = std.fs.File.stdin().reader(&.{});
    const reader = &stdin_reader.interface;

    const idx = try zinput.select(writer, reader, .{
        .message = "Close which sprint?",
        .choices = data.sprints,
    });

    const name = data.sprints[idx];

    var remaining = std.ArrayList([]const u8){};
    defer remaining.deinit(allocator);
    for (data.sprints, 0..) |s, i| {
        if (i != idx) try remaining.append(allocator, s);
    }
    data.sprints = remaining.items;
    try store.save(allocator, data);

    try ztheme.theme("✔").success().render(context.stdout(), &context.theme);
    try context.stdout().print(" Closed sprint: {s}\n", .{name});
}
