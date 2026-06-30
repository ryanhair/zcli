//! POSIX terminal backend (Linux, macOS). libc-free via `std.posix`: the flag
//! words are packed structs with identical POSIX field names on Linux and
//! macOS, so there is a single path here with no `extern "c"`.

const std = @import("std");
const posix = std.posix;
const backend = @import("backend.zig");

const Handle = backend.Handle;
const Winsize = backend.Winsize;
const TerminalError = backend.TerminalError;

/// Saved terminal state for restoring after raw mode.
pub const RawMode = struct {
    fd: Handle,
    original: posix.termios,

    /// Restore original terminal settings.
    pub fn disable(self: RawMode) void {
        posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
    }
};

pub fn enableRawMode(fd: Handle) TerminalError!RawMode {
    const original = posix.tcgetattr(fd) catch return error.NotATerminal;

    // cfmakeraw() equivalent: clear the flags that cook input/output so bytes
    // arrive unmodified, one at a time, with no echo or signal handling.
    var raw = original;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cflag.PARENB = false;
    raw.cflag.CSIZE = .CS8;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    posix.tcsetattr(fd, .FLUSH, raw) catch return error.TerminalSettingsError;
    return .{ .fd = fd, .original = original };
}

pub fn setEcho(fd: Handle, enabled: bool) TerminalError!void {
    var termios = posix.tcgetattr(fd) catch return error.NotATerminal;
    termios.lflag.ECHO = enabled;
    posix.tcsetattr(fd, .FLUSH, termios) catch return error.TerminalSettingsError;
}

pub fn getWindowSize(fd: Handle) !Winsize {
    var ws: posix.winsize = undefined;
    switch (posix.errno(posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws)))) {
        .SUCCESS => return .{ .row = ws.row, .col = ws.col },
        else => return error.NotATerminal,
    }
}

/// A descriptor is a TTY iff its termios can be read — a libc-free isatty
/// (`std.posix.isatty` was removed in 0.16, and the syscall-free check is
/// exactly what isatty does under the hood).
pub fn isTty(fd: Handle) bool {
    _ = posix.tcgetattr(fd) catch return false;
    return true;
}

pub fn waitReadable(fd: Handle, timeout_ms: i32) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, timeout_ms) catch return false;
    return n > 0;
}
