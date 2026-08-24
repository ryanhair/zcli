//! Real-socket loopback integration tests for `http.Client`, isolated into
//! their own test binary (built ReleaseSafe — see below and build.zig).
//!
//! These drive the full request path against a localhost HTTP server on an
//! ephemeral port — the only way to exercise `request()` end to end, including
//! the bounded-body enforcement that is http.zig's security-load-bearing
//! default. They live here, rather than inline in http.zig, for two reasons:
//!
//!   1. Inline in http.zig they rode along into every test binary that imports
//!      the zcli module (roughly a dozen), re-running the same socket
//!      round-trips redundantly. Here they run exactly once.
//!   2. On Windows the loopback connect intermittently loses a concurrent dial
//!      and the OS returns STATUS_CONNECTION_REFUSED (NTSTATUS 0xc0000236). Zig
//!      0.16's std has no switch arm mapping that status in `netConnectIpWindows`
//!      (Threaded.zig), so a perfectly normal connection-refused falls through
//!      to `windows.unexpectedStatus()`, which dumps a stack trace to stderr
//!      whenever `std.options.unexpected_error_tracing` is on. The winning
//!      connection still succeeds, so the tests pass — but the trace is pure
//!      noise. That option's default is `mode == .Debug`, and a test binary's
//!      root is the injected test runner (so a `std_options` override in this
//!      file would be ignored). build.zig therefore compiles this one binary
//!      ReleaseSafe, which flips the default off while keeping safety checks —
//!      silencing the false positive without hiding it in any other binary.

const std = @import("std");
const testing = std.testing;
const http = @import("http.zig");

const Client = http.Client;
const Status = http.Status;
const Error = http.Error;
const Header = http.Header;

/// Accept exactly one connection and reply with `body`, then close. Runs
/// concurrently with the client under test.
fn serveOnce(io: std.Io, server: *std.Io.net.Server, body: []const u8) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = http_server.receiveHead() catch return;
    request.respond(body, .{}) catch return;
}

/// Accept one connection and hold it open without ever responding, until the
/// task is canceled. Used to make a client request time out deterministically.
fn serveStalled(io: std.Io, server: *std.Io.net.Server) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);
    // Sleep far longer than any test timeout; the test cancels this task.
    io.sleep(.fromSeconds(3600), .awake) catch {};
}

fn loopbackUrl(port: u16) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/", .{port});
}

test "GET over loopback returns the status and body" {
    const io = testing.io;

    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const body = "hello from zcli";
    var future = try io.concurrent(serveOnce, .{ io, &server, @as([]const u8, body) });
    defer future.await(io);

    var client = Client.init(testing.allocator, io, .{});
    defer client.deinit();

    const url = try loopbackUrl(port);
    defer testing.allocator.free(url);

    var response = try client.get(url);
    defer response.deinit();

    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings(body, response.body);
}

test "a response larger than the cap fails with ResponseTooLarge" {
    const io = testing.io;

    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    // 4 KiB body against a 1 KiB cap: the read must fail once the cap is crossed.
    const big = "x" ** 4096;
    var future = try io.concurrent(serveOnce, .{ io, &server, @as([]const u8, big) });
    defer future.await(io);

    var client = Client.init(testing.allocator, io, .{ .max_response_bytes = 1024 });
    defer client.deinit();

    const url = try loopbackUrl(port);
    defer testing.allocator.free(url);

    try testing.expectError(Error.ResponseTooLarge, client.get(url));
}

/// Accept one connection and answer with a redirect to `location` (with
/// `Connection: close`, so the client must dial the next hop instead of
/// reusing the pooled connection), then accept a second connection and report
/// which interesting headers arrived on it, as "auth=<bool> custom=<bool>".
fn serveRedirectThenEchoHeaders(io: std.Io, server: *std.Io.net.Server, location: []const u8) void {
    {
        var stream = server.accept(io) catch return;
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var stream_reader = stream.reader(io, &read_buf);
        var stream_writer = stream.writer(io, &write_buf);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = http_server.receiveHead() catch return;
        request.respond("", .{
            .status = .found,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "location", .value = location }},
        }) catch return;
    }
    {
        var stream = server.accept(io) catch return;
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var stream_reader = stream.reader(io, &read_buf);
        var stream_writer = stream.writer(io, &write_buf);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = http_server.receiveHead() catch return;

        var has_auth = false;
        var has_custom = false;
        var it = request.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) has_auth = true;
            if (std.ascii.eqlIgnoreCase(header.name, "x-zcli-test")) has_custom = true;
        }

        var body_buf: [64]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "auth={} custom={}", .{ has_auth, has_custom }) catch return;
        request.respond(body, .{}) catch return;
    }
}

