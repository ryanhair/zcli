//! Puts the Windows console into UTF-8 for the duration of a CLI run.
//!
//! A Windows console starts out on a legacy OEM/ANSI code page, and that code
//! page is what `ReadFile`/`WriteFile` use to translate between bytes and
//! characters. So a typed `é` comes back mangled and any UTF-8 the CLI prints
//! renders as mojibake — unless both console code pages are switched to
//! `CP_UTF8`. `enable()` does that and returns the prior code pages;
//! `restore()` puts them back so the parent shell isn't left reconfigured.
//!
//! Everything here is a no-op on non-Windows platforms (POSIX terminals are
//! already byte-transparent UTF-8), and the Win32 calls are compiled only into
//! the Windows build.

const std = @import("std");
const builtin = @import("builtin");

const UINT = std.os.windows.UINT;

/// Code page identifier for UTF-8 (see the Win32 "Code Page Identifiers" list).
const CP_UTF8: UINT = 65001;

/// The console code pages `enable()` replaced, for `restore()` to put back. A
/// field of 0 means "left unchanged" — either not Windows, no attached console,
/// or it was already UTF-8 — so `restore()` skips it.
pub const State = struct {
    prev_in: UINT = 0,
    prev_out: UINT = 0,

    /// Restore the code pages captured by `enable()`. Safe to call more than
    /// once and on any platform; only pages we actually changed are reverted.
    pub fn restore(self: State) void {
        if (builtin.os.tag == .windows) {
            if (self.prev_in != 0) _ = win.SetConsoleCP(self.prev_in);
            if (self.prev_out != 0) _ = win.SetConsoleOutputCP(self.prev_out);
        }
    }
};

/// Switch the attached console's input and output code pages to UTF-8, best
/// effort. Returns the prior code pages for `restore()`; a page is only
/// captured when the query and the switch both succeed, so a process with no
/// console (redirected to a pipe/file) leaves the returned `State` empty.
pub fn enable() State {
    if (builtin.os.tag == .windows) {
        var state: State = .{};
        const in = win.GetConsoleCP();
        if (in != 0 and in != CP_UTF8 and win.SetConsoleCP(CP_UTF8) != 0) state.prev_in = in;
        const out = win.GetConsoleOutputCP();
        if (out != 0 and out != CP_UTF8 and win.SetConsoleOutputCP(CP_UTF8) != 0) state.prev_out = out;
        return state;
    }
    return .{};
}

// Zig 0.16's `std.os.windows` exposes none of the console code-page functions,
// so declare the four needed. `GetConsole*CP` return the code page (0 if the
// process has no console); `SetConsole*CP` return a BOOL (0 on failure) — typed
// as `c_int` to match the other kernel32 externs in this repo (backend_windows)
// and to compare directly against 0, which `std.os.windows.BOOL` doesn't allow.
// Only referenced inside the Windows-gated blocks above, so this links nowhere
// else.
const win = struct {
    extern "kernel32" fn GetConsoleCP() callconv(.winapi) UINT;
    extern "kernel32" fn SetConsoleCP(wCodePageID: UINT) callconv(.winapi) c_int;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) UINT;
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: UINT) callconv(.winapi) c_int;
};
