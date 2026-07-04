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
        // Returning an error is the normal way to fail a command: zcli exits
        // non-zero and reports it. The stack trace is Debug-only — a release
        // build just prints `error: NoteNotFound`. (Want a custom message and
        // exit code instead? Print it, then call context.exit(code).)
        return error.NoteNotFound;
    }
}
