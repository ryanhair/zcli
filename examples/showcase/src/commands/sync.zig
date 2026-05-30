const std = @import("std");
const zcli = @import("zcli");
const zprogress = zcli.zprogress;

pub const meta = .{
    .description = "Sync tasks with remote server",
    .examples = &.{"sync"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: anytype) !void {
    const io = context.io.io;
    var spinner = zprogress.spinner(io, .{ .style = .dots });
    spinner.start("Connecting to server...");

    io.sleep(.{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch {};
    spinner.setText("Uploading changes...");
    io.sleep(.{ .nanoseconds = 400 * std.time.ns_per_ms }, .awake) catch {};
    spinner.setText("Downloading updates...");
    io.sleep(.{ .nanoseconds = 600 * std.time.ns_per_ms }, .awake) catch {};

    spinner.succeed("Synced successfully");
}
