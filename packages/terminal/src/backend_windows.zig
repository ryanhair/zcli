//! Windows terminal backend (Windows 10 1511+ / Windows Terminal / modern
//! conhost). Raw mode is done with the console-mode API rather than termios.
//!
//! The key enabler is virtual-terminal mode: with `ENABLE_VIRTUAL_TERMINAL_INPUT`
//! the console delivers the same ANSI escape sequences for arrow keys etc. that
//! POSIX terminals send, so all of `key.zig`'s escape-sequence parsing is reused
//! unchanged. `ENABLE_VIRTUAL_TERMINAL_PROCESSING` does the same for output, so
//! the package's ANSI/color sequences render correctly.
//!
//! Zig 0.16's `std.os.windows` does not expose these console functions, so the
//! handful needed are declared below.

const std = @import("std");
const windows = std.os.windows;
const backend = @import("backend.zig");

const Handle = backend.Handle;
const Winsize = backend.Winsize;
const TerminalError = backend.TerminalError;

const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
const SHORT = windows.SHORT;
const COORD = windows.COORD;

// Console input mode flags.
const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
const ENABLE_LINE_INPUT: DWORD = 0x0002;
const ENABLE_ECHO_INPUT: DWORD = 0x0004;
const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;

// Console output mode flags.
const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

const WAIT_OBJECT_0: DWORD = 0x00000000;
const INFINITE: DWORD = 0xFFFFFFFF;

// Console input-record plumbing, used only to drain non-key records that keep
// the stdin handle signaled without providing VT bytes (#394). The union body
// is opaque — only `EventType` is inspected; KEY_EVENT_RECORD (16 bytes) is
// the largest member, so the record is 20 bytes like the Win32 original.
const KEY_EVENT_TYPE: u16 = 0x0001;
const INPUT_RECORD = extern struct {
    EventType: u16,
    _pad: u16 = 0,
    Event: [16]u8,
};

const SMALL_RECT = extern struct {
    Left: SHORT,
    Top: SHORT,
    Right: SHORT,
    Bottom: SHORT,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) c_int;
extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) c_int;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn PeekConsoleInputW(hConsoleInput: HANDLE, lpBuffer: [*]INPUT_RECORD, nLength: DWORD, lpNumberOfEventsRead: *DWORD) callconv(.winapi) c_int;
extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: [*]INPUT_RECORD, nLength: DWORD, lpNumberOfEventsRead: *DWORD) callconv(.winapi) c_int;

/// Saved console state for restoring after raw mode. Raw mode touches both the
/// input handle (to stop line buffering/echo and turn on VT input) and the
/// output handle (to turn on VT processing), so both are restored on `disable()`.
pub const RawMode = struct {
    in: Handle,
    in_mode: DWORD,
    out: Handle,
    out_mode: DWORD,
    out_changed: bool,

    /// Restore original console settings.
    pub fn disable(self: RawMode) void {
        _ = SetConsoleMode(self.in, self.in_mode);
        if (self.out_changed) _ = SetConsoleMode(self.out, self.out_mode);
    }
};

/// Given the input console's current mode, compute the raw-mode input flags
/// to install: line buffering/echo/processed-input off, VT input on so
/// `key.zig`'s escape-sequence parsing sees the same bytes as a POSIX tty.
/// Pure (no syscalls) — testable without a console.
fn rawInputMode(in_mode: DWORD) DWORD {
    var raw_in = in_mode;
    raw_in &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
    raw_in |= ENABLE_VIRTUAL_TERMINAL_INPUT;
    return raw_in;
}

/// Given the output console's current mode, compute the mode with VT
/// processing enabled so the package's ANSI (cursor, color) sequences render.
/// Pure.
fn vtOutputMode(out_mode: DWORD) DWORD {
    return out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING | ENABLE_PROCESSED_OUTPUT;
}

/// Given the console's current mode, compute the mode with echo set to
/// `enabled` and everything else untouched. Pure.
fn echoMode(mode: DWORD, enabled: bool) DWORD {
    return if (enabled) mode | ENABLE_ECHO_INPUT else mode & ~ENABLE_ECHO_INPUT;
}

