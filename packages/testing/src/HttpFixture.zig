//! A scripted loopback HTTP server for adapter and client integration tests.
//!
//! Queue the responses the code under test should see, point it at
//! `fixture.baseUrl()` (or `fixture.url("/some/path")`), then inspect
//! `fixture.requests()` to assert on what it actually sent. The fixture owns the
//! listening socket, the tasks that serve it, and every byte it hands back — one
//! `deinit()` releases all of it.
//!
//! ```zig
//! const HttpFixture = @import("zcli-testing").HttpFixture;
//!
//! test "the adapter sends the token and parses the payload" {
//!     var fixture = try HttpFixture.init(std.testing.allocator, std.testing.io, .{});
//!     defer fixture.deinit();
//!
//!     try fixture.respondWith(.{
//!         .status = .ok,
//!         .headers = &.{.{ .name = "content-type", .value = "application/json" }},
//!         .body = "{\"id\":7}",
//!     });
//!
//!     // ... drive the code under test against fixture.url("/widgets") ...
//!
//!     const sent = fixture.requests();
//!     try std.testing.expectEqual(@as(usize, 1), sent.len);
//!     try std.testing.expectEqual(std.http.Method.GET, sent[0].method);
//!     try std.testing.expectEqualStrings("/widgets", sent[0].target);
//! }
//! ```
//!
//! **Ordering.** Queued responses are handed out in the order they were queued,
//! one per request. A client that issues its requests sequentially therefore
//! sees them in exactly the scripted order. Once the queue runs dry, every
//! further request is answered with `unscripted_status` and `unscripted_body` —
//! a loud, assertable signal instead of a hang.
//!
//! **Threading.** The serving tasks run concurrently with the caller, so the
//! `allocator` passed to `init` must be safe to use from more than one thread
//! (`std.testing.allocator` is). The fixture's own state is serialized
//! internally.

const std = @import("std");

const HttpFixture = @This();

/// Status returned once the queue of scripted responses is exhausted.
pub const unscripted_status: std.http.Status = .internal_server_error;
/// Body returned once the queue of scripted responses is exhausted. A test that
/// wants to prove it scripted enough responses can assert on this.
pub const unscripted_body = "zcli-testing: no queued response";

pub const Options = struct {
    /// How many connections the fixture serves at the same time. Each one costs
    /// a task for the fixture's lifetime. Must be at least 1.
    concurrency: usize = 4,
    /// Upper bound on how many request-body bytes are recorded per request.
    /// Anything beyond it is read and discarded and `Request.body_truncated` is
    /// set, so the code under test cannot turn the fixture into an unbounded
    /// buffer.
    max_request_body_bytes: usize = 64 * 1024,
};

/// One scripted response. Every field is copied by `respondWith`, so the caller
/// keeps ownership of whatever it passes in.
pub const Response = struct {
    status: std.http.Status = .ok,
    headers: []const std.http.Header = &.{},
    body: []const u8 = "",
};

/// One request the fixture served. All slices are owned by the fixture and stay
/// valid until `deinit`.
pub const Request = struct {
    method: std.http.Method,
    /// The request target exactly as it arrived on the request line, e.g.
    /// `/widgets?page=2`.
    target: []const u8,
    headers: []const std.http.Header,
    /// The request body, truncated to `Options.max_request_body_bytes`.
    body: []const u8,
    /// True when the body was longer than the recording bound, so `body` holds
    /// only its first `max_request_body_bytes` bytes.
    body_truncated: bool,

    /// The value of the first header named `name` (case-insensitive), or null.
    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

pub const InitError = std.mem.Allocator.Error ||
    std.Io.net.IpAddress.ListenError ||
    std.Io.ConcurrentError ||
    error{InvalidConcurrency};

allocator: std.mem.Allocator,
io: std.Io,
options: Options,

server: std.Io.net.Server,
/// `http://127.0.0.1:<port>` — no trailing slash.
base_url: []u8,

/// Guards everything below it.
mutex: std.Io.Mutex,
queue: std.ArrayList(Response),
/// Index of the next response in `queue` to hand out. Consumed entries stay in
/// the list so there is exactly one place that frees their bytes.
queue_pos: usize,
recorded: std.ArrayList(Request),
/// Strings handed out by `url`, freed with the fixture.
urls: std.ArrayList([]u8),

/// Latched by `deinit` so a serving task whose cancelation was swallowed by a
/// socket read still leaves its accept loop instead of blocking again.
shutting_down: std.atomic.Value(bool),
tasks: std.Io.Group,

/// Bind an ephemeral loopback port and start serving. The fixture is
/// heap-allocated because the serving tasks hold a pointer to it; `deinit`
/// releases it.
pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) InitError!*HttpFixture {
    if (options.concurrency == 0) return error.InvalidConcurrency;

    const self = try allocator.create(HttpFixture);
    errdefer allocator.destroy(self);

    // A dotted-quad literal always parses; the error set is unreachable here.
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(io, .{});
    errdefer server.deinit(io);

    const base_url = try std.fmt.allocPrint(
        allocator,
        "http://127.0.0.1:{d}",
        .{server.socket.address.getPort()},
    );
    errdefer allocator.free(base_url);

    self.* = .{
        .allocator = allocator,
        .io = io,
        .options = options,
        .server = server,
        .base_url = base_url,
        .mutex = .init,
        .queue = .empty,
        .queue_pos = 0,
        .recorded = .empty,
        .urls = .empty,
        .shutting_down = .init(false),
        .tasks = .init,
    };

    // Spawn the whole serving set up front, so the fixture's concurrency is a
    // fixed, known quantity for the test rather than something that depends on
    // when requests happen to arrive.
    errdefer {
        self.shutting_down.store(true, .release);
        self.tasks.cancel(io);
    }
    for (0..options.concurrency) |_| try self.tasks.concurrent(io, serve, .{self});

    return self;
}

