const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");

pub const meta = .{
    .description = "Delete a stored secret",
    .examples = &.{"remove github-token"},
    .args = .{ .name = .{ .description = "Name the secret was stored under", .complete = completeName } },
    .aliases = &.{"rm"},
};

pub const Args = struct { name: []const u8 };
pub const Options = struct {};

fn completeName(req: *zcli.completion.Request) !zcli.completion.Result {
    var loaded = try store.load(req.allocator, req.io);
    defer loaded.deinit();

    var out: std.ArrayList(zcli.completion.Candidate) = .empty;
    for (loaded.value.names) |name| {
        if (!std.mem.startsWith(u8, name, req.partial)) continue;
        try out.append(req.allocator, .{ .value = try req.allocator.dupe(u8, name) });
    }
    return .{ .candidates = try out.toOwnedSlice(req.allocator) };
}

pub fn execute(args: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
    var loaded = try store.load(allocator, context.io);
    defer loaded.deinit();

    if (!store.contains(loaded.value.names, args.name)) {
        return context.fail("no secret stored under '{s}'.", .{args.name});
    }

    const p = context.prompts();
    const msg = try std.fmt.allocPrint(allocator, "Delete secret '{s}'?", .{args.name});
    const confirmed = p.confirm(.{ .message = msg, .default = false }) catch true; // non-interactive: default to yes

    if (!confirmed) {
        try context.stdout().writeAll("Cancelled.\n");
        return;
    }

    try context.plugins.zcli_secrets.delete(args.name);

    const updated_names = try store.withRemoved(allocator, loaded.value.names, args.name);
    try store.save(allocator, context.io, .{ .names = updated_names });

    try context.stdout().print("Deleted secret '{s}'.\n", .{args.name});
}
