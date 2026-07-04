const std = @import("std");
const zcli = @import("zcli");
const store = @import("store");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "List every saved note title",
};

pub const Args = struct {};
pub const Options = struct {};

pub fn execute(_: Args, _: Options, context: *Context) !void {
    const notes = try store.load(context.io, context.allocator);
    if (notes.notes.len == 0) {
        try context.stdout().writeAll("No notes yet.\n");
        return;
    }
    for (notes.notes) |note| {
        try context.stdout().print("{s}\n", .{note.title});
    }
}
