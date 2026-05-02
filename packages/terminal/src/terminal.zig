//! Cross-platform terminal primitives.
//!
//! Provides raw mode control, key reading, cursor manipulation, and
//! window size queries. Used by both `zinput` (interactive prompts)
//! and `interactive` (PTY test harness).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const key = @import("key.zig");
pub const Key = key.Key;
pub const readKey = key.readKey;

// ============================================================================
// Cross-platform termios
// ============================================================================

pub const Termios = switch (builtin.os.tag) {
    .linux => std.os.linux.termios,
    .macos => extern struct {
        c_iflag: c_ulong, // tcflag_t = unsigned long on macOS
        c_oflag: c_ulong,
        c_cflag: c_ulong,
        c_lflag: c_ulong,
        c_cc: [20]u8,
        c_ispeed: c_ulong, // speed_t = unsigned long on macOS
        c_ospeed: c_ulong,
    },
    else => std.os.linux.termios,
};

pub extern "c" fn tcgetattr(fd: c_int, termios_p: *Termios) c_int;
pub extern "c" fn tcsetattr(fd: c_int, optional_actions: c_int, termios_p: *const Termios) c_int;
pub extern "c" fn cfmakeraw(termios_p: *Termios) void;
pub extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

pub const TCSAFLUSH = 2;

pub const TerminalError = error{
    NotATerminal,
    TerminalSettingsError,
};

// ============================================================================
// Raw mode
// ============================================================================

/// Saved terminal state for restoring after raw mode.
pub const RawMode = struct {
    fd: posix.fd_t,
    original: Termios,

    /// Restore original terminal settings.
    pub fn disable(self: RawMode) void {
        _ = tcsetattr(self.fd, TCSAFLUSH, &self.original);
    }
};

/// Enable raw mode on a file descriptor (typically stdin).
/// Returns a RawMode handle that must be used to restore settings.
pub fn enableRawMode(fd: posix.fd_t) TerminalError!RawMode {
    var original: Termios = undefined;
    if (tcgetattr(fd, &original) != 0) return error.NotATerminal;

    var raw = original;
    cfmakeraw(&raw);

    if (tcsetattr(fd, TCSAFLUSH, &raw) != 0) return error.TerminalSettingsError;

    return .{ .fd = fd, .original = original };
}

// ============================================================================
// Echo control
// ============================================================================

/// Enable or disable terminal echo (for password input).
pub fn setEcho(fd: posix.fd_t, enabled: bool) TerminalError!void {
    var termios: Termios = undefined;
    if (tcgetattr(fd, &termios) != 0) return error.NotATerminal;

    switch (builtin.os.tag) {
        .linux => {
            const echo_flag = std.os.linux.ECHO;
            if (enabled) termios.lflag |= echo_flag else termios.lflag &= ~echo_flag;
        },
        .macos => {
            const echo_flag: c_ulong = 0x00000008;
            if (enabled) termios.c_lflag |= echo_flag else termios.c_lflag &= ~echo_flag;
        },
        else => {
            const echo_flag: c_ulong = 0x00000008;
            if (enabled) termios.lflag |= echo_flag else termios.lflag &= ~echo_flag;
        },
    }

    if (tcsetattr(fd, TCSAFLUSH, &termios) != 0) return error.TerminalSettingsError;
}

// ============================================================================
// Window size
// ============================================================================

pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

pub const TIOCGWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5413,
    .macos => 0x40087468,
    else => 0x5413,
};

pub fn getWindowSize(fd: posix.fd_t) !Winsize {
    var ws: Winsize = undefined;
    if (ioctl(fd, TIOCGWINSZ, &ws) != 0) return error.NotATerminal;
    return ws;
}

// ============================================================================
// TTY detection
// ============================================================================

pub fn isTty(fd: posix.fd_t) bool {
    return posix.isatty(fd);
}

pub fn isStdinTty() bool {
    return isTty(std.fs.File.stdin().handle);
}

pub fn isStdoutTty() bool {
    return isTty(std.fs.File.stdout().handle);
}

// ============================================================================
// Unicode detection
// ============================================================================

/// Check if the terminal likely supports Unicode (UTF-8).
/// Checks LC_ALL, LC_CTYPE, and LANG environment variables for UTF-8 indicators.
/// Most modern terminals support UTF-8, but some remote/embedded environments don't.
pub fn unicodeSupported() bool {
    // Check locale environment variables for UTF-8
    const vars = [_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" };
    for (vars) |name| {
        if (std.posix.getenv(name)) |val| {
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

test "Termios type exists" {
    var t: Termios = undefined;
    _ = &t;
}

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
    _ = unicodeSupported();
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
