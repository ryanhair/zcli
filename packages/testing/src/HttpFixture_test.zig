//! Real-socket tests for `HttpFixture`, isolated into their own test binary
//! (built ReleaseSafe — see below and build.zig).
//!
//! They drive the fixture over an actual loopback connection with
//! `std.http.Client` — the same client `zcli.http` wraps — so the scripted
//! responses, the request recording and the teardown path are all exercised
//! end to end on every platform CI runs.
//!
//! Two reasons for the separate binary, both inherited from
//! core's `http_loopback_test.zig`:
//!
//!   1. Inline in `main.zig` these socket round-trips would ride along into
//!      every consumer's test build of the std-only testing tier. Here they run
//!      exactly once.
//!   2. On Windows a loopback connect intermittently loses a concurrent dial and
//!      the OS returns STATUS_CONNECTION_REFUSED (NTSTATUS 0xc0000236). Zig
//!      0.16's std has no switch arm mapping that status in
//!      `netConnectIpWindows`, so a perfectly normal connection-refused falls
//!      through to `windows.unexpectedStatus()`, which dumps a stack trace
//!      whenever `std.options.unexpected_error_tracing` is on. That option
//!      defaults to `mode == .Debug`, and a test binary's root is the injected
//!      test runner (so a `std_options` override here would be ignored).
//!      build.zig therefore compiles this one binary ReleaseSafe, which flips
//!      the default off while keeping safety checks.

const std = @import("std");
const testing = std.testing;

const HttpFixture = @import("HttpFixture.zig");

/// A completed response, read fully into memory. Mirrors what a client adapter
/// would hand back, so the tests can assert on status and body without repeating
/// the `std.http.Client` plumbing.
const Fetched = struct {
    status: std.http.Status,
    body: []u8,

    fn deinit(self: *Fetched) void {
        testing.allocator.free(self.body);
        self.* = undefined;
    }
};

const FetchOptions = struct {
    method: std.http.Method = .GET,
    headers: []const std.http.Header = &.{},
    body: ?[]const u8 = null,
};

fn fetch(client: *std.http.Client, url: []const u8, options: FetchOptions) !Fetched {
    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer body.deinit();

    const result = try client.fetch(.{
        .method = options.method,
        .location = .{ .url = url },
        .extra_headers = options.headers,
        .payload = options.body,
        .response_writer = &body.writer,
    });

    return .{ .status = result.status, .body = try body.toOwnedSlice() };
}

test "serves queued responses in order, then reports the queue is exhausted" {
    var fixture = try HttpFixture.init(testing.allocator, testing.io, .{});
    defer fixture.deinit();

    try fixture.respondWith(.{ .status = .ok, .body = "first" });
    try fixture.respondWith(.{ .status = .created, .body = "second" });
    try fixture.respondWith(.{ .status = .accepted, .body = "third" });

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const url = try fixture.url("/queued");

    const expected = [_]struct { status: std.http.Status, body: []const u8 }{
        .{ .status = .ok, .body = "first" },
        .{ .status = .created, .body = "second" },
        .{ .status = .accepted, .body = "third" },
    };
    for (expected) |want| {
        var got = try fetch(&client, url, .{});
        defer got.deinit();
        try testing.expectEqual(want.status, got.status);
        try testing.expectEqualStrings(want.body, got.body);
    }

    // A fourth request has nothing left to serve and must say so rather than
    // hang or replay the last response.
    var exhausted = try fetch(&client, url, .{});
    defer exhausted.deinit();
    try testing.expectEqual(HttpFixture.unscripted_status, exhausted.status);
    try testing.expectEqualStrings(HttpFixture.unscripted_body, exhausted.body);

    try testing.expectEqual(@as(usize, 4), (try fixture.requests()).len);
}

