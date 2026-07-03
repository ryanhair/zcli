//! Cross-platform terminal primitives.
//!
//! Provides raw mode control, key reading, cursor manipulation, and
//! window size queries. Used by both `zinput` (interactive prompts)
//! and `interactive` (PTY test harness).

const std = @import("std");
const backend = @import("backend.zig");

pub const key = @import("key.zig");
pub const Key = key.Key;
pub const readKey = key.readKey;
pub const readKeyOpt = key.readKeyOpt;

/// Input event multiplexing: a key press or a terminal resize.
pub const event = @import("event.zig");
pub const Event = event.Event;
pub const readEvent = event.readEvent;

/// Watches for terminal resizes; construct for the lifetime of a prompt.
pub const ResizeWatcher = backend.ResizeWatcher;

/// Display-width measurement and word-wrapping (grapheme- and ANSI-aware).
pub const wrap = @import("wrap.zig");
pub const displayWidth = wrap.displayWidth;
pub const wrapToWidth = wrap.wrapToWidth;
pub const wrapForEach = wrap.wrapForEach;
pub const wrapCount = wrap.wrapCount;
pub const trailingGraphemeLen = wrap.trailingGraphemeLen;
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

/// Symbols that adapt based on unicode support.
/// Use these instead of hardcoding Unicode characters.
pub const symbols = struct {
    pub fn select_cursor(unicode: bool) []const u8 {
        return if (unicode) "❯" else ">";
    }
    pub fn selected(unicode: bool) []const u8 {
        return if (unicode) "◉" else "[x]";
    }
    pub fn unselected(unicode: bool) []const u8 {
        return if (unicode) "○" else "[ ]";
    }
    pub fn success(unicode: bool) []const u8 {
        return if (unicode) "✔" else "+";
    }
    pub fn failure(unicode: bool) []const u8 {
        return if (unicode) "✖" else "x";
    }
    pub fn warning(unicode: bool) []const u8 {
        return if (unicode) "⚠" else "!";
    }
    pub fn info(unicode: bool) []const u8 {
        return if (unicode) "ℹ" else "i";
    }
    pub fn bullet(unicode: bool) []const u8 {
        return if (unicode) "•" else "*";
    }
};

// ============================================================================
// ANSI escape helpers
// ============================================================================

pub const ansi = struct {
    pub const hide_cursor = "\x1b[?25l";
    pub const show_cursor = "\x1b[?25h";
    pub const clear_line = "\r\x1b[K";
    pub const clear_to_end = "\x1b[J";
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";

    pub fn cursorUp(comptime n: usize) []const u8 {
        return std.fmt.comptimePrint("\x1b[{d}A", .{n});
    }

    pub fn cursorDown(comptime n: usize) []const u8 {
        return std.fmt.comptimePrint("\x1b[{d}B", .{n});
    }
};

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

test "ANSI helpers" {
    try std.testing.expectEqualStrings("\x1b[?25l", ansi.hide_cursor);
    try std.testing.expectEqualStrings("\r\x1b[K", ansi.clear_line);
}

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

test "symbols provide correct fallbacks" {
    try std.testing.expectEqualStrings("❯", symbols.select_cursor(true));
    try std.testing.expectEqualStrings(">", symbols.select_cursor(false));
    try std.testing.expectEqualStrings("✔", symbols.success(true));
    try std.testing.expectEqualStrings("+", symbols.success(false));
}

test {
    std.testing.refAllDecls(@This());
}
