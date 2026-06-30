//! Cross-platform terminal primitives.
//!
//! Provides raw mode control, key reading, cursor manipulation, and
//! window size queries. Used by both `zinput` (interactive prompts)
//! and `interactive` (PTY test harness).

const std = @import("std");
const posix = std.posix;

pub const key = @import("key.zig");
pub const Key = key.Key;
pub const readKey = key.readKey;
pub const readKeyOpt = key.readKeyOpt;

// ============================================================================
// Termios / raw mode (libc-free via std.posix)
// ============================================================================

/// The platform termios struct. `std.posix` normalizes the flag words to packed
/// structs with identical POSIX field names on Linux and macOS, so all the code
/// below is a single cross-platform path with no `extern "c"` and no libc.
pub const Termios = posix.termios;

pub const TerminalError = error{
    NotATerminal,
    TerminalSettingsError,
};

/// Saved terminal state for restoring after raw mode.
pub const RawMode = struct {
    fd: posix.fd_t,
    original: Termios,

    /// Restore original terminal settings.
    pub fn disable(self: RawMode) void {
        posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
    }
};

/// Enable raw mode on a file descriptor (typically stdin).
/// Returns a RawMode handle that must be used to restore settings.
pub fn enableRawMode(fd: posix.fd_t) TerminalError!RawMode {
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

// ============================================================================
// Echo control
// ============================================================================

/// Enable or disable terminal echo (for password input).
pub fn setEcho(fd: posix.fd_t, enabled: bool) TerminalError!void {
    var termios = posix.tcgetattr(fd) catch return error.NotATerminal;
    termios.lflag.ECHO = enabled;
    posix.tcsetattr(fd, .FLUSH, termios) catch return error.TerminalSettingsError;
}

// ============================================================================
// Window size
// ============================================================================

pub const Winsize = posix.winsize;

pub fn getWindowSize(fd: posix.fd_t) !Winsize {
    var ws: Winsize = undefined;
    switch (posix.errno(posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws)))) {
        .SUCCESS => return ws,
        else => return error.NotATerminal,
    }
}

// ============================================================================
// TTY detection
// ============================================================================

/// A descriptor is a TTY iff its termios can be read — a libc-free isatty
/// (`std.posix.isatty` was removed in 0.16, and the syscall-free check is
/// exactly what isatty does under the hood).
pub fn isTty(fd: posix.fd_t) bool {
    _ = posix.tcgetattr(fd) catch return false;
    return true;
}

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
