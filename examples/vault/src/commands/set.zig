const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");

pub const meta = .{
    .description = "Store a secret under a name (value is read from a hidden prompt)",
    .examples = &.{"set github-token"},
    .args = .{ .name = "Name to store the secret under" },
};

pub const Args = struct { name: []const u8 };
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
    var loaded = try store.load(allocator, context.io);
    defer loaded.deinit();

    const p = context.prompts();

    if (store.contains(loaded.value.names, args.name)) {
        const msg = try std.fmt.allocPrint(allocator, "'{s}' already exists. Overwrite?", .{args.name});
        const overwrite = p.confirm(.{ .message = msg, .default = false }) catch |err| switch (err) {
            error.EndOfStream => return context.fail("set requires an interactive terminal (stdin closed).", .{}),
            else => return err,
        };
        if (!overwrite) {
            try context.stdout().writeAll("Cancelled.\n");
            return;
        }
    }

    // Masked input: the value never echoes to the terminal or lands in shell
    // history the way an `--value` flag would.
    const value = p.password(.{
        .message = "Secret value:",
    }) catch |err| switch (err) {
        error.EndOfStream => return context.fail("set requires an interactive terminal (stdin closed).", .{}),
        else => return err,
    };
    defer allocator.free(value);

    if (value.len == 0) {
        return context.fail("secret value cannot be empty.", .{});
    }

    // The keychain/Secret Service backend stores only the opaque bytes; the
    // name index (JSON, plaintext) tracks nothing sensitive — just which names
    // exist, so `list`/`get`/`remove` have something to enumerate and complete.
    try context.plugins.zcli_secrets.set(args.name, value);

    const updated_names = try store.withAdded(allocator, loaded.value.names, args.name);
    try store.save(allocator, context.io, .{ .names = updated_names });

    try context.stdout().print("Saved secret '{s}'.\n", .{args.name});
}