/// Stop serving, close the socket, and free everything the fixture allocated —
/// the fixture itself included. Safe whether or not any request was served.
pub fn deinit(self: *HttpFixture) void {
    const allocator = self.allocator;
    const io = self.io;

    // Order matters: latch first, then cancel. A task parked in `accept` wakes
    // with `error.Canceled`; a task whose cancelation was instead consumed (and
    // erased into `error.ReadFailed`) by a socket read mid-connection sees the
    // latch on its next loop check. Either way it returns, so `cancel` — which
    // also awaits the group — cannot hang.
    self.shutting_down.store(true, .release);
    self.tasks.cancel(io);

    // Only now that every task has finished is it safe to close the listener and
    // free what they were reading into and writing from.
    self.server.deinit(io);

    for (self.queue.items) |response| freeResponse(allocator, response);
    self.queue.deinit(allocator);

    for (self.recorded.items) |request| freeRequest(allocator, request);
    self.recorded.deinit(allocator);

    for (self.urls.items) |u| allocator.free(u);
    self.urls.deinit(allocator);

    allocator.free(self.base_url);
    allocator.destroy(self);
}

/// `http://127.0.0.1:<ephemeral port>`, with no trailing slash. Requesting it
/// directly targets `/`.
pub fn baseUrl(self: *const HttpFixture) []const u8 {
    return self.base_url;
}

/// `baseUrl()` joined with `path` (which must start with `/`). The returned
/// string is owned by the fixture and freed by `deinit`.
pub fn url(self: *HttpFixture, path: []const u8) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(path.len > 0 and path[0] == '/');

    const joined = try std.mem.concat(self.allocator, u8, &.{ self.base_url, path });
    errdefer self.allocator.free(joined);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.urls.append(self.allocator, joined);
    return joined;
}

/// Queue one response. Call it once per request the code under test will make;
/// they are served in queue order.
pub fn respondWith(self: *HttpFixture, response: Response) std.mem.Allocator.Error!void {
    const owned = try dupeResponse(self.allocator, response);
    errdefer freeResponse(self.allocator, owned);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.queue.append(self.allocator, owned);
}

/// Every request served so far, oldest first. The slice is invalidated when the
/// fixture serves another request, so read it once the work under test is done.
pub fn requests(self: *HttpFixture) []const Request {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.recorded.items;
}

// ============================================================================
// Serving
// ============================================================================

/// Accept connections until the fixture is torn down. One of these runs per
/// `Options.concurrency`.
fn serve(self: *HttpFixture) std.Io.Cancelable!void {
    while (!self.shutting_down.load(.acquire)) {
        // Every accept failure — `error.Canceled` at teardown included — retires
        // this task; there is no state left to unwind.
        var stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        self.serveConnection(&stream);
    }
}

/// Serve requests on one connection until the peer goes away, the client asks
/// for the connection to close, or anything fails. Connection-level failures are
/// how a connection normally ends here (teardown included), so they end the
/// connection rather than being reported.
fn serveConnection(self: *HttpFixture, stream: *std.Io.net.Stream) void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(self.io, &read_buf);
    var stream_writer = stream.writer(self.io, &write_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    while (!self.shutting_down.load(.acquire)) {
        var request = http_server.receiveHead() catch return;
        const keep_alive = request.head.keep_alive;
        self.serveRequest(&request) catch return;
        if (!keep_alive) return;
    }
}