pub fn enableRawMode(in: Handle) TerminalError!RawMode {
    var in_mode: DWORD = 0;
    if (GetConsoleMode(in, &in_mode) == 0) return error.NotATerminal;

    // Output VT processing so the prompt's ANSI (cursor, colors) renders. The
    // output handle may not be a console (redirected), so this is best-effort.
    const out = std.Io.File.stdout().handle;
    var out_mode: DWORD = 0;
    const out_is_console = GetConsoleMode(out, &out_mode) != 0;

    if (SetConsoleMode(in, rawInputMode(in_mode)) == 0) return error.TerminalSettingsError;

    if (out_is_console) {
        _ = SetConsoleMode(out, vtOutputMode(out_mode));
    }

    return .{
        .in = in,
        .in_mode = in_mode,
        .out = out,
        .out_mode = out_mode,
        .out_changed = out_is_console,
    };
}

pub fn setEcho(handle: Handle, enabled: bool) TerminalError!void {
    var mode: DWORD = 0;
    if (GetConsoleMode(handle, &mode) == 0) return error.NotATerminal;
    if (SetConsoleMode(handle, echoMode(mode, enabled)) == 0) return error.TerminalSettingsError;
}

pub fn getWindowSize(handle: Handle) !Winsize {
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (GetConsoleScreenBufferInfo(handle, &info) == 0) return error.NotATerminal;
    // The visible window, not the (often larger) scrollback buffer.
    const cols = info.srWindow.Right - info.srWindow.Left + 1;
    const rows = info.srWindow.Bottom - info.srWindow.Top + 1;
    return .{ .row = @intCast(rows), .col = @intCast(cols) };
}

/// A handle is a console iff its console mode can be queried — the Windows
/// analogue of the termios-based isatty check.
pub fn isTty(handle: Handle) bool {
    var mode: DWORD = 0;
    return GetConsoleMode(handle, &mode) != 0;
}

pub fn waitReadable(handle: Handle, timeout_ms: i32) bool {
    const ms: DWORD = if (timeout_ms < 0) INFINITE else @intCast(timeout_ms);
    return WaitForSingleObject(handle, ms) == WAIT_OBJECT_0;
}

/// Whether a `wait` returned because input is ready or the terminal resized.
pub const InputWait = enum { input, resize };

/// Result of `waitTimeout`: input ready, a resize, or the caller's deadline
/// elapsed with neither.
pub const WaitResult = enum { input, resize, timeout };

/// How often `wait` re-checks the window size while blocked on input. With
/// `ENABLE_VIRTUAL_TERMINAL_INPUT`, resize events are not delivered through the
/// byte stream (`ReadFile`), so rather than rewire input reading to consume
/// console records — which would risk the VT byte path — we poll the size on a
/// short interval. ~60ms is imperceptible for a resize repaint.
const resize_poll_ms: i32 = 60;

/// Watches for console-window resizes and multiplexes them with input
/// readiness. Detects resize by polling `getWindowSize` on the output handle,
/// which keeps the input-reading path (VT byte stream via `ReadFile`) untouched.
pub const ResizeWatcher = struct {
    out: Handle,
    last: Winsize,

    pub fn init() ResizeWatcher {
        const out = std.Io.File.stdout().handle;
        return .{ .out = out, .last = getWindowSize(out) catch .{ .row = 0, .col = 0 } };
    }

    pub fn deinit(self: *ResizeWatcher) void {
        _ = self;
    }

    /// Block until stdin (`handle`) has input or the console window resizes.
    pub fn wait(self: *ResizeWatcher, handle: Handle) InputWait {
        return switch (self.waitTimeout(handle, null)) {
            .input => .input,
            .resize => .resize,
            .timeout => unreachable, // a null timeout never expires
        };
    }

    /// Like `wait`, but return `.timeout` if neither input nor a resize
    /// arrives within `timeout_ms`. `null` blocks indefinitely (never
    /// returns `.timeout`). A finite timeout lets a full-screen loop repaint
    /// on a tick with no input; the size poll runs at most one
    /// `resize_poll_ms` interval past the deadline.
    pub fn waitTimeout(self: *ResizeWatcher, handle: Handle, timeout_ms: ?u32) WaitResult {
        var remaining: ?u32 = timeout_ms;
        while (true) {
            const wait_ms: DWORD = if (remaining) |r| blk: {
                if (r == 0) return .timeout;
                break :blk @intCast(@min(r, @as(u32, @intCast(resize_poll_ms))));
            } else @intCast(resize_poll_ms);

            const ready = WaitForSingleObject(handle, wait_ms) == WAIT_OBJECT_0;
            const sz = getWindowSize(self.out) catch self.last;
            if (sz.row != self.last.row or sz.col != self.last.col) {
                self.last = sz;
                return .resize;
            }
            if (ready and drainedToRealInput(handle)) return .input;
            if (remaining) |*r| r.* -|= wait_ms;
        }
    }
};

