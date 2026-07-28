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

    // The token got here via the `login` device flow — but `whoami` neither knows
    // nor cares how it was minted; it just reads the opaque credential back.
    // `get` hands back a scoped `Secret`: `deinit` wipes the plaintext rather
    // than leaving it legible in the arena's reclaimed pages.
    var token = (try context.plugins.zcli_secrets.get("token")) orelse
        return context.fail("Not logged in. Run `oauth-device login` first.", .{});
    defer token.deinit();

    var client = zcli.http.Client.init(arena, io, .{});
    defer client.deinit();

    // The Authorization header carries the credential; zcli.http drops it if a
    // redirect ever leaves GitHub's origin, so a token can't leak to another host.
    // This header is a second copy of the plaintext that the `Secret` knows
    // nothing about, so scrub it on the way out too.
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token.bytes});
    defer std.crypto.secureZero(u8, auth);
    var response = client.request(.GET, "https://api.github.com/user", .{
        .headers = &.{
            .{ .name = "User-Agent", .value = "zcli-oauth-device" },
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "Authorization", .value = auth },
        },
    }) catch |err| {
        return context.fail("Request to GitHub failed: {s}", .{@errorName(err)});
    };
    defer response.deinit();

    if (response.status == .unauthorized) {
        return context.fail("Your token was rejected (401). Run `oauth-device login` again.", .{});
    }
    if (response.status != .ok) {
        return context.fail("GitHub returned {d}.", .{@intFromEnum(response.status)});
    }

    const user = (try response.json(User, arena)).value;

    const stdout = context.stdout();
    if (user.name) |name| {
        try stdout.print("{s} (@{s})\n", .{ name, user.login });
    } else {
        try stdout.print("@{s}\n", .{user.login});
    }
}