const ServeError = std.mem.Allocator.Error ||
    std.http.Server.Request.ExpectContinueError ||
    std.Io.Reader.ShortError;

/// Record one request, then answer it from the queue.
fn serveRequest(self: *HttpFixture, request: *std.http.Server.Request) ServeError!void {
    const response = try self.recordAndDequeue(request);
    try request.respond(response.body, .{
        .status = response.status,
        .extra_headers = response.headers,
    });
}

/// Copy the request into the recording and take the next scripted response. The
/// returned `Response` borrows fixture-owned bytes that live until `deinit`.
fn recordAndDequeue(self: *HttpFixture, request: *std.http.Server.Request) ServeError!Response {
    // The head strings point into the connection's read buffer and are
    // invalidated the moment the body reader is created, so copy them first.
    var recorded: Request = .{
        .method = request.head.method,
        .target = try self.allocator.dupe(u8, request.head.target),
        .headers = &.{},
        .body = &.{},
        .body_truncated = false,
    };
    errdefer freeRequest(self.allocator, recorded);
    recorded.headers = try dupeHeaders(self.allocator, request.iterateHeaders());

    try self.recordBody(request, &recorded);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    // Nothing below can fail, so the recording is final once this append lands.
    try self.recorded.append(self.allocator, recorded);

    if (self.queue_pos == self.queue.items.len) {
        return .{ .status = unscripted_status, .body = unscripted_body };
    }
    defer self.queue_pos += 1;
    return self.queue.items[self.queue_pos];
}

/// Read the request body into `recorded`, bounded by
/// `Options.max_request_body_bytes`, then drain whatever is left so the
/// connection stays reusable.
fn recordBody(self: *HttpFixture, request: *std.http.Server.Request, recorded: *Request) ServeError!void {
    var body_buf: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&body_buf);

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(self.allocator);

    reader.appendRemaining(
        self.allocator,
        &body,
        .limited(self.options.max_request_body_bytes),
    ) catch |err| switch (err) {
        // The body reached the recording bound: keep the prefix and discard the
        // rest so the connection stays reusable. `appendRemaining` reports this
        // on reaching the bound as well as on passing it, so only call the
        // recording truncated if bytes were actually dropped.
        error.StreamTooLong => recorded.body_truncated = try reader.discardRemaining() > 0,
        else => |e| return e,
    };

    recorded.body = try body.toOwnedSlice(self.allocator);
}

// ============================================================================
// Owned copies
// ============================================================================

fn dupeResponse(allocator: std.mem.Allocator, response: Response) std.mem.Allocator.Error!Response {
    var out: Response = .{ .status = response.status };
    errdefer freeResponse(allocator, out);
    out.headers = try dupeHeaderSlice(allocator, response.headers);
    out.body = try allocator.dupe(u8, response.body);
    return out;
}

fn freeResponse(allocator: std.mem.Allocator, response: Response) void {
    freeHeaders(allocator, response.headers);
    allocator.free(response.body);
}

fn freeRequest(allocator: std.mem.Allocator, request: Request) void {
    freeHeaders(allocator, request.headers);
    allocator.free(request.target);
    allocator.free(request.body);
}

fn dupeHeaderSlice(
    allocator: std.mem.Allocator,
    headers: []const std.http.Header,
) std.mem.Allocator.Error![]const std.http.Header {
    var out: std.ArrayList(std.http.Header) = .empty;
    errdefer freeHeaderList(allocator, &out);
    for (headers) |h| try out.append(allocator, try dupeHeader(allocator, h));
    return out.toOwnedSlice(allocator);
}

fn dupeHeaders(
    allocator: std.mem.Allocator,
    iterator: std.http.HeaderIterator,
) std.mem.Allocator.Error![]const std.http.Header {
    var it = iterator;
    var out: std.ArrayList(std.http.Header) = .empty;
    errdefer freeHeaderList(allocator, &out);
    while (it.next()) |h| try out.append(allocator, try dupeHeader(allocator, h));
    return out.toOwnedSlice(allocator);
}

fn dupeHeader(allocator: std.mem.Allocator, header: std.http.Header) std.mem.Allocator.Error!std.http.Header {
    const name = try allocator.dupe(u8, header.name);
    errdefer allocator.free(name);
    return .{ .name = name, .value = try allocator.dupe(u8, header.value) };
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []const std.http.Header) void {
    for (headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(headers);
}

fn freeHeaderList(allocator: std.mem.Allocator, list: *std.ArrayList(std.http.Header)) void {
    for (list.items) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    list.deinit(allocator);
}
