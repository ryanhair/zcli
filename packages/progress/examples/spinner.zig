//! Spinner — indeterminate progress that animates itself.
//!
//! A spinner is for work whose total you don't know: connecting, waiting on a
//! server, resolving dependencies. On a TTY, `start` spawns a background task
//! that redraws the spinner every frame interval until you finish it — you just
//! call `setMessage` as the work moves through phases. When stdout is piped, the
//! animation never spawns and each message prints as one plain `- <message>`
//! line, so logs and CI stay readable.
//!
//! Finishing picks a themed result symbol:
//!   succeed → ✓ (success)   fail → ✗ (error)
//!   warn    → ⚠ (warning)   info → ℹ (info)
//! The result becomes a static line that flows into scrollback.

const std = @import("std");
const Progress = @import("progress");
const common = @import("common.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out: common.Io = .{};
    out.init(io);
    defer out.flush(); // buffered writer — flush before we exit

    // The import IS the type: one bundle, three constructors as methods.
    const p: Progress = .{ .writer = out.w(), .io = io, .allocator = init.gpa };

    // A `.dots` spinner (the default). `start` begins the self-animation.
    var spinner = try p.spinner(.{ .style = .dots });
    // NOTE: after `start` the spinner must not be moved or copied — the
    // background task holds a pointer to it.
    spinner.start("Connecting to registry...");
    common.sleepMs(io, 900);

    // Update the message in place; the animation keeps spinning underneath.
    spinner.setMessage("Resolving dependencies...");
    common.sleepMs(io, 900);

    spinner.setMessage("Fetching packages...");
    common.sleepMs(io, 900);

    // Finish with a success result. The spinning frame is replaced by a static
    // "✓ Installed 12 packages" line. (Alternatives: fail / warn / info / stop.)
    spinner.succeed("Installed 12 packages");
}
