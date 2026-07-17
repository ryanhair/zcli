const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

// The root command (ADR-0029): this file makes the app itself the command —
// `myapp World` greets World, no subcommand needed. Emitted by
// `zcli init --template single`; a multi-command project has no root index.
// Sibling command files still work alongside it: an exact command name
// always wins over the root's positionals.

pub const meta = .{
    .description = "Say hello to someone",
    .examples = &.{
        "World",
        "Alice --loud",
    },
    // Arg descriptions are plain strings; option descriptions are structs
    // that can also declare a short flag (and .name/.env). These show up in
    // `--help` and the generated docs, so the first command a user reads
    // models the full grammar.
    .args = .{
        .name = "Who to greet",
    },
    .options = .{
        .loud = .{ .description = "Shout the greeting", .short = 'l' },
    },
};

pub const Args = struct {
    // Optional so the bare `myapp` still runs (greeting the world). Make it
    // non-optional (`name: []const u8`) to require a value instead — then
    // bare `myapp` reports a missing argument with usage, rg-style.
    name: ?[]const u8 = null,
};

pub const Options = struct {
    loud: bool = false,
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    const name = args.name orelse "world";
    const greeting = if (options.loud) "HELLO" else "Hello";
    try context.stdout().print("{s}, {s}!\n", .{ greeting, name });
}