const redirect_test_headers = [_]Header{
    .{ .name = "authorization", .value = "Bearer secret-token" },
    .{ .name = "x-zcli-test", .value = "1" },
};

test "credential headers survive a same-host redirect" {
    const io = testing.io;

    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const location = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/next", .{port});
    defer testing.allocator.free(location);

    var future = try io.concurrent(serveRedirectThenEchoHeaders, .{ io, &server, @as([]const u8, location) });
    defer future.await(io);

    var client = Client.init(testing.allocator, io, .{});
    defer client.deinit();

    const url = try loopbackUrl(port);
    defer testing.allocator.free(url);

    var response = try client.request(.GET, url, .{ .headers = &redirect_test_headers });
    defer response.deinit();

    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("auth=true custom=true", response.body);
}

test "credential headers are stripped when a redirect crosses hosts" {
    const io = testing.io;

    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    // Same listener, but the redirect names a different host ("localhost" vs
    // "127.0.0.1"), so std.http.Client must treat the hop as cross-domain and
    // drop the privileged headers while keeping the custom one.
    const location = try std.fmt.allocPrint(testing.allocator, "http://localhost:{d}/next", .{port});
    defer testing.allocator.free(location);

    var future = try io.concurrent(serveRedirectThenEchoHeaders, .{ io, &server, @as([]const u8, location) });
    defer future.await(io);

    var client = Client.init(testing.allocator, io, .{});
    defer client.deinit();

    const url = try loopbackUrl(port);
    defer testing.allocator.free(url);

    var response = try client.request(.GET, url, .{ .headers = &redirect_test_headers });
    defer response.deinit();

    try testing.expectEqual(Status.ok, response.status);
    try testing.expectEqualStrings("auth=false custom=true", response.body);
}

/// Answer every connection with a redirect back to `location`, until canceled.
/// Used to prove the client bounds redirect chains.
fn serveEndlessRedirects(io: std.Io, server: *std.Io.net.Server, location: []const u8) void {
    while (true) {
        var stream = server.accept(io) catch return;
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var stream_reader = stream.reader(io, &read_buf);
        var stream_writer = stream.writer(io, &write_buf);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = http_server.receiveHead() catch return;
        request.respond("", .{
            .status = .found,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "location", .value = location }},
        }) catch return;
    }
}

test "a redirect loop fails with TooManyRedirects" {
    const io = testing.io;

    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const url = try loopbackUrl(port);
    defer testing.allocator.free(url);

    var future = try io.concurrent(serveEndlessRedirects, .{ io, &server, @as([]const u8, url) });
    defer _ = future.cancel(io);

    var client = Client.init(testing.allocator, io, .{});
    defer client.deinit();

    try testing.expectError(Error.TooManyRedirects, client.get(url));
}

/// Accept one connection and reply with a redirect to `location`, then close.
fn serveOneRedirect(io: std.Io, server: *std.Io.net.Server, location: []const u8) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = http_server.receiveHead() catch return;
    request.respond("", .{
        .status = .found,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    }) catch return;
}

test "a redirect to a non-https remote host fails with InsecureRedirect" {
    const io = testing.io;

    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    // The redirect target is a plain-http URL for a non-loopback host. The client
    // must refuse this downgrade before opening any connection to the target.
    const http_remote = "http://cdn.example.com/file";
    var future = try io.concurrent(serveOneRedirect, .{ io, &server, @as([]const u8, http_remote) });
    defer future.await(io);

    var client = Client.init(testing.allocator, io, .{});
    defer client.deinit();

    const url = try loopbackUrl(port);
    defer testing.allocator.free(url);

    try testing.expectError(Error.InsecureRedirect, client.get(url));
}

test "a credentialed request refuses the same redirect, with the token in flight" {
    const io = testing.io;

    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    // Same downgrade, but the request carries `authorization`: the first hop is
    // loopback (the carve-out, so the header legitimately goes out) and the
    // server then points at plain http on a remote host. The guard must fire on
    // the redirect *target*, before the client dials it — the case that matters
    // most, since the destination is entirely server-controlled and a bearer
    // token is in flight.
    const http_remote = "http://cdn.example.com/file";
    var future = try io.concurrent(serveOneRedirect, .{ io, &server, @as([]const u8, http_remote) });
    defer future.await(io);

    var client = Client.init(testing.allocator, io, .{});
    defer client.deinit();

    const url = try loopbackUrl(port);
    defer testing.allocator.free(url);

    try testing.expectError(
        Error.InsecureRedirect,
        client.request(.GET, url, .{ .headers = &redirect_test_headers }),
    );
}

