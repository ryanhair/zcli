const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;

pub const meta = .{
    .description = "Deploy a service (demonstrates required options, array options, a validate hook, and a custom parse type)",
    .examples = &.{
        "deploy api --region us-east-1",
        "deploy api --region us-east-1 --tag env=prod --tag team=payments --replicas 5 --timeout 2m",
    },
    .args = .{ .name = "Service to deploy" },
    .options = .{
        // `env`: a source between struct default and CLI — reading
        // $DEPLOY_REGION satisfies the required check exactly like passing
        // `--region` would.
        .region = .{ .short = 'r', .description = "Target region", .env = "DEPLOY_REGION" },
        .tag = .{ .short = 't', .description = "key=value tag (repeatable)" },
        .replicas = .{ .description = "Number of replicas", .validate = validateReplicas },
        .timeout = .{ .description = "Deploy timeout, e.g. 30s / 5m / 1h" },
    },
};

pub const Args = struct { name: []const u8 };

pub const Options = struct {
    // No default: a required option. Help marks it `(required)`, and the
    // command never runs until it's supplied by a CLI flag, `.env`, or config.
    region: []const u8,

    // Multi-value/array option: []const []const u8 — each `--tag value` on the
    // command line appends to this slice, so `--tag a --tag b` yields
    // &.{ "a", "b" }.
    tag: []const []const u8 = &.{},

    replicas: u32 = 1,

    timeout: Duration = .{ .seconds = 30 },
};

/// Per-field `validate` hook: runs after the value is resolved from every
/// source. Returning null means valid; a returned string is the reason shown
/// to the user (a misuse — exit code 2).
fn validateReplicas(n: u32) ?[]const u8 {
    if (n == 0) return "must be at least 1";
    if (n > 100) return "must be at most 100";
    return null;
}

/// A custom `parse` type: any struct/union declaring `pub fn parse(s: []const
/// u8) !@This()` can be used as an option (or arg) field type, and the CLI,
/// env, and config sources all funnel through the same parser.
pub const Duration = struct {
    seconds: u32,

    pub fn parse(s: []const u8) !Duration {
        if (s.len < 2) return error.InvalidDuration;
        const unit = s[s.len - 1];
        const digits = s[0 .. s.len - 1];
        const n = try std.fmt.parseInt(u32, digits, 10);
        const multiplier: u32 = switch (unit) {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            else => return error.InvalidDuration,
        };
        return .{ .seconds = n * multiplier };
    }
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    const stdout = context.stdout();
    try stdout.print("Deploying '{s}' to {s} ({d} replicas, timeout {d}s)\n", .{
        args.name,
        options.region,
        options.replicas,
        options.timeout.seconds,
    });
    for (options.tag) |tag| {
        try stdout.print("  tag: {s}\n", .{tag});
    }
}

test "Duration.parse: seconds, minutes, hours" {
    try std.testing.expectEqual(@as(u32, 30), (try Duration.parse("30s")).seconds);
    try std.testing.expectEqual(@as(u32, 120), (try Duration.parse("2m")).seconds);
    try std.testing.expectEqual(@as(u32, 3600), (try Duration.parse("1h")).seconds);
}

test "Duration.parse: rejects an unknown unit" {
    try std.testing.expectError(error.InvalidDuration, Duration.parse("30x"));
}

test "validateReplicas: rejects zero and anything over 100" {
    try std.testing.expect(validateReplicas(0) != null);
    try std.testing.expect(validateReplicas(101) != null);
    try std.testing.expect(validateReplicas(1) == null);
    try std.testing.expect(validateReplicas(100) == null);
}
