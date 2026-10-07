const std = @import("std");
const zcli = @import("zcli");
pub const Duration = @import("deployment").Duration;
const Zone = @import("deployment").Zone;
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
        .zone = .{ .short = 'z', .description = "Deployment zones (repeatable)", .env = "DEPLOY_ZONES", .delimiter = ',' },
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

    zone: []const Zone = &.{},

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

pub fn execute(args: Args, options: Options, context: *Context) !void {
    const stdout = context.stdout();
    try stdout.print("Deploying '{s}' to {s} ({d} replicas, timeout {d}s)\n", .{
        args.name,
        options.region,
        options.replicas,
        options.timeout.seconds,
    });
    for (options.zone) |zone| try stdout.print("  zone: {s}\n", .{@tagName(zone)});
    for (options.tag) |tag| {
        try stdout.print("  tag: {s}\n", .{tag});
    }
}

test "validateReplicas: rejects zero and anything over 100" {
    try std.testing.expect(validateReplicas(0) != null);
    try std.testing.expect(validateReplicas(101) != null);
    try std.testing.expect(validateReplicas(1) == null);
    try std.testing.expect(validateReplicas(100) == null);
}
