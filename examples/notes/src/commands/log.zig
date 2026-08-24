const std = @import("std");
const zcli = @import("zcli");
const log = @import("log");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Show the activity log, oldest entry first",
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *Context) !void {
    // A shared lock: any number of `notes log` runs read at once, and none of
    // them sees a half-written record (see src/log.zig).
    const entries = try log.read(std.Io.Dir.cwd(), context.io, context.allocator);
    if (entries.len == 0) {
        try context.stdout().writeAll("Nothing logged yet.\n");
        return;
    }
    for (entries) |entry| {
        try context.stdout().print("{s} {s}\n", .{ entry.action, entry.title });
    }
}
