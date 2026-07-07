//! Shared stdin/stdout wiring for the prompts examples.
//!
//! The interactive prompts take any writer/reader, so all a real program needs
//! is a buffered writer over stdout and a reader over stdin, both built from the
//! process `std.Io`. This keeps each example file focused on the prompt itself.

const std = @import("std");

pub const Io = struct {
    stdout: std.Io.File.Writer = undefined,
    stdin: std.Io.File.Reader = undefined,
    out_buf: [4096]u8 = undefined,
    in_buf: [4096]u8 = undefined,

    /// Initialise in place. Holds buffers by value, so don't copy an `Io` after
    /// calling this — take a pointer.
    pub fn init(self: *Io, io: std.Io) void {
        self.stdout = std.Io.File.stdout().writer(io, &self.out_buf);
        self.stdin = std.Io.File.stdin().reader(io, &self.in_buf);
    }

    pub fn w(self: *Io) *std.Io.Writer {
        return &self.stdout.interface;
    }

    pub fn r(self: *Io) *std.Io.Reader {
        return &self.stdin.interface;
    }

    pub fn flush(self: *Io) void {
        self.stdout.interface.flush() catch {};
    }
};