test "a snapshot from requests() survives later requests" {
    var fixture = try HttpFixture.init(testing.allocator, testing.io, .{});
    defer fixture.deinit();

    for (0..8) |_| try fixture.respondWith(.{ .body = "ok" });

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const url = try fixture.url("/snapshot");
    {
        var first = try fetch(&client, url, .{});
        defer first.deinit();
    }

    // Held across seven more requests, each of which appends to the fixture's
    // own recording and will grow (and move) its backing array. The snapshot is
    // the caller's, so it must neither move nor grow.
    const held = try fixture.requests();
    try testing.expectEqual(@as(usize, 1), held.len);

    for (0..7) |_| {
        var later = try fetch(&client, url, .{});
        defer later.deinit();
    }

    try testing.expectEqual(@as(usize, 1), held.len);
    try testing.expectEqualStrings("/snapshot", held[0].target);
    try testing.expectEqual(@as(usize, 8), (try fixture.requests()).len);
}

test "records method, target, headers and body" {
    var fixture = try HttpFixture.init(testing.allocator, testing.io, .{});
    defer fixture.deinit();

    try fixture.respondWith(.{});

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const url = try fixture.url("/widgets?page=2");
    var response = try fetch(&client, url, .{
        .method = .POST,
        .headers = &.{
            .{ .name = "authorization", .value = "Bearer secret-token" },
            .{ .name = "x-zcli-test", .value = "1" },
        },
        .body = "{\"name\":\"widget\"}",
    });
    defer response.deinit();
    try testing.expectEqual(std.http.Status.ok, response.status);

    const sent = try fixture.requests();
    try testing.expectEqual(@as(usize, 1), sent.len);
    try testing.expectEqual(std.http.Method.POST, sent[0].method);
    try testing.expectEqualStrings("/widgets?page=2", sent[0].target);
    try testing.expectEqualStrings("{\"name\":\"widget\"}", sent[0].body);
    try testing.expect(!sent[0].body_truncated);
    try testing.expectEqualStrings("Bearer secret-token", sent[0].header("Authorization").?);
    try testing.expectEqualStrings("1", sent[0].header("x-zcli-test").?);
    try testing.expectEqual(@as(?[]const u8, null), sent[0].header("x-absent"));
}

test "scripted response headers reach the client" {
    var fixture = try HttpFixture.init(testing.allocator, testing.io, .{});
    defer fixture.deinit();

    try fixture.respondWith(.{
        .headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-request-id", .value = "abc123" },
        },
        .body = "{\"id\":7}",
    });

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    // Raw client API rather than `fetch`, which does not surface response
    // headers. Read them before `response.reader()`, which invalidates them.
    var request = try client.request(.GET, try std.Uri.parse(try fixture.url("/json")), .{});
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buffer: [1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    var content_type: ?[]const u8 = null;
    var request_id: ?[]const u8 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) content_type = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "x-request-id")) request_id = h.value;
    }
    try testing.expectEqualStrings("application/json", content_type.?);
    try testing.expectEqualStrings("abc123", request_id.?);

    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    var transfer_buffer: [1024]u8 = undefined;
    _ = try response.reader(&transfer_buffer).streamRemaining(&body.writer);
    try testing.expectEqualStrings("{\"id\":7}", body.written());
}

test "requesting the base URL directly targets /" {
    var fixture = try HttpFixture.init(testing.allocator, testing.io, .{});
    defer fixture.deinit();

    try fixture.respondWith(.{ .body = "root" });

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    var response = try fetch(&client, fixture.baseUrl(), .{});
    defer response.deinit();
    try testing.expectEqualStrings("root", response.body);
    try testing.expectEqualStrings("/", (try fixture.requests())[0].target);
}

test "a request body beyond the recording bound is truncated, not buffered whole" {
    var fixture = try HttpFixture.init(testing.allocator, testing.io, .{
        .max_request_body_bytes = 16,
    });
    defer fixture.deinit();

    try fixture.respondWith(.{ .body = "ok" });

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const payload = "0123456789" ** 100;
    var response = try fetch(&client, try fixture.url("/upload"), .{
        .method = .POST,
        .body = payload,
    });
    defer response.deinit();
    try testing.expectEqualStrings("ok", response.body);

    const sent = try fixture.requests();
    try testing.expect(sent[0].body_truncated);
    try testing.expectEqualStrings(payload[0..16], sent[0].body);
}

