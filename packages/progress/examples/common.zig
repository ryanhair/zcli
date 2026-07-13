//! Shared stdout wiring for the progress examples.
//!
//! A standalone `Progress` bundle needs a `writer`, an `io`, an `allocator`,
//! and (optionally) a `theme`. Every example builds the same buffered stdout
//! writer from the process `std.Io`, so this helper keeps each example file
//! focused on the indicator it demonstrates.
//!
//! IMPORTANT (Zig 0.16): the stdout writer is buffered, and finishing an
//! indicator does not flush the process writer for you. Always `flush()` before
//! `main` returns or the last frame/result line can be lost.

const std = @import("std");

pub const Io = struct {
    stdout: std.Io.File.Writer = undefined,
    buf: [16384]u8 = undefined,

    /// Initialise in place. Holds the buffer by value, so take a pointer — don't
    /// copy an `Io` after calling this.
    pub fn init(self: *Io, io: std.Io) void {
        self.stdout = std.Io.File.stdout().writer(io, &self.buf);
    }

    pub fn w(self: *Io) *std.Io.Writer {
        return &self.stdout.interface;
    }

    pub fn flush(self: *Io) void {
        self.stdout.interface.flush() catch {};
    }
};

/// Sleep for `ms` milliseconds — examples simulate real work so the animation
/// has something to show. Errors (e.g. a cancelled sleep) are ignored: a demo
/// that can't sleep just runs faster.
pub fn sleepMs(io: std.Io, ms: u64) void {
    io.sleep(.{ .nanoseconds = ms * std.time.ns_per_ms }, .awake) catch {};
}
