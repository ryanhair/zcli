const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const prompts = zcli.prompts;
const themed = zcli.theme.styled;

pub const meta = .{
    .description = "Configure task tracker defaults",
    .examples = &.{"config"},
};

pub const Args = struct {};
pub const Options = struct {};

/// The file the `zcli_config` plugin reads to seed command-option defaults.
const CONFIG_FILE = ".tasks.config.json";

/// Mirrors the `tasks` config schema. `add` and `list` are command-scoped:
/// the zcli_config plugin applies them as defaults for `tasks add` / `tasks list`.
const Config = struct {
    output: []const u8 = "text",
    add: struct {
        priority: []const u8 = "medium",
        points: u32 = 1,
    } = .{},
    list: struct {
        all: bool = false,
    } = .{},
};

const priorities = [_][]const u8{ "low", "medium", "high", "critical" };

pub fn execute(_: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
    const writer = context.stdout();
    const reader = context.stdin();

    // Load the current config so prompts can show existing values as defaults.
    // Keep `parsed` alive until after we write, so its strings stay valid.
    var parsed: ?std.json.Parsed(Config) = null;
    defer if (parsed) |p| p.deinit();
    var current = Config{};
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(context.io, CONFIG_FILE, allocator, .limited(1024 * 1024))) |content| {
        defer allocator.free(content);
        if (std.json.parseFromSlice(Config, allocator, content, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        })) |p| {
            parsed = p;
            current = p.value;
        } else |_| {}
    } else |_| {}

    try writer.writeAll("\r\n  ");
    try themed("Settings").bold().render(writer, &context.theme);
    try writer.writeAll("\r\n\r\n");

    const priority_idx = try prompts.select(writer, reader, .{
        .message = "Default priority for new tasks:",
        .choices = &priorities,
    });

    const points = try prompts.number(writer, reader, .{
        .message = "Default story points:",
        .default = current.add.points,
        .min = 0,
        .max = 100,
    });

    const show_done = try prompts.confirm(writer, reader, .{
        .message = "Show completed tasks in 'list' by default?",
        .default = current.list.all,
    });

    const new_config = Config{
        .output = current.output, // preserve existing global setting
        .add = .{ .priority = priorities[priority_idx], .points = @intCast(points) },
        .list = .{ .all = show_done },
    };

    const file = try cwd.createFile(context.io, CONFIG_FILE, .{});
    defer file.close(context.io);
    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(context.io, &buf);
    try file_writer.interface.print("{f}", .{std.json.fmt(new_config, .{ .whitespace = .indent_2 })});
    try file_writer.interface.flush();

    try writer.writeAll("\r\n  ");
    try themed("✔ Saved to ").success().render(writer, &context.theme);
    try themed(CONFIG_FILE).path().render(writer, &context.theme);
    try writer.writeAll("\r\n  ");
    try themed("These defaults now apply to 'tasks add' and 'tasks list'.").dim().render(writer, &context.theme);
    try writer.writeAll("\r\n\r\n");
}