test "a request body that exactly fills the recording bound is not flagged truncated" {
    var fixture = try HttpFixture.init(testing.allocator, testing.io, .{
        .max_request_body_bytes = 16,
    });
    defer fixture.deinit();

    try fixture.respondWith(.{ .body = "ok" });

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    const payload = "0123456789abcdef";
    var response = try fetch(&client, try fixture.url("/upload"), .{
        .method = .POST,
        .body = payload,
    });
    defer response.deinit();

    const sent = try fixture.requests();
    try testing.expect(!sent[0].body_truncated);
    try testing.expectEqualStrings(payload, sent[0].body);
}

/// One in-flight request, run as a concurrent task so several can overlap.
fn fetchConcurrently(client: *std.http.Client, url: []const u8, out: *?std.http.Status) void {
    var response = fetch(client, url, .{}) catch return;
    defer response.deinit();
    out.* = response.status;
}

test "overlapping requests are served concurrently" {
    var fixture = try HttpFixture.init(testing.allocator, testing.io, .{ .concurrency = 2 });
    defer fixture.deinit();

    try fixture.respondWith(.{ .status = .ok });
    try fixture.respondWith(.{ .status = .ok });

    // Separate clients so the two requests can't be serialized onto one pooled
    // connection — each dials the fixture itself.
    var client_a: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client_a.deinit();
    var client_b: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client_b.deinit();

    const url = try fixture.url("/parallel");
    var status_a: ?std.http.Status = null;
    var status_b: ?std.http.Status = null;

    var future_a = try testing.io.concurrent(fetchConcurrently, .{ &client_a, url, &status_a });
    var future_b = try testing.io.concurrent(fetchConcurrently, .{ &client_b, url, &status_b });
    future_a.await(testing.io);
    future_b.await(testing.io);

    try testing.expectEqual(std.http.Status.ok, status_a.?);
    try testing.expectEqual(std.http.Status.ok, status_b.?);
    try testing.expectEqual(@as(usize, 2), (try fixture.requests()).len);
}

test "connections that die without sending a request don't drain the serving pool" {
    // Smoke test, deliberately: a dial that hangs up immediately is *not* a
    // reliable way to produce `error.ConnectionAborted`. Whether the kernel
    // completes the handshake before the close decides it, so this usually ends
    // as a successful accept followed by EOF in `receiveHead` — a different code
    // path (`serveConnection` returning) that must also spare the task. Neither
    // outcome is selectable from here, so the accept-error classification that
    // this used to claim to cover is unit-tested directly instead, next to the
    // function, in HttpFixture.zig. What is asserted here is the invariant both
    // paths share, end to end over a real socket: dead connections must not
    // retire serving tasks.
    //
    // `concurrency = 1` is what gives that teeth — with a single task, anything
    // that retires it takes the whole fixture down and the request below hangs
    // rather than merely running slower.
    var fixture = try HttpFixture.init(testing.allocator, testing.io, .{ .concurrency = 1 });
    defer fixture.deinit();

    try fixture.respondWith(.{ .body = "still here" });

    const uri = try std.Uri.parse(fixture.baseUrl());
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", uri.port.?);

    // Dial and hang up without saying a word, repeatedly.
    for (0..16) |_| {
        const stream = try address.connect(testing.io, .{ .mode = .stream });
        stream.close(testing.io);
    }

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();

    var response = try fetch(&client, try fixture.url("/after"), .{});
    defer response.deinit();
    try testing.expectEqualStrings("still here", response.body);
}

test "a fixture that never serves a request tears down cleanly" {
    var fixture = try HttpFixture.init(testing.allocator, testing.io, .{});
    // Queue a response that is deliberately never claimed: deinit must still
    // release it, the listening socket, and every serving task.
    try fixture.respondWith(.{ .body = "unused" });
    _ = try fixture.url("/never-called");
    fixture.deinit();
}

test "a concurrency of zero is rejected rather than silently serving nothing" {
    try testing.expectError(
        error.InvalidConcurrency,
        HttpFixture.init(testing.allocator, testing.io, .{ .concurrency = 0 }),
    );
}
