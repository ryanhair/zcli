const std = @import("std");
const nightwatch = @import("nightwatch");

pub const std_options: std.Options = .{ .logFn = discardExpectedLog };

fn discardExpectedLog(
    comptime _: std.log.Level,
    comptime _: @EnumLiteral(),
    comptime _: []const u8,
    _: anytype,
) void {}

const handler_vtable = nightwatch.Default.Handler.VTable{
    .change = change,
    .rename = rename,
};

fn change(
    _: *nightwatch.Default.Handler,
    _: []const u8,
    _: nightwatch.EventType,
    _: nightwatch.ObjectType,
) error{HandlerFailed}!void {}

fn rename(
    _: *nightwatch.Default.Handler,
    _: []const u8,
    _: []const u8,
    _: nightwatch.ObjectType,
) error{HandlerFailed}!void {}

/// Regression probe for Nightwatch's Linux raw-syscall errno decoding.
///
/// In a libc-linked Zig 0.16 binary, std.posix.errno follows libc's `rc == -1`
/// convention, while inotify_add_watch returns raw `-errno`. Nightwatch before
/// cac3b9e accepted that negative result and then panicked while storing it as a
/// watch descriptor. The fixed public `watch` seam reports WatchFailed.
pub fn main(init: std.process.Init) !void {
    var handler = nightwatch.Default.Handler{ .vtable = &handler_vtable };
    var watcher = try nightwatch.Default.init(init.io, init.gpa, &handler);
    defer watcher.deinit();

    watcher.watch("/zcli-nightwatch-regression/path-does-not-exist") catch |err| {
        if (err == error.WatchFailed) return;
        return err;
    };
    return error.ExpectedWatchFailed;
}
