const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");

pub const meta = .{
    .description = "Print a stored secret's value",
    .examples = &.{"get github-token"},
    .args = .{ .name = .{ .description = "Name the secret was stored under", .complete = completeName } },
};

pub const Args = struct { name: []const u8 };
pub const Options = struct {};

/// Dynamic completion (ADR-0026): offer the known names from the index, so
/// `vault get <TAB>` lists what's actually stored instead of nothing.
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
    const value = (try context.plugins.zcli_secrets.get(args.name)) orelse {
        return context.fail("no secret stored under '{s}'. Run `vault set {s}` first.", .{ args.name, args.name });
    };
    try context.stdout().print("{s}\n", .{value});
}
