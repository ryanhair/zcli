const std = @import("std");
const zcli = @import("zcli");
const zinput = zcli.zinput;

pub const meta = .{
    .description = "Configure task tracker settings",
    .examples = &.{"config"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: anytype) !void {
    const allocator = context.allocator;
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const writer = &stdout_writer.interface;
    var stdin_reader = std.fs.File.stdin().reader(&.{});
    const reader = &stdin_reader.interface;

    try writer.writeAll("\r\n  \x1b[1mSettings\x1b[0m\r\n\r\n");

    const priority_idx = try zinput.select(writer, reader, .{
        .message = "Default priority:",
        .choices = &.{ "low", "medium", "high", "critical" },
    });
    _ = priority_idx;

    const points = try zinput.number(writer, reader, .{
        .message = "Default story points:",
        .default = 1,
        .min = 0,
        .max = 100,
    });
    _ = points;

    const wants_api = try zinput.confirm(writer, reader, .{
        .message = "Configure API integration?",
        .default = false,
    });

    if (wants_api) {
        const token = try zinput.password(writer, reader, allocator, .{
            .message = "API token:",
        });
        defer allocator.free(token);
        try writer.writeAll("  \x1b[32m✔\x1b[0m Token saved\r\n");
    }

    try writer.writeAll("\r\n  \x1b[32m✔ Settings updated\x1b[0m\r\n\r\n");
}
