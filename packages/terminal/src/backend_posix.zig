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

/// cfmakeraw() equivalent: given the terminal's current mode, compute the
/// termios to install for raw mode — clears the flags that cook input/output
/// so bytes arrive unmodified, one at a time, with no echo or signal handling.
/// Pure (no syscalls), so it's testable without a TTY.
fn rawTermios(original: posix.termios) posix.termios {
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
    return raw;
}

/// Given the terminal's current mode, compute the termios with echo set to
/// `enabled` and everything else untouched. Pure — testable without a TTY.
fn echoTermios(termios: posix.termios, enabled: bool) posix.termios {
    var t = termios;
    t.lflag.ECHO = enabled;
    return t;
}

pub fn enableRawMode(fd: Handle) TerminalError!RawMode {
    const original = posix.tcgetattr(fd) catch return error.NotATerminal;
    const raw = rawTermios(original);
    posix.tcsetattr(fd, .FLUSH, raw) catch return error.TerminalSettingsError;
    return .{ .fd = fd, .original = original };
}

pub fn setEcho(fd: Handle, enabled: bool) TerminalError!void {
    const termios = posix.tcgetattr(fd) catch return error.NotATerminal;
    const updated = echoTermios(termios, enabled);
    posix.tcsetattr(fd, .FLUSH, updated) catch return error.TerminalSettingsError;
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
/// exactly what isatty does under the hood). We call the syscall directly
/// rather than `posix.tcgetattr` so that a non-terminal fd (e.g. /dev/null,
/// which reports ENODEV on Darwin) simply returns false instead of routing
/// through `unexpectedErrno`, which dumps a stack trace in debug builds.
pub fn isTty(fd: Handle) bool {
    var term: posix.termios = undefined;
    return switch (posix.errno(posix.system.tcgetattr(fd, &term))) {
        .SUCCESS => true,
        else => false,
    };
}

pub fn waitReadable(fd: Handle, timeout_ms: i32) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, timeout_ms) catch return false;
    return n > 0;
}

/// Whether a `wait` returned because input is ready or the terminal resized.
pub const InputWait = enum { input, resize };

/// Result of `waitTimeout`: input ready, a resize, or the caller's deadline
/// elapsed with neither.
pub const WaitResult = enum { input, resize, timeout };

/// Backstop poll interval. A SIGWINCH interrupts the poll (EINTR) and is caught
/// immediately; this only bounds the tiny race where the signal lands between
/// the flag check and the poll entering the kernel — at worst that resize is
/// noticed one interval later, which is imperceptible.
const poll_backstop_ms: i32 = 100;

/// Set by the SIGWINCH handler, drained by the watcher. Process-global because
/// signal handlers can't carry context; only one `ResizeWatcher` is active at a
/// time (interactive prompts are modal), which this assumes.
var resize_pending = std.atomic.Value(bool).init(false);

fn handleSigwinch(_: posix.SIG) callconv(.c) void {
    resize_pending.store(true, .seq_cst);
}

