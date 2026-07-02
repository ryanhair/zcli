//! An HTTP client with safe defaults, layered over `std.http.Client`.
//!
//! Nearly every CLI makes HTTP calls, and hand-rolling `std.http.Client` in a
//! command's `execute()` is both verbose and easy to get wrong (the classic
//! footgun being to disable TLS verification "just to make it work"). This
//! module gives a command author — or an AI writing freeform business logic —
//! a correct-by-default client with a small ergonomic surface (GET / POST /
//! JSON) that returns the status and body in one call.
//!
//! ## Safe defaults
//!
//! - **TLS verification is on and cannot be turned off here.** `std.http.Client`
//!   verifies certificates against the system CA bundle by default; this wrapper
//!   deliberately exposes no knob to disable it.
//! - **The response body is bounded** (`max_response_bytes`, default
//!   `default_max_response_bytes`). A hostile or misbehaving server cannot make
//!   the client allocate unbounded memory — the read fails with
//!   `error.ResponseTooLarge` once the limit is crossed.
//! - **Redirects are bounded** (`max_redirects`) for bodyless requests, and are
//!   not auto-followed for requests carrying a payload (a redirect must not
//!   silently replay a POST body against a different host).
//! - **Each request has an overall timeout** (default `default_timeout`) so a
//!   hung or dead server cannot make a command hang forever. See "Timeouts".
//!
//! ## Timeouts
//!
//! `std.http.Client` exposes no timeout of its own — in Zig 0.16 timeouts and
//! cancellation live in the `std.Io` layer. So an overall per-request timeout is
//! enforced there: the request runs as a concurrent task raced against a timer
//! (`std.Io.Select`), and whichever loses is canceled. A request that outlives
//! its deadline fails with `error.Timeout`.
//!
//! The timeout defaults to `default_timeout`, is configurable per client
//! (`Options.timeout`), and is overridable per request (`RequestOptions.timeout`).
//! Set the client's timeout to `null`, or a request's to `.none`, to disable it.
//! (Cancellation is delivered at the request's next I/O cancellation point —
//! connect, TLS handshake, or read — which is where a stuck request blocks; the
//! connection-pool's brief `lockUncancelable` critical sections do not.)
//!
//! ## Memory
//!
//! `Response.body` is owned by the allocator passed to `Client.init`. In a
//! command that allocator is the arena-per-command, so the body is reclaimed
//! when the command returns; `Response.deinit` is still provided for callers
//! (like tests) using a tracking allocator.

const std = @import("std");

/// Re-export so callers can build header lists without importing `std.http`.
pub const Header = std.http.Header;
pub const Method = std.http.Method;
pub const Status = std.http.Status;

/// Default cap on a response body: 10 MiB. Large enough for realistic API
/// payloads, small enough that a runaway response fails fast instead of
/// exhausting memory.
pub const default_max_response_bytes: usize = 10 * 1024 * 1024;

/// Maximum number of redirects followed for a bodyless request.
pub const max_redirects: u16 = 3;

/// Default overall timeout applied to each request: 30 seconds. Long enough for
/// a slow-but-alive API, short enough that a hung server does not hang a command
/// indefinitely.
pub const default_timeout: std.Io.Duration = .fromSeconds(30);

pub const Error = error{
    /// A response body exceeded `Client.max_response_bytes`.
    ResponseTooLarge,
    /// The server used a compression method this client does not support.
    UnsupportedCompressionMethod,
    /// The request did not complete within its timeout.
    Timeout,
};

/// Per-request timeout setting (`RequestOptions.timeout`).
pub const Timeout = union(enum) {
    /// Use the client's configured default timeout.
    inherit,
    /// Disable the timeout for this request.
    none,
    /// Override with a specific duration.
    after: std.Io.Duration,
};

/// A completed HTTP response. The body has been fully read (and decompressed,
/// if the server compressed it) into memory.
pub const Response = struct {
    allocator: std.mem.Allocator,
    status: Status,
    body: []u8,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }

    /// Parse the response body as JSON into `T`. The returned `Parsed(T)` owns
    /// its own arena — call `.deinit()` on it when done. Unknown fields are
    /// ignored so a struct can model just the parts of a payload it cares about.
    pub fn json(
        self: Response,
        comptime T: type,
        allocator: std.mem.Allocator,
    ) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, self.body, .{
            .ignore_unknown_fields = true,
        });
    }
};

