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
//!   silently replay a POST body against a different host). Redirects are
//!   followed by this wrapper itself, not `std.http.Client` — see below.
//! - **Credential headers do not leak across origins.** Caller-supplied
//!   `authorization`, `cookie`, and `proxy-authorization` headers are sent with
//!   the initial request and kept for redirects within the same origin
//!   (scheme + host + port), but stripped as soon as a redirect leaves it, so
//!   a hostile redirect cannot exfiltrate a bearer token. Other caller headers
//!   are kept across all redirects. (This is why the wrapper follows redirects
//!   itself: as of 0.16, `std.http.Client`'s auto-follow re-sends every extra
//!   header to the redirect target regardless of origin.)
//! - **Credential headers never ride cleartext to a remote host.** A request
//!   that carries one of those credential headers over a non-`https` scheme
//!   fails with `error.InsecureCredentialTransport` — checked on every hop, so a
//!   same-origin `http`→`http` redirect cannot smuggle a token onto the wire
//!   either. The sole carve-out is loopback (`127.0.0.0/8`, `::1`, `localhost`),
//!   which is a secure transport in practice (nothing on the wire) and is what
//!   the loopback integration tests exercise; every real caller uses `https`.
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
    /// A redirect chain exceeded `max_redirects`.
    TooManyRedirects,
    /// A request carrying a credential header (`authorization`, `cookie`, or
    /// `proxy-authorization`) targeted a non-`https` origin that is not
    /// loopback. Refused fail-closed so a bearer token / cookie is never put on
    /// the wire in cleartext to a remote host.
    InsecureCredentialTransport,
};

/// Request headers that carry credentials. These are stripped from a request
/// as soon as a redirect leaves the origin they were originally sent to.
const privileged_header_names = [_][]const u8{
    "authorization",
    "cookie",
    "proxy-authorization",
};

fn isPrivilegedHeaderName(name: []const u8) bool {
    for (privileged_header_names) |privileged| {
        if (std.ascii.eqlIgnoreCase(name, privileged)) return true;
    }
    return false;
}

fn defaultPort(scheme: []const u8) u16 {
    if (std.ascii.eqlIgnoreCase(scheme, "http")) return 80;
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return 443;
    return 0;
}

/// Strict same-origin check: scheme, host, and effective port must all match.
/// Deliberately stricter than `std.http.Client`'s parent-domain redirect rule —
/// credentials for api.example.com must not follow a redirect to
/// evil.example.com.
fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;
    var a_buf: [256]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    const a_host = (a.host orelse return false).toRaw(&a_buf) catch return false;
    const b_host = (b.host orelse return false).toRaw(&b_buf) catch return false;
    if (!std.ascii.eqlIgnoreCase(a_host, b_host)) return false;
    return (a.port orelse defaultPort(a.scheme)) == (b.port orelse defaultPort(b.scheme));
}

/// True when `host` is a loopback address — the one carve-out where a credential
/// header may travel over cleartext `http`, because nothing leaves the machine.
/// Covers the IPv4 loopback block `127.0.0.0/8`, the IPv6 loopback `::1` (with or
/// without brackets), and the literal name `localhost`.
fn isLoopbackHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    // IPv6 literal, possibly bracketed in a URI authority.
    const h = std.mem.trim(u8, host, "[]");
    if (std.Io.net.IpAddress.parse(h, 0)) |addr| {
        return switch (addr) {
            .ip4 => |v4| v4.bytes[0] == 127, // 127.0.0.0/8
            .ip6 => |v6| std.mem.eql(u8, &v6.bytes, &([_]u8{0} ** 15 ++ [_]u8{1})), // ::1
        };
    } else |_| return false;
}

/// A credential-bearing request may go out only over `https`, or to a loopback
/// host over any scheme. Returns false for anything else (cleartext to a remote
/// host), which the request loop turns into `error.InsecureCredentialTransport`.
fn credentialTransportOk(uri: std.Uri) bool {
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    var host_buf: [256]u8 = undefined;
    const host = (uri.host orelse return false).toRaw(&host_buf) catch return false;
    return isLoopbackHost(host);
}

/// The Location to follow for a redirect response, or null when the status is
/// not one this client follows (e.g. 300 or 304).
fn redirectTarget(status: Status, location: ?[]const u8) ?[]const u8 {
    return switch (status) {
        .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => location,
        else => null,
    };
}

