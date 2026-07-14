const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Authorize this CLI via GitHub's OAuth device flow (RFC 8628)",
    .examples = &.{"login"},
};

pub const Args = struct {};
pub const Options = struct {};

// GitHub's device-flow endpoints. Another provider is the same shape with three
// different URLs and a different client_id — the flow below doesn't change.
const device_code_url = "https://github.com/login/device/code";
const token_url = "https://github.com/login/oauth/access_token";
const grant_type = "urn:ietf:params:oauth:grant-type:device_code";

/// The fields we read from the device-code response (RFC 8628 §3.2). Unknown
/// fields (`verification_uri_complete`, …) are ignored by `Response.json`.
const DeviceCode = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    expires_in: u32,
    interval: u32 = 5,
};

/// The token endpoint returns EITHER a success (`access_token`) OR a pending/
/// terminal `error` (RFC 8628 §3.5). Model both as optionals and branch on
/// which one arrived.
const TokenResponse = struct {
    access_token: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// What one poll of the token endpoint tells us to do next. This is the part of
/// a device flow that's easy to get subtly wrong — so it's a pure function with
/// a unit test, not buried in the polling loop.
const PollOutcome = enum { keep_waiting, slow_down, denied, expired, unknown_error };

fn classifyError(err: []const u8) PollOutcome {
    if (std.mem.eql(u8, err, "authorization_pending")) return .keep_waiting;
    if (std.mem.eql(u8, err, "slow_down")) return .slow_down;
    if (std.mem.eql(u8, err, "access_denied")) return .denied;
    if (std.mem.eql(u8, err, "expired_token")) return .expired;
    return .unknown_error;
}

pub fn execute(_: Args, _: Options, context: *Context) !void {
    const io = context.io;
    const stdout = context.stdout();

    // The client_id identifies your OAuth app; it isn't a secret (it ships in
    // every copy of the client), so reading it from the environment is fine.
    // Register an app with device flow enabled at github.com/settings/developers.
    const client_id = context.environ.get("GITHUB_CLIENT_ID") orelse
        return context.fail("Set GITHUB_CLIENT_ID to your GitHub OAuth app's client ID.", .{});

    var client = zcli.http.Client.init(context.allocator, io, .{});
    defer client.deinit();

    // 1. Ask GitHub for a device code plus a short user code (RFC 8628 §3.1–3.2).
    const device = try requestDeviceCode(&client, context, client_id);

    // 2. Send the user off to authorize (§3.3). Flush so they actually SEE the
    //    code before we block on polling — the stdout writer is buffered.
    try stdout.print(
        \\To authorize, open:
        \\
        \\    {s}
        \\
        \\and enter the code:  {s}
        \\
        \\Waiting for you to authorize…
        \\
    , .{ device.verification_uri, device.user_code });
    try stdout.flush();

    // 3. Poll the token endpoint until the user finishes, denies, or it expires.
    const token = try pollForToken(&client, context, io, client_id, device);

    // 4. The flow produced an opaque credential; `zcli_secrets` stashes it in
    //    the OS keychain — never a plaintext file. From here it's identical to
    //    the token `ghauth` pastes: the plugin doesn't care how it was minted.
    try context.plugins.zcli_secrets.set("token", token);

    try stdout.print("\nAuthorized. Try `oauth-device whoami`.\n", .{});
}

/// POST the client_id and get back a device code, a user code, and where to
/// enter it. Copies the fields we keep out of the response body before it's freed.
fn requestDeviceCode(
    client: *zcli.http.Client,
    context: *Context,
    client_id: []const u8,
) !DeviceCode {
    const arena = context.allocator;

    // No `scope`: a scopeless GitHub token can still read `GET /user` (the public
    // profile), which is all `whoami` needs — and it keeps this form body free of
    // characters that would otherwise need URL-encoding.
    const body = try std.fmt.allocPrint(arena, "client_id={s}", .{client_id});

    var response = try client.post(device_code_url, .{
        .body = body,
        .content_type = "application/x-www-form-urlencoded",
        .headers = &.{.{ .name = "Accept", .value = "application/json" }},
    });
    defer response.deinit();

    if (response.status != .ok) {
        return context.fail(
            "GitHub rejected the device-code request ({d}). Is GITHUB_CLIENT_ID an OAuth app with device flow enabled?",
            .{@intFromEnum(response.status)},
        );
    }

    const d = (try response.json(DeviceCode, arena)).value;
    // `response.json` may reference `response.body`, which the defer above frees
    // when this function returns — so copy everything that outlives it.
    return .{
        .device_code = try arena.dupe(u8, d.device_code),
        .user_code = try arena.dupe(u8, d.user_code),
        .verification_uri = try arena.dupe(u8, d.verification_uri),
        .expires_in = d.expires_in,
        .interval = d.interval,
    };
}

/// Poll the token endpoint on the server-mandated interval until it hands back a
/// token or a terminal condition ends the flow (RFC 8628 §3.4–3.5).
fn pollForToken(
    client: *zcli.http.Client,
    context: *Context,
    io: std.Io,
    client_id: []const u8,
    device: DeviceCode,
) ![]const u8 {
    const arena = context.allocator;

    const body = try std.fmt.allocPrint(
        arena,
        "client_id={s}&device_code={s}&grant_type={s}",
        .{ client_id, device.device_code, grant_type },
    );

    var interval: u32 = device.interval;
    var elapsed: u32 = 0;
    while (elapsed < device.expires_in) {
        // Wait the mandated interval before each poll; polling faster earns a
        // `slow_down` (RFC 8628 §3.5).
        try io.sleep(.fromSeconds(interval), .awake);
        elapsed += interval;

        var response = try client.post(token_url, .{
            .body = body,
            .content_type = "application/x-www-form-urlencoded",
            .headers = &.{.{ .name = "Accept", .value = "application/json" }},
        });
        defer response.deinit();

        const result = (try response.json(TokenResponse, arena)).value;
        if (result.access_token) |token| {
            // Copy it out: the body this may reference is freed by the defer above.
            return arena.dupe(u8, token);
        }

        const err = result.@"error" orelse
            return context.fail("The token endpoint returned neither a token nor an error.", .{});
        switch (classifyError(err)) {
            .keep_waiting => {},
            .slow_down => interval += 5, // back off and keep polling
            .denied => return context.fail("You denied the authorization request.", .{}),
            .expired => return context.fail("The code expired before you authorized. Run `login` again.", .{}),
            .unknown_error => return context.fail("GitHub returned an OAuth error: {s}", .{err}),
        }
    }
    return context.fail("Timed out waiting for authorization. Run `login` again.", .{});
}

test "classifyError maps the RFC 8628 token-endpoint responses" {
    try std.testing.expectEqual(PollOutcome.keep_waiting, classifyError("authorization_pending"));
    try std.testing.expectEqual(PollOutcome.slow_down, classifyError("slow_down"));
    try std.testing.expectEqual(PollOutcome.denied, classifyError("access_denied"));
    try std.testing.expectEqual(PollOutcome.expired, classifyError("expired_token"));
    try std.testing.expectEqual(PollOutcome.unknown_error, classifyError("nonsense"));
}