/// A signaled console input handle does not guarantee `ReadFile` will yield
/// bytes: non-key records — the WINDOW_BUFFER_SIZE_EVENT a resize queues (we
/// detect resizes by polling the *output* size and never consume the record),
/// focus and menu events — keep the handle signaled while producing no VT
/// input. Returning `.input` on those sends the caller into a blocking
/// `ReadFile` with nothing to read, starving ticks until a real key arrives
/// (#394). Peek the queue: leading non-key records are consumed (via
/// `ReadConsoleInputW`, which never touches key records here, so the VT byte
/// path is unaffected); report ready only when a KEY_EVENT is queued or the
/// handle is not a console at all (a pipe — readiness there means bytes).
fn drainedToRealInput(handle: Handle) bool {
    var records: [16]INPUT_RECORD = undefined;
    var n: DWORD = 0;
    if (PeekConsoleInputW(handle, &records, records.len, &n) == 0) return true; // not a console
    if (n == 0) return false; // spurious wake — nothing queued
    var leading_non_key: DWORD = 0;
    for (records[0..n]) |rec| {
        if (rec.EventType == KEY_EVENT_TYPE) break;
        leading_non_key += 1;
    }
    if (leading_non_key == 0) return true; // a key is first in the queue
    var discarded: DWORD = 0;
    _ = ReadConsoleInputW(handle, &records, leading_non_key, &discarded);
    // A key behind the drained records means the handle is still genuinely
    // ready; an all-non-key queue means keep waiting.
    return leading_non_key < n;
}

test "rawInputMode clears line/echo/processed-input and sets VT input" {
    const cooked: DWORD = ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT;
    const raw = rawInputMode(cooked);

    try std.testing.expect(raw & ENABLE_LINE_INPUT == 0);
    try std.testing.expect(raw & ENABLE_ECHO_INPUT == 0);
    try std.testing.expect(raw & ENABLE_PROCESSED_INPUT == 0);
    try std.testing.expect(raw & ENABLE_VIRTUAL_TERMINAL_INPUT != 0);
}

test "rawInputMode preserves bits it doesn't touch" {
    const extra_bit: DWORD = 0x0100;
    const raw = rawInputMode(extra_bit);
    try std.testing.expect(raw & extra_bit != 0);
}

test "vtOutputMode sets VT processing and processed output" {
    const mode = vtOutputMode(0);
    try std.testing.expect(mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING != 0);
    try std.testing.expect(mode & ENABLE_PROCESSED_OUTPUT != 0);
}

test "echoMode toggles ENABLE_ECHO_INPUT without touching other bits" {
    const base: DWORD = ENABLE_LINE_INPUT;

    const disabled = echoMode(base | ENABLE_ECHO_INPUT, false);
    try std.testing.expect(disabled & ENABLE_ECHO_INPUT == 0);
    try std.testing.expect(disabled & ENABLE_LINE_INPUT != 0);

    const enabled = echoMode(base, true);
    try std.testing.expect(enabled & ENABLE_ECHO_INPUT != 0);
    try std.testing.expect(enabled & ENABLE_LINE_INPUT != 0);
}