/// Resolve a redirect `location` (possibly relative) against `base`, returning
/// a freshly-allocated absolute URL string.
fn resolveLocation(
    allocator: std.mem.Allocator,
    base: std.Uri,
    location: []const u8,
) ![]u8 {
    // resolveInPlace wants the location at the start of a mutable buffer, with
    // headroom after it for path merging.
    const aux = try allocator.alloc(u8, location.len + 4096);
    defer allocator.free(aux);
    @memcpy(aux[0..location.len], location);
    var remaining: []u8 = aux;
    const resolved = try base.resolveInPlace(location.len, &remaining);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try resolved.writeToStream(&out.writer, .{
        .scheme = true,
        .authority = true,
        .path = true,
        .query = true,
    });
    return out.toOwnedSlice();
}

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
    /// Extra headers sent verbatim. Credential-bearing headers (`authorization`,
    /// `cookie`, `proxy-authorization`; case-insensitive) are stripped as soon
    /// as a redirect leaves the original origin (scheme + host + port); all
    /// others are kept across every redirect.
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
    /// `context.io`. `allocator` owns client-internal allocations and every
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
    ///
    /// Redirects are followed here in the wrapper, not by `std.http.Client`:
    /// std's auto-follow (as of 0.16) re-sends every extra header to the
    /// redirect target regardless of origin, which would leak credential
    /// headers cross-origin. Following them ourselves lets us drop credential
    /// headers the moment a hop leaves the original origin.
    fn requestInner(
        self: *Client,
        method: Method,
        url: []const u8,
        options: RequestOptions,
    ) !Response {
        const allocator = self.inner.allocator;

        // Build the hop header list with non-credential headers (plus an
        // optional content-type) first and credential headers last, so the
        // credential-stripped view is simply a prefix of the full list.
        var headers: std.ArrayList(Header) = .empty;
        defer headers.deinit(allocator);
        try headers.ensureTotalCapacity(allocator, options.headers.len + 1);
        for (options.headers) |header| {
            if (!isPrivilegedHeaderName(header.name)) headers.appendAssumeCapacity(header);
        }
        if (options.content_type) |ct| {
            headers.appendAssumeCapacity(.{ .name = "content-type", .value = ct });
        }
        const safe_header_count = headers.items.len;
        for (options.headers) |header| {
            if (isPrivilegedHeaderName(header.name)) headers.appendAssumeCapacity(header);
        }
        // Whether any credential header is present at all — the guard below only
        // needs to fire when a hop would actually put one on the wire.
        const has_credentials = headers.items.len > safe_header_count;

        var current_method = method;
        var current_url: []const u8 = url;
        var owned_url: ?[]u8 = null;
        defer if (owned_url) |u| allocator.free(u);
        var send_credentials = true;
        var hops: u16 = 0;

        while (true) {
            const uri = try std.Uri.parse(current_url);

            // Fail closed before opening the connection: a credential header must
            // never travel in cleartext to a remote host. This covers the initial
            // request and every same-origin `http`→`http` redirect hop (a hop that
            // leaves the origin has already cleared `send_credentials`). `https`
            // and loopback are the only origins allowed to carry credentials.
            if (send_credentials and has_credentials and !credentialTransportOk(uri)) {
                return Error.InsecureCredentialTransport;
            }

            const hop_headers = headers.items[0..if (send_credentials)
                headers.items.len
            else
                safe_header_count];

            var req = try self.inner.request(current_method, uri, .{
                .redirect_behavior = .unhandled,
                .extra_headers = hop_headers,
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

            // No aux buffer needed: with `.unhandled` receiveHead never
            // resolves redirects itself.
            var response = try req.receiveHead(&.{});

            // Read header-derived fields before the first body read: obtaining
            // the reader invalidates the header string memory.
            const status = response.head.status;
            const content_encoding = response.head.content_encoding;

            // Follow redirects only for bodyless requests: a redirect must not
            // silently replay a payload against a new host. Payload-carrying
            // requests get the 3xx response back as the result.
            if (options.body == null and status.class() == .redirect) {
                if (redirectTarget(status, response.head.location)) |location| {
                    if (hops >= max_redirects) return Error.TooManyRedirects;
                    hops += 1;

                    const next_url = try resolveLocation(allocator, uri, location);
                    errdefer allocator.free(next_url);
                    // `uri` still references the previous URL string — settle
                    // the origin question before releasing it.
                    const next_uri = try std.Uri.parse(next_url);
                    if (!sameOrigin(uri, next_uri)) send_credentials = false;
                    // A 303 means "GET the result of what you sent".
                    if (status == .see_other) current_method = .GET;

                    if (owned_url) |u| allocator.free(u);
                    owned_url = next_url;
                    current_url = next_url;
                    continue;
                }
            }

            // Size a decompression buffer per the negotiated content encoding,
            // the same way std.http.Client.fetch does.
            const decompress_buffer: []u8 = switch (content_encoding) {
                .identity => &.{},
                .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
                .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
                .compress => return Error.UnsupportedCompressionMethod,
            };
            defer allocator.free(decompress_buffer);

            var transfer_buffer: [64]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

            const body = reader.allocRemaining(
                allocator,
                .limited(self.max_response_bytes),
            ) catch |err| switch (err) {
                error.StreamTooLong => return Error.ResponseTooLarge,
                error.ReadFailed => return response.bodyErr().?,
                error.OutOfMemory => return error.OutOfMemory,
            };

            return .{
                .allocator = allocator,
                .status = status,
                .body = body,
            };
        }
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

test "isPrivilegedHeaderName matches credential headers case-insensitively" {
    try testing.expect(isPrivilegedHeaderName("authorization"));
    try testing.expect(isPrivilegedHeaderName("Authorization"));
    try testing.expect(isPrivilegedHeaderName("COOKIE"));
    try testing.expect(isPrivilegedHeaderName("Proxy-Authorization"));
    try testing.expect(!isPrivilegedHeaderName("accept"));
    try testing.expect(!isPrivilegedHeaderName("x-api-version"));
    try testing.expect(!isPrivilegedHeaderName("authorization-extra"));
}

test "sameOrigin requires scheme, host, and effective port to match" {
    const parse = std.Uri.parse;
    try testing.expect(sameOrigin(try parse("https://api.example.com/a"), try parse("https://api.example.com/b")));
    try testing.expect(sameOrigin(try parse("https://api.example.com/"), try parse("https://API.EXAMPLE.COM:443/")));
    try testing.expect(!sameOrigin(try parse("https://api.example.com/"), try parse("http://api.example.com/")));
    try testing.expect(!sameOrigin(try parse("https://api.example.com/"), try parse("https://evil.example.com/")));
    try testing.expect(!sameOrigin(try parse("https://api.example.com/"), try parse("https://example.com/")));
    try testing.expect(!sameOrigin(try parse("https://api.example.com/"), try parse("https://api.example.com:8443/")));
    try testing.expect(!sameOrigin(try parse("http://127.0.0.1:8080/"), try parse("http://127.0.0.1:9090/")));
}

test "isLoopbackHost recognizes loopback names and addresses only" {
    try testing.expect(isLoopbackHost("localhost"));
    try testing.expect(isLoopbackHost("LocalHost"));
    try testing.expect(isLoopbackHost("127.0.0.1"));
    try testing.expect(isLoopbackHost("127.1.2.3")); // whole 127.0.0.0/8 block
    try testing.expect(isLoopbackHost("::1"));
    try testing.expect(isLoopbackHost("[::1]")); // bracketed IPv6 authority
    try testing.expect(!isLoopbackHost("example.com"));
    try testing.expect(!isLoopbackHost("10.0.0.1"));
    try testing.expect(!isLoopbackHost("128.0.0.1"));
    try testing.expect(!isLoopbackHost("localhost.evil.com"));
    try testing.expect(!isLoopbackHost("::2"));
}

test "credentialTransportOk allows https and loopback, refuses cleartext to a remote host" {
    const parse = std.Uri.parse;
    // https anywhere is fine.
    try testing.expect(credentialTransportOk(try parse("https://api.example.com/")));
    try testing.expect(credentialTransportOk(try parse("https://127.0.0.1:8443/")));
    // http only on loopback.
    try testing.expect(credentialTransportOk(try parse("http://127.0.0.1:8080/")));
    try testing.expect(credentialTransportOk(try parse("http://localhost:8080/")));
    try testing.expect(credentialTransportOk(try parse("http://[::1]:8080/")));
    // http to a remote host is refused — this is the leak the guard closes.
    try testing.expect(!credentialTransportOk(try parse("http://api.example.com/")));
    try testing.expect(!credentialTransportOk(try parse("http://10.0.0.5/")));
}

test "a credentialed request over cleartext to a remote host is refused before connecting" {
    var client = Client.init(testing.allocator, testing.io, .{});
    defer client.deinit();

    // An authorization header over plain http to a non-loopback host must fail
    // closed with InsecureCredentialTransport, without any network work.
    const creds = [_]Header{.{ .name = "authorization", .value = "Bearer secret-token" }};
    try testing.expectError(
        Error.InsecureCredentialTransport,
        client.request(.GET, "http://api.example.com/", .{ .headers = &creds }),
    );
    // A cookie header is guarded the same way.
    const cookie = [_]Header{.{ .name = "cookie", .value = "session=abc" }};
    try testing.expectError(
        Error.InsecureCredentialTransport,
        client.request(.GET, "http://api.example.com/", .{ .headers = &cookie }),
    );
}

test "redirectTarget follows only real redirect statuses" {
    try testing.expectEqualStrings("/next", redirectTarget(.found, "/next").?);
    try testing.expectEqualStrings("/next", redirectTarget(.moved_permanently, "/next").?);
    try testing.expectEqualStrings("/next", redirectTarget(.permanent_redirect, "/next").?);
    try testing.expect(redirectTarget(.not_modified, "/next") == null);
    try testing.expect(redirectTarget(.multiple_choice, "/next") == null);
    try testing.expect(redirectTarget(.found, null) == null);
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
