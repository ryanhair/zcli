const std = @import("std");
const zcli = @import("zcli");
const zprogress = zcli.zprogress;

pub const meta = .{
    .description = "Sync tasks with remote server",
    .examples = &.{"sync"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, _: anytype) !void {
    var spinner = zprogress.spinner(.{ .style = .dots });
    spinner.start("Connecting to server...");

    std.Thread.sleep(500 * std.time.ns_per_ms);
    spinner.setText("Uploading changes...");
    std.Thread.sleep(400 * std.time.ns_per_ms);
    spinner.setText("Downloading updates...");
    std.Thread.sleep(600 * std.time.ns_per_ms);

    spinner.succeed("Synced successfully");
}