/// Per-request knobs beyond the URL. Everything is optional; the zero value is
/// a plain request with no extra headers and no body.
pub const RequestOptions = struct {
    /// Extra headers sent verbatim (kept across cross-domain redirects).
    headers: []const Header = &.{},
    /// Request body. When set on a `POST`/`PUT`/etc., its length is sent as
    /// `Content-Length`.
    body: ?[]const u8 = null,
    /// Value for the `Content-Type` header, if any.
    content_type: ?[]const u8 = null,
    /// Overall timeout for this request. `.inherit` (the default) uses the
    /// client's configured timeout; `.none` disables it.
    timeout: Timeout = .inherit,
};

/// An HTTP client with safe defaults. Construct with `init`, reuse across
/// requests (the underlying connection pool is reused), and `deinit` when done.
pub const Client = struct {
    inner: std.http.Client,
    max_response_bytes: usize,
    /// Default overall timeout for each request; `null` disables it.
    timeout: ?std.Io.Duration,

    pub const Options = struct {
        max_response_bytes: usize = default_max_response_bytes,
        timeout: ?std.Io.Duration = default_timeout,
    };

    /// `io` is the `std.Io` the client performs network I/O with — in a command,
    /// `context.io.io`. `allocator` owns client-internal allocations and every
    /// returned `Response.body`; in a command, the arena-per-command allocator.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) Client {
        return .{
            .inner = .{ .allocator = allocator, .io = io },
            .max_response_bytes = options.max_response_bytes,
            .timeout = options.timeout,
        };
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
    }

    /// GET `url`.
    pub fn get(self: *Client, url: []const u8) !Response {
        return self.request(.GET, url, .{});
    }

    /// POST to `url` with `options` (typically a `body` + `content_type`).
    pub fn post(self: *Client, url: []const u8, options: RequestOptions) !Response {
        return self.request(.POST, url, options);
    }

    /// POST `value` serialized as JSON, with `Content-Type: application/json`.
    pub fn postJson(self: *Client, url: []const u8, value: anytype) !Response {
        const payload = try std.json.Stringify.valueAlloc(self.inner.allocator, value, .{});
        defer self.inner.allocator.free(payload);
        return self.request(.POST, url, .{
            .body = payload,
            .content_type = "application/json",
        });
    }

    /// The general request path used by all the convenience methods. Resolves
    /// the effective timeout and, when one applies, races the request against a
    /// timer so it fails with `error.Timeout` instead of hanging.
    pub fn request(
        self: *Client,
        method: Method,
        url: []const u8,
        options: RequestOptions,
    ) !Response {
        const timeout: ?std.Io.Duration = switch (options.timeout) {
            .inherit => self.timeout,
            .none => null,
            .after => |d| d,
        };
        const duration = timeout orelse return self.requestInner(method, url, options);

        const io = self.inner.io;
        // Preserve requestInner's precise error set in the race's result union.
        const ReqResult = @typeInfo(@TypeOf(requestInner)).@"fn".return_type.?;
        const Outcome = union(enum) {
            done: ReqResult,
            expired: std.Io.Cancelable!void,
        };

        var buffer: [2]Outcome = undefined;
        var race = std.Io.Select(Outcome).init(io, &buffer);
        try race.concurrent(.done, requestInner, .{ self, method, url, options });
        try race.concurrent(.expired, sleepFor, .{ io, duration });

        const first = try race.await();
        // Cancel and unwind whichever task lost the race (freeing any partial
        // allocations the losing request made).
        race.cancelDiscard();

        switch (first) {
            .done => |result| return result,
            .expired => return Error.Timeout,
        }
    }

    fn sleepFor(io: std.Io, duration: std.Io.Duration) std.Io.Cancelable!void {
        return io.sleep(duration, .awake);
    }

    /// Opens (or reuses) a connection, sends the request, then reads the whole
    /// response body into memory, bounded by `max_response_bytes` and
    /// transparently decompressed. `request` wraps this with the timeout race.
    fn requestInner(
        self: *Client,
        method: Method,
        url: []const u8,
        options: RequestOptions,
    ) !Response {
        const uri = try std.Uri.parse(url);

        // Combine caller headers with an optional content-type into one slice.
        var header_buf: [1]Header = undefined;
        const extra_headers: []const Header = if (options.content_type) |ct| blk: {
            // Fast path for the common case: only a content-type, no user
            // headers — no allocation needed.
            if (options.headers.len == 0) {
                header_buf[0] = .{ .name = "content-type", .value = ct };
                break :blk header_buf[0..1];
            }
            const combined = try self.inner.allocator.alloc(Header, options.headers.len + 1);
            @memcpy(combined[0..options.headers.len], options.headers);
            combined[options.headers.len] = .{ .name = "content-type", .value = ct };
            break :blk combined;
        } else options.headers;
        defer if (options.content_type != null and options.headers.len > 0) {
            self.inner.allocator.free(extra_headers);
        };

        // Don't auto-follow redirects for a request that carries a payload: a
        // redirect must not silently replay the body against a new host.
        const redirect_behavior: std.http.Client.Request.RedirectBehavior =
            if (options.body == null) @enumFromInt(max_redirects) else .unhandled;

        var req = try self.inner.request(method, uri, .{
            .redirect_behavior = redirect_behavior,
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        if (options.body) |body| {
            req.transfer_encoding = .{ .content_length = body.len };
            var body_writer = try req.sendBodyUnflushed(&.{});
            try body_writer.writer.writeAll(body);
            try body_writer.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        // Read header-derived fields before the first body read: obtaining the
        // reader invalidates the header string memory.
        const status = response.head.status;
        const content_encoding = response.head.content_encoding;

        // Size a decompression buffer per the negotiated content encoding, the
        // same way std.http.Client.fetch does.
        const decompress_buffer: []u8 = switch (content_encoding) {
            .identity => &.{},
            .zstd => try self.inner.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.inner.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return Error.UnsupportedCompressionMethod,
        };
        defer self.inner.allocator.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        const body = reader.allocRemaining(
            self.inner.allocator,
            .limited(self.max_response_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => return Error.ResponseTooLarge,
            error.ReadFailed => return response.bodyErr().?,
            error.OutOfMemory => return error.OutOfMemory,
        };

        return .{
            .allocator = self.inner.allocator,
            .status = status,
            .body = body,
        };
    }
};

const testing = std.testing;

test "Response.json parses body into a struct, ignoring unknown fields" {
    var response: Response = .{
        .allocator = testing.allocator,
        .status = .ok,
        .body = try testing.allocator.dupe(u8,
            \\{"name":"zcli","stars":42,"extra":"ignored"}
        ),
    };
    defer response.deinit();

    const Repo = struct { name: []const u8, stars: u32 };
    const parsed = try response.json(Repo, testing.allocator);
    defer parsed.deinit();

    try testing.expectEqualStrings("zcli", parsed.value.name);
    try testing.expectEqual(@as(u32, 42), parsed.value.stars);
}

test "postJson serializes a value the same way it is read back" {
    // Round-trip the serialization postJson performs, independent of any network.
    const payload = try std.json.Stringify.valueAlloc(
        testing.allocator,
        .{ .name = "zcli", .count = 3 },
        .{},
    );
    defer testing.allocator.free(payload);

    const Body = struct { name: []const u8, count: u32 };
    const parsed = try std.json.parseFromSlice(Body, testing.allocator, payload, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("zcli", parsed.value.name);
    try testing.expectEqual(@as(u32, 3), parsed.value.count);
}

test "an invalid URL fails before any network work" {
    var client = Client.init(testing.allocator, testing.io, .{});
    defer client.deinit();

    try testing.expectError(error.InvalidFormat, client.get("not-a-url"));
}

test "init records the configured response-size cap" {
    var bounded = Client.init(testing.allocator, testing.io, .{ .max_response_bytes = 1024 });
    defer bounded.deinit();
    try testing.expectEqual(@as(usize, 1024), bounded.max_response_bytes);

    var default_client = Client.init(testing.allocator, testing.io, .{});
    defer default_client.deinit();
    try testing.expectEqual(default_max_response_bytes, default_client.max_response_bytes);
}

// ---------------------------------------------------------------------------
// Loopback integration tests
//
// `std.testing.io` is a threaded Io, so these spin up a real HTTP server on a
// localhost ephemeral port and drive the full request path against it — the
// only way to exercise `request()` end to end, including the bounded-body
// enforcement that is this module's security-load-bearing default.
// ---------------------------------------------------------------------------

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
