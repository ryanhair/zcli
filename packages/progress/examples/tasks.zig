//! Multi-step task flow — spinners and a bar in one realistic command.
//!
//! Real CLIs mix indicators: a spinner for the indeterminate "reach out and
//! wait" phases, and a bar for the one phase whose total is known. Each finished
//! indicator emits a static result line, so the transcript reads top-to-bottom
//! like a build log while only the active indicator animates in place.
//!
//! This mirrors what a `deploy`-style command looks like end to end.

const std = @import("std");
const Progress = @import("progress");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out: common.Io = .{};
    out.init(io);
    defer out.flush();

    const p: Progress = .{ .writer = out.w(), .io = io, .allocator = init.gpa };

    try out.w().print("Deploying acme-web to production\n", .{});

    // Step 1 — indeterminate: authenticate (spinner).
    var auth = try p.spinner(.{ .style = .dots });
    auth.start("Authenticating...");
    common.sleepMs(io, 800);
    auth.succeed("Authenticated as ci-bot");

    // Step 2 — determinate: upload N build artifacts (bar with rate + ETA).
    const artifacts: usize = 24;
    var upload = try p.progressBar(.{
        .total = artifacts,
        .width = 28,
        .prefix = "Uploading ",
        .show_eta = true,
        .show_rate = true,
    });
    for (0..artifacts) |i| {
        common.sleepMs(io, 60);
        upload.update(i + 1, null);
    }
    upload.finishWithMessage("Uploaded 24 artifacts");

    // Step 3 — indeterminate: wait for the health check, which fails over to a
    // warning (demonstrates a non-success finish mid-flow).
    var health = try p.spinner(.{ .style = .line });
    health.start("Waiting for health check...");
    common.sleepMs(io, 900);
    health.warn("1 of 3 replicas slow to start");

    // Step 4 — indeterminate: finalize, ending on success.
    var finalize = try p.spinner(.{ .style = .arrow });
    finalize.start("Swapping traffic...");
    common.sleepMs(io, 800);
    finalize.succeed("Deploy live");

    try out.w().print("\nDone in ~4s.\n", .{});
}