/// Watches for terminal-resize (SIGWINCH) events and multiplexes them with
/// stdin readiness. The handler sets an atomic flag and interrupts the poll;
/// `wait` checks the flag on every wakeup (signal, input, or the backstop
/// timeout), so a resize is reported promptly whether or not stdin has input.
pub const ResizeWatcher = struct {
    old_action: posix.Sigaction,

    pub fn init() ResizeWatcher {
        resize_pending.store(false, .seq_cst);
        var act = posix.Sigaction{
            .handler = .{ .handler = handleSigwinch },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        var old_action: posix.Sigaction = undefined;
        posix.sigaction(posix.SIG.WINCH, &act, &old_action);
        return .{ .old_action = old_action };
    }

    pub fn deinit(self: *ResizeWatcher) void {
        posix.sigaction(posix.SIG.WINCH, &self.old_action, null);
    }

    /// Block until stdin (`fd`) has input or the terminal is resized. Uses the
    /// raw `poll` (not `std.posix.poll`, which retries EINTR internally and
    /// would hide the SIGWINCH wakeup).
    pub fn wait(self: *ResizeWatcher, fd: Handle) InputWait {
        return switch (self.waitTimeout(fd, null)) {
            .input => .input,
            .resize => .resize,
            .timeout => unreachable, // a null timeout never expires
        };
    }

    /// Like `wait`, but return `.timeout` if neither input nor a resize
    /// arrives within `timeout_ms`. `null` blocks indefinitely (never
    /// returns `.timeout`) — the classic prompt behavior. A finite timeout is
    /// what lets a full-screen loop repaint on a tick with no input.
    ///
    /// The deadline is honored one backstop interval at a time: each poll
    /// waits at most `poll_backstop_ms` so a SIGWINCH that raced the poll is
    /// noticed promptly, and the remaining budget is decremented by the
    /// interval actually waited.
    pub fn waitTimeout(self: *ResizeWatcher, fd: Handle, timeout_ms: ?u32) WaitResult {
        _ = self;
        var remaining: ?u32 = timeout_ms;
        while (true) {
            if (resize_pending.swap(false, .seq_cst)) return .resize;

            const wait_ms: i32 = if (remaining) |r| blk: {
                if (r == 0) return .timeout;
                break :blk @intCast(@min(r, @as(u32, poll_backstop_ms)));
            } else poll_backstop_ms;

            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
            const rc = posix.system.poll(&fds, 1, wait_ms);
            if (resize_pending.swap(false, .seq_cst)) return .resize;
            switch (posix.errno(rc)) {
                .SUCCESS => if (rc > 0 and fds[0].revents & posix.POLL.IN != 0) return .input,
                else => {}, // EINTR / EAGAIN — loop and re-check the flag
            }
            if (remaining) |*r| r.* -|= @intCast(wait_ms);
        }
    }
};

test "rawTermios clears cooked-mode flags and sets CS8 + VMIN/VTIME" {
    var original = std.mem.zeroes(posix.termios);
    original.iflag.BRKINT = true;
    original.iflag.ICRNL = true;
    original.iflag.INPCK = true;
    original.iflag.ISTRIP = true;
    original.iflag.IXON = true;
    original.oflag.OPOST = true;
    original.lflag.ECHO = true;
    original.lflag.ICANON = true;
    original.lflag.IEXTEN = true;
    original.lflag.ISIG = true;
    original.cflag.PARENB = true;

    const raw = rawTermios(original);

    try std.testing.expect(!raw.iflag.BRKINT);
    try std.testing.expect(!raw.iflag.ICRNL);
    try std.testing.expect(!raw.iflag.INPCK);
    try std.testing.expect(!raw.iflag.ISTRIP);
    try std.testing.expect(!raw.iflag.IXON);
    try std.testing.expect(!raw.oflag.OPOST);
    try std.testing.expect(!raw.lflag.ECHO);
    try std.testing.expect(!raw.lflag.ICANON);
    try std.testing.expect(!raw.lflag.IEXTEN);
    try std.testing.expect(!raw.lflag.ISIG);
    try std.testing.expect(!raw.cflag.PARENB);
    try std.testing.expectEqual(posix.CSIZE.CS8, raw.cflag.CSIZE);
    try std.testing.expectEqual(@as(posix.cc_t, 1), raw.cc[@intFromEnum(posix.V.MIN)]);
    try std.testing.expectEqual(@as(posix.cc_t, 0), raw.cc[@intFromEnum(posix.V.TIME)]);
}

test "rawTermios leaves untouched flags alone" {
    var original = std.mem.zeroes(posix.termios);
    original.iflag.IXOFF = true; // not part of the raw-mode transform

    const raw = rawTermios(original);

    try std.testing.expect(raw.iflag.IXOFF);
}

test "echoTermios toggles ECHO without touching other flags" {
    var termios = std.mem.zeroes(posix.termios);
    termios.lflag.ICANON = true;

    const disabled = echoTermios(termios, false);
    try std.testing.expect(!disabled.lflag.ECHO);
    try std.testing.expect(disabled.lflag.ICANON);

    const enabled = echoTermios(termios, true);
    try std.testing.expect(enabled.lflag.ECHO);
    try std.testing.expect(enabled.lflag.ICANON);
}
