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
        // A missing note is a plain user error: report it and exit non-zero,
        // rather than returning an error (which would print a Zig stack trace).
        try context.stderr().print("No note titled '{s}'\n", .{args.title});
        context.exit(1);
    }
}
