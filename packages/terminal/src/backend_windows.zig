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

pub fn enableRawMode(in: Handle) TerminalError!RawMode {
    var in_mode: DWORD = 0;
    if (GetConsoleMode(in, &in_mode) == 0) return error.NotATerminal;

    // Output VT processing so the prompt's ANSI (cursor, colors) renders. The
    // output handle may not be a console (redirected), so this is best-effort.
    const out = std.Io.File.stdout().handle;
    var out_mode: DWORD = 0;
    const out_is_console = GetConsoleMode(out, &out_mode) != 0;

    var raw_in = in_mode;
    raw_in &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
    raw_in |= ENABLE_VIRTUAL_TERMINAL_INPUT;
    if (SetConsoleMode(in, raw_in) == 0) return error.TerminalSettingsError;

    if (out_is_console) {
        _ = SetConsoleMode(out, out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING | ENABLE_PROCESSED_OUTPUT);
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
    if (enabled) {
        mode |= ENABLE_ECHO_INPUT;
    } else {
        mode &= ~ENABLE_ECHO_INPUT;
    }
    if (SetConsoleMode(handle, mode) == 0) return error.TerminalSettingsError;
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
