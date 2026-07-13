//! Shared stdout wiring for the theme examples.
//!
//! Every example is a self-contained `main` that renders styled text to
//! stdout. All that really needs is a buffered writer built from the process
//! `std.Io` — this keeps each example file focused on the theme concept it
//! demonstrates.
//!
//! Writers are buffered in Zig 0.16, so `flush()` (deferred by every example)
//! is what actually pushes bytes to the terminal.

const std = @import("std");

pub const Out = struct {
    stdout: std.Io.File.Writer = undefined,
    buf: [8192]u8 = undefined,

    /// Initialise in place. Holds the buffer by value, so take a pointer —
    /// don't copy an `Out` after calling this.
    pub fn init(self: *Out, io: std.Io) void {
        self.stdout = std.Io.File.stdout().writer(io, &self.buf);
    }

    pub fn w(self: *Out) *std.Io.Writer {
        return &self.stdout.interface;
    }

    pub fn flush(self: *Out) void {
        self.stdout.interface.flush() catch {};
    }
};
