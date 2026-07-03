const std = @import("std");
const zcli = @import("zcli");
const store = @import("store");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Save a note under a title",
    .examples = &.{
        "add greeting \"Hello, there!\"",
    },
};

pub const Args = struct {
    title: []const u8,
    body: []const u8,
};

pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    const arena = context.allocator;
    var notes = try store.load(context.io, arena);

    // Append the new note. Everything is arena-allocated, so there is nothing
    // to free — the whole arena is reclaimed when the command returns.
    const grown = try arena.alloc(store.Note, notes.notes.len + 1);
    @memcpy(grown[0..notes.notes.len], notes.notes);
    grown[notes.notes.len] = .{ .title = args.title, .body = args.body };
    notes.notes = grown;

    try store.save(context.io, notes);
    try context.stdout().print("Saved note '{s}'\n", .{args.title});
}
