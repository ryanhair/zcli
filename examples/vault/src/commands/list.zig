const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");

pub const meta = .{
    .description = "List the names of stored secrets",
    .examples = &.{"list"},
    .options = .{
        .verbose = .{ .description = "Also print how many secrets are stored" },
    },
};

pub const Args = struct {};
pub const Options = struct {
    // Left unset on the CLI, this is filled from `.vault.config.json`'s
    // `"list": { "verbose": true }` — the zcli_config plugin (wired in
    // build.zig) applies command-scoped config as a default, beaten only by an
    // explicit `--verbose`/`--no-verbose` flag or env var.
    verbose: bool = false,
};

pub fn execute(_: Args, options: Options, context: *Context) !void {
    const allocator = context.allocator;
    var loaded = try store.load(allocator, context.io);
    defer loaded.deinit();

    if (loaded.value.names.len == 0) {
        try context.stdout().writeAll("No secrets stored. Run `vault set <name>` to add one.\n");
        return;
    }

    for (loaded.value.names) |name| {
        try context.stdout().print("{s}\n", .{name});
    }

    if (options.verbose) {
        try context.stdout().print("({d} secret{s} stored)\n", .{
            loaded.value.names.len,
            if (loaded.value.names.len == 1) "" else "s",
        });
    }
}
