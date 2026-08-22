//! Example: the **HTTP fixture** — `HttpFixture`, a scripted loopback server
//! for testing the code that talks to an HTTP API.
//!
//! The unit tier runs a command's `execute()`; the integration and E2E tiers run
//! the binary. None of them help with the layer in between — the *adapter* that
//! turns an API's JSON into your domain types. `HttpFixture` is that layer's test
//! double: queue the responses the adapter should see, point it at an ephemeral
//! `127.0.0.1` URL, and then assert on the requests it actually sent.
//!
//! It is a real server on a real socket, so this exercises the whole client path
//! — URL building, headers, bodies, status handling — with no network access and
//! nothing to stub out.
//!
//! `zig build examples` runs every `test` below.

const std = @import("std");
const zcli = @import("zcli");
const HttpFixture = @import("zcli-testing").HttpFixture;

// ---------------------------------------------------------------------------
// The code under test: a small adapter over an HTTP API.
// ---------------------------------------------------------------------------

/// The domain type the rest of the CLI works with. It owns its strings, so it
/// outlives the HTTP response they were parsed out of.
const Widget = struct {
    id: u32,
    name: []u8,

    fn deinit(self: *Widget, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

/// Fetch one widget. Exactly the shape of adapter a CLI command would call:
/// it owns the URL layout and the auth header, and it hands back a domain type.
fn fetchWidget(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    token: []const u8,
    id: u32,
) !Widget {
    var client: zcli.http.Client = .init(allocator, io, .{});
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "{s}/widgets/{d}", .{ base_url, id });
    defer allocator.free(url);

    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(authorization);

    var response = try client.request(.GET, url, .{
        .headers = &.{.{ .name = "authorization", .value = authorization }},
    });
    defer response.deinit();

    if (response.status != .ok) return error.WidgetFetchFailed;

    // Parsed strings can point straight into `response.body`, so copy anything
    // the caller keeps before the response (and its body) goes away.
    var parsed = try response.json(struct { id: u32, name: []const u8 }, allocator);
    defer parsed.deinit();
    return .{ .id = parsed.value.id, .name = try allocator.dupe(u8, parsed.value.name) };
}

// ---------------------------------------------------------------------------
// 1. The happy path: script a response, assert on the request that produced it.
// ---------------------------------------------------------------------------

test "fetchWidget sends the token and parses the payload" {
    const allocator = std.testing.allocator;

    // `init` binds an ephemeral loopback port and starts serving immediately.
    // `deinit` stops the serving tasks, closes the socket, and frees every byte
    // the fixture handed out — including the URLs from `url()`.
    var fixture = try HttpFixture.init(allocator, std.testing.io, .{});
    defer fixture.deinit();

    try fixture.respondWith(.{
        .status = .ok,
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = "{\"id\":7,\"name\":\"sprocket\"}",
    });

    var widget = try fetchWidget(allocator, std.testing.io, fixture.baseUrl(), "secret-token", 7);
    defer widget.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 7), widget.id);
    try std.testing.expectEqualStrings("sprocket", widget.name);

    // Now assert on what the adapter actually put on the wire.
    const sent = fixture.requests();
    try std.testing.expectEqual(@as(usize, 1), sent.len);
    try std.testing.expectEqual(std.http.Method.GET, sent[0].method);
    try std.testing.expectEqualStrings("/widgets/7", sent[0].target);
    try std.testing.expectEqualStrings("Bearer secret-token", sent[0].header("authorization").?);
}

// ---------------------------------------------------------------------------
// 2. The failure path: script an error status and check the adapter's mapping.
// ---------------------------------------------------------------------------

test "fetchWidget turns a non-200 into a domain error" {
    const allocator = std.testing.allocator;

    var fixture = try HttpFixture.init(allocator, std.testing.io, .{});
    defer fixture.deinit();

    try fixture.respondWith(.{ .status = .not_found, .body = "{\"error\":\"no such widget\"}" });

    try std.testing.expectError(
        error.WidgetFetchFailed,
        fetchWidget(allocator, std.testing.io, fixture.baseUrl(), "secret-token", 404),
    );
}

// ---------------------------------------------------------------------------
// 3. Several calls in a row: responses are served in the order they were queued.
// ---------------------------------------------------------------------------

test "queued responses are served in order" {
    const allocator = std.testing.allocator;

    var fixture = try HttpFixture.init(allocator, std.testing.io, .{});
    defer fixture.deinit();

    try fixture.respondWith(.{ .body = "{\"id\":1,\"name\":\"first\"}" });
    try fixture.respondWith(.{ .body = "{\"id\":2,\"name\":\"second\"}" });

    for ([_][]const u8{ "first", "second" }, 1..) |name, id| {
        var widget = try fetchWidget(allocator, std.testing.io, fixture.baseUrl(), "t", @intCast(id));
        defer widget.deinit(allocator);
        try std.testing.expectEqualStrings(name, widget.name);
    }

    try std.testing.expectEqual(@as(usize, 2), fixture.requests().len);
}
