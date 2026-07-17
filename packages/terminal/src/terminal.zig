//! Cross-platform terminal primitives.
//!
//! Provides raw mode control, key reading, cursor manipulation, and
//! window size queries. Used by both `prompts` (interactive prompts)
//! and `interactive` (PTY test harness).

const std = @import("std");
const backend = @import("backend.zig");

pub const key = @import("key.zig");
pub const Key = key.Key;
pub const Mouse = key.Mouse;
pub const Focus = key.Focus;
pub const readKey = key.readKey;
pub const readKeyOpt = key.readKeyOpt;

/// Input event multiplexing: a key press or a terminal resize.
pub const event = @import("event.zig");
pub const Event = event.Event;
pub const PasteSink = event.PasteSink;
pub const readEvent = event.readEvent;
pub const readEventTimeout = event.readEventTimeout;

/// Watches for terminal resizes; construct for the lifetime of a prompt.
pub const ResizeWatcher = backend.ResizeWatcher;

/// Process-global terminal restore guard (ADR-0015): replays a registered
/// restore blob on external termination (signals / console-close) and, via the
/// `ui.panic` hook, on a panic. `arm` on takeover, `disarm` on clean teardown,
/// `restore` from a handler.
pub const guard = @import("guard.zig");

/// Display-width measurement and word-wrapping (grapheme- and ANSI-aware).
pub const wrap = @import("wrap.zig");
pub const displayWidth = wrap.displayWidth;
pub const truncateToWidth = wrap.truncateToWidth;
pub const visibleGraphemes = wrap.visibleGraphemes;
pub const wrapToWidth = wrap.wrapToWidth;
pub const wrapForEach = wrap.wrapForEach;
pub const wrapCount = wrap.wrapCount;
pub const trailingGraphemeLen = wrap.trailingGraphemeLen;
pub const leadingGraphemeLen = wrap.leadingGraphemeLen;
pub const graphemeCount = wrap.graphemeCount;

// ============================================================================
// Raw mode, echo, window size, TTY detection
//
// These need OS support, which differs by platform, so the implementations live
// in the selected backend (`backend_posix.zig` / `backend_windows.zig`). The
// public surface is identical across platforms — `RawMode` is opaque and is
// restored via `disable()`.
// ============================================================================

pub const TerminalError = backend.TerminalError;

/// Saved terminal state for restoring after raw mode. Returned by
/// `enableRawMode`; call `disable()` to restore the original settings.
pub const RawMode = backend.RawMode;

/// Enable raw mode on a handle (typically stdin). Returns a RawMode handle that
/// must be used to restore settings.
pub const enableRawMode = backend.enableRawMode;

/// Enable or disable terminal echo (for password input).
pub const setEcho = backend.setEcho;

/// Terminal window dimensions in character cells.
pub const Winsize = backend.Winsize;
pub const getWindowSize = backend.getWindowSize;

/// Whether a handle refers to a terminal/console.
pub const isTty = backend.isTty;

pub fn isStdinTty() bool {
    return isTty(std.Io.File.stdin().handle);
}

pub fn isStdoutTty() bool {
    return isTty(std.Io.File.stdout().handle);
}

pub fn isStderrTty() bool {
    return isTty(std.Io.File.stderr().handle);
}

/// Whether the process can drive an interactive full-frame prompt: it needs
/// stdin as a TTY to read keystrokes in raw mode *and* stdout as a TTY so the
/// rendered frame escapes land on the terminal rather than a redirected file.
/// If either end is redirected, callers must fall back to the plain line path.
pub fn isInteractiveTty() bool {
    return isStdinTty() and isStdoutTty();
}

// ============================================================================
// Unicode detection
// ============================================================================

/// Check if the terminal likely supports Unicode (UTF-8).
/// Checks LC_ALL, LC_CTYPE, and LANG environment variables for UTF-8 indicators.
/// Most modern terminals support UTF-8, but some remote/embedded environments don't.
pub fn unicodeSupported(environ: *const std.process.Environ.Map) bool {
    // Check locale environment variables for UTF-8
    const vars = [_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" };
    for (vars) |name| {
        if (environ.get(name)) |val| {
            if (containsUtf8(val)) return true;
            // If explicitly set to a non-UTF-8 locale, respect that
            if (val.len > 0 and !std.mem.eql(u8, val, "C") and !std.mem.eql(u8, val, "POSIX")) {
                return false;
            }
        }
    }
    // Default: assume UTF-8 on modern systems
    return true;
}

fn containsUtf8(val: []const u8) bool {
    // Check for common UTF-8 indicators: "UTF-8", "utf-8", "utf8", ".UTF8"
    var i: usize = 0;
    while (i + 4 <= val.len) : (i += 1) {
        const c0 = std.ascii.toLower(val[i]);
        const c1 = std.ascii.toLower(val[i + 1]);
        const c2 = std.ascii.toLower(val[i + 2]);
        const c3 = std.ascii.toLower(val[i + 3]);
        if (c0 == 'u' and c1 == 't' and c2 == 'f') {
            if (c3 == '8') return true; // "utf8"
            if (c3 == '-' and i + 5 <= val.len and val[i + 4] == '8') return true; // "utf-8"
        }
    }
    return false;
}

// Adaptive glyph shapes now live in the theme package (`theme.Glyphs`), so an
// app can swap a prompt/progress glyph's shape as well as recolor it. The
// unicode/ASCII fallback is `theme.Glyph.pick(unicode)`, driven by the Unicode
// support this package detects (`unicodeSupported`).

// ============================================================================
// ANSI escape helpers
// ============================================================================

// ============================================================================
// Tests
// ============================================================================

test "Winsize type exists" {
    var ws: Winsize = undefined;
    _ = &ws;
}

test "Key type works" {
    const k: Key = .enter;
    try std.testing.expect(k == .enter);

    const c: Key = .{ .char = 'a' };
    try std.testing.expect(c.char == 'a');
}

test "ANSI helpers" {}

test "TTY detection runs" {
    _ = isStdinTty();
    _ = isStdoutTty();
}

test "unicode detection runs" {
    const env = std.process.Environ.Map.init(std.testing.allocator);
    _ = unicodeSupported(&env);
}

test "containsUtf8" {
    try std.testing.expect(containsUtf8("en_US.UTF-8"));
    try std.testing.expect(containsUtf8("en_US.utf8"));
    try std.testing.expect(containsUtf8("C.UTF-8"));
    try std.testing.expect(containsUtf8("UTF-8"));
    try std.testing.expect(!containsUtf8("C"));
    try std.testing.expect(!containsUtf8("POSIX"));
    try std.testing.expect(!containsUtf8("en_US.ISO-8859-1"));
}

test {
    std.testing.refAllDecls(@This());
    // `backend` is a private import, so refAllDecls doesn't reach it; reference
    // it explicitly so the backend (and its platform impl's) tests run.
    _ = backend;
}
