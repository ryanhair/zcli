const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Show stats for a public GitHub repository",
    .examples = &.{
        "repo ziglang/zig",
        "repo ryanhair/zcli",
    },
    .args = .{
        .slug = "Repository as owner/name (e.g. ziglang/zig)",
    },
};

pub const Args = struct {
    slug: []const u8,
};

pub const Options = struct {};

/// Only the fields we render. `Response.json` ignores unknown fields, so this
/// struct can model just the slice of GitHub's payload we care about.
const Repo = struct {
    full_name: []const u8,
    description: ?[]const u8 = null,
    stargazers_count: u64 = 0,
    language: ?[]const u8 = null,
    html_url: []const u8,
};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    // The arena-per-command allocator: everything here is freed at once when the
    // command returns, so nothing below needs an explicit `free`/`deinit` for
    // memory (network handles still get `deinit`).
    const arena = context.allocator;
    const io = context.io;
    const stderr = context.stderr();

    const url = try std.fmt.allocPrint(arena, "https://api.github.com/repos/{s}", .{args.slug});

    // Safe defaults come for free: TLS verification on, a 30s timeout, and a
    // bounded response body. `arena` owns the response body.
    var client = zcli.http.Client.init(arena, io, .{});
    defer client.deinit();

    var response = client.request(.GET, url, .{
        .headers = &.{
            .{ .name = "User-Agent", .value = "zcli-repostat" }, // GitHub requires one
            .{ .name = "Accept", .value = "application/vnd.github+json" },
        },
    }) catch |err| {
        try stderr.print("Error: request to GitHub failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer response.deinit();

    if (response.status != .ok) {
        try stderr.print(
            "Error: GitHub returned {d} for '{s}' (is the repo public and spelled owner/name?)\n",
            .{ @intFromEnum(response.status), args.slug },
        );
        return error.RequestFailed;
    }

    const parsed = response.json(Repo, arena) catch {
        try stderr.print("Error: could not parse GitHub's response\n", .{});
        return error.BadResponse;
    };
    const repo = parsed.value;

    const stdout = context.stdout();
    try stdout.print("{s}\n", .{repo.full_name});
    if (repo.description) |d| try stdout.print("  {s}\n", .{d});
    try stdout.print("  \u{2605} {d} stars", .{repo.stargazers_count});
    if (repo.language) |l| try stdout.print("  \u{00b7}  {s}", .{l});
    try stdout.print("\n  {s}\n", .{repo.html_url});
}
