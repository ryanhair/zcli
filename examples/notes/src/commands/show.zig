const std = @import("std");
const zcli = @import("zcli");
const store = @import("store");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Print the body of a named note",
    .examples = &.{
        "show greeting",
    },
};

pub const Args = struct {
    title: []const u8,
};

pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    const notes = try store.load(context.io, context.allocator);
    if (store.find(notes, args.title)) |note| {
        try context.stdout().print("{s}\n", .{note.body});
    } else {
        // Fail with a message the user should see. context.fail prints it and
        // exits non-zero cleanly — no `error: Name`, no stack trace. (A plain
        // `return error.X` is for unexpected bugs, where the name and Debug
        // trace help you debug.)
        return context.fail("No note titled '{s}'", .{args.title});
    }
}