test "a request that outlives its timeout fails with error.Timeout" {
    const io = testing.io;

    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    // Server accepts but never responds; cancel it once the client has timed out.
    var server_future = try io.concurrent(serveStalled, .{ io, &server });
    defer _ = server_future.cancel(io);

    var client = Client.init(testing.allocator, io, .{
        .timeout = .fromMilliseconds(100),
    });
    defer client.deinit();

    const url = try loopbackUrl(port);
    defer testing.allocator.free(url);

    try testing.expectError(Error.Timeout, client.get(url));
}

/// Answer every connection with `body` until this task is canceled, closing each
/// one after a single exchange. A client that was canceled mid-request tears its
/// connection down, which the accept loop must survive rather than treat as the
/// end of the run — otherwise the timeout sweep below would silently be talking
/// to a dead server. Only cancelation, or a genuinely broken listener, stops it.
fn serveUntilCanceled(io: std.Io, server: *std.Io.net.Server, body: []const u8) void {
    while (true) {
        var stream = server.accept(io) catch |err| switch (err) {
            // The peer went away between the SYN and the accept — exactly what a
            // canceled client request looks like from here.
            error.ConnectionAborted => continue,
            else => return,
        };
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var stream_reader = stream.reader(io, &read_buf);
        var stream_writer = stream.writer(io, &write_buf);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = http_server.receiveHead() catch continue;
        request.respond(body, .{ .keep_alive = false }) catch continue;
    }
}

test "a response that completes as the timeout fires is not leaked" {
    const io = testing.io;

    var addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const body = "raced response body";
    var server_future = try io.concurrent(serveUntilCanceled, .{ io, &server, @as([]const u8, body) });
    defer _ = server_future.cancel(io);

    const url = try loopbackUrl(port);
    defer testing.allocator.free(url);

    // Calibrate on this machine: time one untimed round trip, so the sweep below
    // straddles the real request duration instead of a guessed constant.
    const start = std.Io.Timestamp.now(io, .awake);
    {
        var client = Client.init(testing.allocator, io, .{ .timeout = null });
        defer client.deinit();
        var response = try client.get(url);
        defer response.deinit();
        try testing.expectEqualStrings(body, response.body);
    }
    const round_trip = std.Io.Timestamp.durationTo(start, std.Io.Timestamp.now(io, .awake));
    const round_trip_ns: i96 = @max(1, round_trip.nanoseconds);

    // Sweep timeouts from 1ns (the timer cannot lose) up to several times the
    // measured round trip (the request cannot lose), so the run necessarily
    // crosses the boundary in between. That boundary is the bug's window: the
    // timer wins the select, yet the request completes anyway before cancelation
    // reaches it — cancelation is only delivered at the next I/O cancelation
    // point — handing back a fully-allocated `Response` that nothing else can
    // free. Dropping it leaks under `testing.allocator`, failing this test.
    //
    // Which iterations land in that window is scheduling-dependent, so the
    // outcome tallies below are the guard that the sweep actually swept: seeing
    // both a `Timeout` and a completed response proves the boundary was crossed
    // and the server stayed alive throughout. A sweep that produced only one
    // regime proves nothing, so it is retried rather than passed.
    const iterations = 64;
    const max_rounds = 4;
    var timed_out: usize = 0;
    var completed: usize = 0;

    var round: usize = 0;
    while (round < max_rounds and (timed_out == 0 or completed == 0)) : (round += 1) {
        for (0..iterations) |i| {
            const span = round_trip_ns * 4 * @as(i96, @intCast(i));
            const ns = 1 + @divTrunc(span, iterations);
            var client = Client.init(testing.allocator, io, .{ .timeout = .fromNanoseconds(ns) });
            defer client.deinit();

            if (client.get(url)) |result| {
                var response = result;
                defer response.deinit();
                try testing.expectEqual(Status.ok, response.status);
                try testing.expectEqualStrings(body, response.body);
                completed += 1;
            } else |err| switch (err) {
                Error.Timeout => timed_out += 1,
                // A request canceled mid-flight surfaces as its connection being
                // torn down under it. That is a legitimate sweep outcome, but it
                // is not evidence either regime was reached, so it is not counted.
                error.Canceled, error.ConnectionResetByPeer, error.EndOfStream => {},
                else => return err,
            }
        }
    }

    // Not assertions about the fix — assertions that the sweep was meaningful.
    try testing.expect(timed_out > 0);
    try testing.expect(completed > 0);
}
