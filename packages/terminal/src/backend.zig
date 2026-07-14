//! Platform selection for the terminal primitives that need OS support:
//! raw mode, echo control, window size, TTY detection, and the input poll used
//! to disambiguate a lone Escape from an escape sequence.
//!
//! The POSIX and Windows backends expose an identical surface, re-exported
//! below, so callers (and the rest of this package) stay platform-agnostic.

const std = @import("std");
const builtin = @import("builtin");

/// An OS handle for a terminal stream (stdin/stdout). This is `windows.HANDLE`
/// on Windows and a file descriptor elsewhere.
pub const Handle = std.Io.File.Handle;

pub const TerminalError = error{
    NotATerminal,
    TerminalSettingsError,
};

/// Terminal window dimensions in character cells.
pub const Winsize = struct {
    row: u16,
    col: u16,
};

const impl = if (builtin.os.tag == .windows)
    @import("backend_windows.zig")
else
    @import("backend_posix.zig");

/// Saved terminal state for restoring after raw mode. Opaque and
/// platform-specific; restore the original settings via `disable()`.
pub const RawMode = impl.RawMode;

/// Enable raw mode on `handle` (typically stdin). Returns a `RawMode` that must
/// be used to restore the original settings.
pub const enableRawMode = impl.enableRawMode;

/// Enable or disable terminal echo (for password input) on `handle`.
pub const setEcho = impl.setEcho;

/// Query the terminal window size for `handle`.
pub const getWindowSize = impl.getWindowSize;

/// Whether `handle` refers to a terminal/console.
pub const isTty = impl.isTty;

/// Wait up to `timeout_ms` for `handle` to have input ready to read. Returns
/// false on timeout or error. A negative timeout blocks indefinitely.
pub const waitReadable = impl.waitReadable;

/// Watches for terminal-resize events and multiplexes them with stdin
/// readiness. Construct with `init()` for the duration of an interactive
/// prompt, `deinit()` when done, and drive it via `wait(handle)`.
pub const ResizeWatcher = impl.ResizeWatcher;

/// Result of `ResizeWatcher.wait`: either input is ready or a resize occurred.
pub const InputWait = impl.InputWait;

/// Result of `ResizeWatcher.waitTimeout`: input ready, a resize, or the
/// caller's deadline elapsed with neither.
pub const WaitResult = impl.WaitResult;

test {
    // Pull in the active platform backend's unit tests (the impl is imported
    // via a comptime branch, so nothing else references its file for tests).
    _ = impl;
}

test "re-exported surface resolves on this platform" {
    // Referencing each re-export forces the (lazily analyzed) platform impl
    // to provide the full surface with the expected shape.
    try std.testing.expect(@hasDecl(RawMode, "disable"));
    try std.testing.expect(@typeInfo(@TypeOf(enableRawMode)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(setEcho)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(getWindowSize)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(isTty)) == .@"fn");
    try std.testing.expect(@typeInfo(@TypeOf(waitReadable)) == .@"fn");
    try std.testing.expect(@hasDecl(ResizeWatcher, "init"));
    try std.testing.expect(@hasDecl(ResizeWatcher, "deinit"));
    try std.testing.expect(@hasDecl(ResizeWatcher, "wait"));
    try std.testing.expect(@hasDecl(ResizeWatcher, "waitTimeout"));
    // Both watcher result enums cover the same cases on every platform.
    try std.testing.expect(@hasField(InputWait, "input") and @hasField(InputWait, "resize"));
    try std.testing.expect(@hasField(WaitResult, "input") and @hasField(WaitResult, "resize") and @hasField(WaitResult, "timeout"));
}
