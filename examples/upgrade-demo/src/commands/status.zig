const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Print the running version",
    .examples = &.{"status"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *Context) !void {
    try context.stdout().print("{s} {s} — run `upgrade-demo upgrade` to self-update\n", .{
        context.app_name,
        context.app_version,
    });
}
