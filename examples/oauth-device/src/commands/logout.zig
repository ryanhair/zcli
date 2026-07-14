const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Forget the stored GitHub token",
    .examples = &.{"logout"},
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *Context) !void {
    // `delete` is a no-op (success) if nothing is stored, so `logout` is always
    // safe to run.
    try context.plugins.zcli_secrets.delete("token");
    try context.stdout().print("Removed your stored GitHub token.\n", .{});
}
