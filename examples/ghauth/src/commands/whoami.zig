const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Show the GitHub user the stored token belongs to",
    .examples = &.{"whoami"},
};

pub const Args = struct {};
pub const Options = struct {};

/// Only the fields we render; `Response.json` ignores the rest.
const User = struct {
    login: []const u8,
    name: ?[]const u8 = null,
};

pub fn execute(_: Args, _: Options, context: *Context) !void {
    const arena = context.allocator;
    const io = context.io;
    const stderr = context.stderr();

    // The stored bytes are owned by the arena, so no free is needed.
    const token = (try context.plugins.zcli_secrets.get(context, "token")) orelse {
        try stderr.print("Not logged in. Run `ghauth login` first.\n", .{});
        return error.NotLoggedIn;
    };

    var client = zcli.http.Client.init(arena, io, .{});
    defer client.deinit();

    // The Authorization header carries the credential; zcli.http drops it if a
    // redirect ever leaves GitHub's origin, so a token can't leak to another host.
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
    var response = client.request(.GET, "https://api.github.com/user", .{
        .headers = &.{
            .{ .name = "User-Agent", .value = "zcli-ghauth" },
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "Authorization", .value = auth },
        },
    }) catch |err| {
        try stderr.print("Error: request to GitHub failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer response.deinit();

    if (response.status == .unauthorized) {
        try stderr.print("Your token was rejected (401). Run `ghauth login` with a valid token.\n", .{});
        return error.Unauthorized;
    }
    if (response.status != .ok) {
        try stderr.print("Error: GitHub returned {d}.\n", .{@intFromEnum(response.status)});
        return error.RequestFailed;
    }

    const parsed = try response.json(User, arena);
    const user = parsed.value;

    const stdout = context.stdout();
    if (user.name) |name| {
        try stdout.print("{s} (@{s})\n", .{ name, user.login });
    } else {
        try stdout.print("@{s}\n", .{user.login});
    }
}
