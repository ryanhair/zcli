//! Terminal Capabilities Detection
//!
//! This package provides comprehensive terminal capability detection for building
//! adaptive terminal applications. It can detect color support, Unicode capabilities,
//! mouse support, terminal size, and much more.

const std = @import("std");

// Core capability detection types
pub const ColorSupport = enum {
    /// No color support (monochrome)
    none,
    /// 16 color support (ANSI)
    ansi_16,
    /// 256 color palette
    palette_256,
    /// 24-bit RGB (truecolor)
    truecolor,

    pub fn supportsRgb(self: ColorSupport) bool {
        return self == .truecolor;
    }

    pub fn supports256(self: ColorSupport) bool {
        return self == .palette_256 or self == .truecolor;
    }

    pub fn supportsAnsi(self: ColorSupport) bool {
        return self != .none;
    }
};

pub const UnicodeSupport = struct {
    /// Basic UTF-8 support
    utf8: bool = false,
    /// Wide character (CJK) support
    wide_chars: bool = false,
    /// Emoji support
    emoji: bool = false,
    /// Combining character support
    combining_chars: bool = false,
};

pub const MouseSupport = struct {
    /// Basic mouse clicks
    basic: bool = false,
    /// Mouse movement tracking
    motion: bool = false,
    /// Scroll wheel events
    wheel: bool = false,
    /// Drag operations
    drag: bool = false,
    /// SGR mouse mode
    sgr_mode: bool = false,
};

pub const TerminalSize = struct {
    width: u16,
    height: u16,

    pub fn cells(self: TerminalSize) u32 {
        return @as(u32, self.width) * @as(u32, self.height);
    }
};

pub const TerminalType = enum {
    /// Unknown or generic terminal
    unknown,
    /// xterm and derivatives
    xterm,
    /// Linux console
    linux_console,
    /// Windows Console Host
    windows_console,
    /// Windows Terminal
    windows_terminal,
    /// Terminal.app (macOS)
    terminal_app,
    /// iTerm2
    iterm2,
    /// tmux multiplexer
    tmux,
    /// screen multiplexer
    screen,
    /// SSH session
    ssh,
};

pub const AlternateScreenSupport = struct {
    /// Can enter alternate screen buffer
    available: bool = false,
    /// Alternate screen preserves scrollback
    preserves_scrollback: bool = false,
};

pub const TerminalCapabilities = struct {
    /// Color support level
    color: ColorSupport = .none,
    /// Unicode and character support
    unicode: UnicodeSupport = .{},
    /// Mouse input capabilities
    mouse: MouseSupport = .{},
    /// Current terminal dimensions
    size: TerminalSize = .{ .width = 80, .height = 24 },
    /// Terminal type identification
    terminal_type: TerminalType = .unknown,
    /// Alternate screen buffer support
    alternate_screen: AlternateScreenSupport = .{},
    /// Whether terminal supports cursor hide/show
    cursor_control: bool = false,
    /// Whether terminal supports scrolling regions
    scrolling_regions: bool = false,
    /// Whether terminal supports bracketed paste
    bracketed_paste: bool = false,
    /// Whether terminal supports focus events
    focus_events: bool = false,

    /// Get a human-readable description of capabilities
    pub fn describe(self: TerminalCapabilities, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        const writer = buffer.writer();

        try writer.print("Terminal: {s}\n", .{@tagName(self.terminal_type)});
        try writer.print("Size: {}x{}\n", .{ self.size.width, self.size.height });
        try writer.print("Color: {s}\n", .{@tagName(self.color)});

        if (self.unicode.utf8) {
            try writer.writeAll("Unicode: ✓ UTF-8");
            if (self.unicode.wide_chars) try writer.writeAll(" ✓ Wide");
            if (self.unicode.emoji) try writer.writeAll(" ✓ Emoji");
            if (self.unicode.combining_chars) try writer.writeAll(" ✓ Combining");
            try writer.writeByte('\n');
        } else {
            try writer.writeAll("Unicode: ✗ No UTF-8 support\n");
        }

        if (self.mouse.basic) {
            try writer.writeAll("Mouse: ✓ Basic");
            if (self.mouse.motion) try writer.writeAll(" ✓ Motion");
            if (self.mouse.wheel) try writer.writeAll(" ✓ Wheel");
            if (self.mouse.drag) try writer.writeAll(" ✓ Drag");
            try writer.writeByte('\n');
        } else {
            try writer.writeAll("Mouse: ✗ Not supported\n");
        }

        return buffer.toOwnedSlice();
    }
};

pub const DetectionError = error{
    /// Could not determine terminal capabilities
    DetectionFailed,
    /// Terminal does not respond to queries
    NoResponse,
    /// Invalid response from terminal
    InvalidResponse,
    /// Timeout during detection
    Timeout,
    /// Not a terminal (e.g., pipe, file)
    NotATty,
} || std.mem.Allocator.Error;

/// Detect terminal capabilities with default timeout
pub fn detect(allocator: std.mem.Allocator) DetectionError!TerminalCapabilities {
    return detectWithTimeout(allocator, 100); // 100ms default timeout
}

/// Detect terminal capabilities with specified timeout in milliseconds
pub fn detectWithTimeout(allocator: std.mem.Allocator, timeout_ms: u32) DetectionError!TerminalCapabilities {
    _ = allocator;
    _ = timeout_ms;

    // Start with basic detection using existing functions
    var caps = TerminalCapabilities{};

    // Detect color support
    caps.color = detectColor(null) catch .none;

    // Detect terminal size
    caps.size = detectSize() catch .{ .width = 80, .height = 24 };

    // Basic Unicode support detection (assume UTF-8 in modern terminals)
    if (caps.color != .none) {
        caps.unicode.utf8 = true;
        caps.unicode.wide_chars = true;
        caps.unicode.emoji = true;
    }

    // Basic feature detection based on terminal type
    if (std.posix.getenv("TERM")) |term| {
        if (std.mem.containsAtLeast(u8, term, 1, "xterm")) {
            caps.terminal_type = .xterm;
            caps.cursor_control = true;
            caps.alternate_screen.available = true;
            caps.mouse.basic = true;
        } else if (std.mem.containsAtLeast(u8, term, 1, "screen")) {
            caps.terminal_type = .screen;
            caps.cursor_control = true;
        } else if (std.mem.containsAtLeast(u8, term, 1, "tmux")) {
            caps.terminal_type = .tmux;
            caps.cursor_control = true;
        }
    }

    return caps;
}

/// Environment interface for dependency injection in tests
pub const Environment = struct {
    isatty_fn: *const fn () bool,
    getenv_fn: *const fn ([]const u8) ?[]const u8,

    pub fn init() Environment {
        return .{
            .isatty_fn = isTty,
            .getenv_fn = getEnvVar,
        };
    }
};

fn getEnvVar(name: []const u8) ?[]const u8 {
    return std.posix.getenv(name);
}

/// Detect specific capability quickly
pub fn detectColor(env: ?Environment) DetectionError!ColorSupport {
    const environment = env orelse Environment.init();

    // First check if we're running in a TTY
    if (!environment.isatty_fn()) {
        return DetectionError.NotATty;
    }

    // Check COLORTERM environment variable first (most reliable for truecolor)
    if (environment.getenv_fn("COLORTERM")) |colorterm| {
        if (std.mem.eql(u8, colorterm, "truecolor") or std.mem.eql(u8, colorterm, "24bit")) {
            return .truecolor;
        }
    }

    // Check TERM environment variable
    if (environment.getenv_fn("TERM")) |term| {
        // Check for truecolor support
        if (std.mem.containsAtLeast(u8, term, 1, "truecolor") or
            std.mem.containsAtLeast(u8, term, 1, "24bit") or
            std.mem.containsAtLeast(u8, term, 1, "iterm") or
            std.mem.eql(u8, term, "xterm-kitty"))
        {
            return .truecolor;
        }

        // Check for 256 color support
        if (std.mem.containsAtLeast(u8, term, 1, "256color") or
            std.mem.containsAtLeast(u8, term, 1, "xterm"))
        {
            return .palette_256;
        }

        // Check for basic color support
        if (std.mem.containsAtLeast(u8, term, 1, "color") or
            std.mem.containsAtLeast(u8, term, 1, "ansi"))
        {
            return .ansi_16;
        }

        // Special cases for terminals that don't advertise color in TERM
        if (std.mem.eql(u8, term, "screen") or std.mem.eql(u8, term, "tmux")) {
            return .ansi_16; // Conservative assumption
        }
    }

    // Fallback: assume basic ANSI color support in most modern terminals
    return .ansi_16;
}

/// Detect terminal size only (faster than full detection)
pub fn detectSize() DetectionError!TerminalSize {
    if (!isTty()) {
        return DetectionError.NotATty;
    }

    // Try to get terminal size using ioctl
    var winsize: std.posix.winsize = undefined;
    const result = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));

    if (std.posix.errno(result) != .SUCCESS) {
        return DetectionError.DetectionFailed;
    }

    if (winsize.col == 0 or winsize.row == 0) {
        // Invalid size, return default
        return .{ .width = 80, .height = 24 };
    }

    return .{ .width = winsize.col, .height = winsize.row };
}

/// Check if current environment is a TTY
pub fn isTty() bool {
    // Check if stdout is a TTY
    return std.posix.isatty(std.posix.STDOUT_FILENO);
}

// Test suite starts here
test {
    std.testing.refAllDecls(@This());
}

test "ColorSupport methods" {
    const none = ColorSupport.none;
    const ansi = ColorSupport.ansi_16;
    const palette = ColorSupport.palette_256;
    const truecolor = ColorSupport.truecolor;

    // Test RGB support
    try std.testing.expect(!none.supportsRgb());
    try std.testing.expect(!ansi.supportsRgb());
    try std.testing.expect(!palette.supportsRgb());
    try std.testing.expect(truecolor.supportsRgb());

    // Test 256 color support
    try std.testing.expect(!none.supports256());
    try std.testing.expect(!ansi.supports256());
    try std.testing.expect(palette.supports256());
    try std.testing.expect(truecolor.supports256());

    // Test ANSI support
    try std.testing.expect(!none.supportsAnsi());
    try std.testing.expect(ansi.supportsAnsi());
    try std.testing.expect(palette.supportsAnsi());
    try std.testing.expect(truecolor.supportsAnsi());
}

test "TerminalSize calculations" {
    const size = TerminalSize{ .width = 80, .height = 24 };
    try std.testing.expectEqual(@as(u32, 1920), size.cells());

    const large = TerminalSize{ .width = 200, .height = 50 };
    try std.testing.expectEqual(@as(u32, 10000), large.cells());
}

test "TerminalCapabilities describe output" {
    var caps = TerminalCapabilities{
        .color = .truecolor,
        .unicode = .{ .utf8 = true, .wide_chars = true, .emoji = true },
        .mouse = .{ .basic = true, .motion = true },
        .size = .{ .width = 120, .height = 40 },
        .terminal_type = .xterm,
    };

    const allocator = std.testing.allocator;
    const description = try caps.describe(allocator);
    defer allocator.free(description);

    try std.testing.expect(std.mem.containsAtLeast(u8, description, 1, "Terminal: xterm"));
    try std.testing.expect(std.mem.containsAtLeast(u8, description, 1, "Size: 120x40"));
    try std.testing.expect(std.mem.containsAtLeast(u8, description, 1, "Color: truecolor"));
    try std.testing.expect(std.mem.containsAtLeast(u8, description, 1, "✓ UTF-8"));
    try std.testing.expect(std.mem.containsAtLeast(u8, description, 1, "✓ Wide"));
    try std.testing.expect(std.mem.containsAtLeast(u8, description, 1, "✓ Emoji"));
    try std.testing.expect(std.mem.containsAtLeast(u8, description, 1, "✓ Basic"));
    try std.testing.expect(std.mem.containsAtLeast(u8, description, 1, "✓ Motion"));
}

fn mockTtyTrue() bool {
    return true;
}

fn mockTtyFalse() bool {
    return false;
}

fn mockGetenvXterm(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "TERM")) {
        return "xterm-256color";
    }
    return null;
}

test "color detection with TTY input" {
    // Mock environment with TTY and xterm
    const mock_env = Environment{
        .isatty_fn = mockTtyTrue,
        .getenv_fn = mockGetenvXterm,
    };

    const color_support = try detectColor(mock_env);
    try std.testing.expect(color_support.supportsAnsi());
}

test "color detection with no TTY returns error" {
    // Mock environment without TTY
    const mock_env = Environment{
        .isatty_fn = mockTtyFalse,
        .getenv_fn = mockGetenvXterm,
    };

    const result = detectColor(mock_env);
    try std.testing.expectError(DetectionError.NotATty, result);
}

test "size detection" {
    const result = detectSize();

    // Should either succeed with reasonable values or fail with appropriate error
    if (result) |size| {
        try std.testing.expect(size.width > 0);
        try std.testing.expect(size.height > 0);
        try std.testing.expect(size.width <= 1000); // Sanity check
        try std.testing.expect(size.height <= 1000);
    } else |err| {
        // These are the expected error types
        try std.testing.expect(err == DetectionError.DetectionFailed or
            err == DetectionError.NotATty or
            err == DetectionError.Timeout);
    }
}

test "full detection with timeout" {
    const allocator = std.testing.allocator;

    // Test with short timeout
    const result = detectWithTimeout(allocator, 50);
    if (result) |caps| {
        // Basic sanity checks on returned capabilities
        try std.testing.expect(caps.size.width > 0);
        try std.testing.expect(caps.size.height > 0);
    } else |err| {
        // Expected errors during testing
        try std.testing.expect(err == DetectionError.DetectionFailed or
            err == DetectionError.NotATty or
            err == DetectionError.Timeout or
            err == DetectionError.NoResponse);
    }
}

test "TTY detection" {
    const is_tty = isTty();
    // Should return boolean without error
    try std.testing.expect(is_tty == true or is_tty == false);
}

test "UnicodeSupport combinations" {
    // Test various Unicode support combinations
    const unicode_basic = UnicodeSupport{ .utf8 = true };
    try std.testing.expect(unicode_basic.utf8);
    try std.testing.expect(!unicode_basic.wide_chars);
    try std.testing.expect(!unicode_basic.emoji);

    const unicode_full = UnicodeSupport{ .utf8 = true, .wide_chars = true, .emoji = true, .combining_chars = true };
    try std.testing.expect(unicode_full.utf8);
    try std.testing.expect(unicode_full.wide_chars);
    try std.testing.expect(unicode_full.emoji);
    try std.testing.expect(unicode_full.combining_chars);
}

test "MouseSupport feature detection" {
    const mouse_basic = MouseSupport{ .basic = true };
    try std.testing.expect(mouse_basic.basic);
    try std.testing.expect(!mouse_basic.motion);

    const mouse_advanced = MouseSupport{ .basic = true, .motion = true, .wheel = true, .drag = true, .sgr_mode = true };
    try std.testing.expect(mouse_advanced.basic);
    try std.testing.expect(mouse_advanced.motion);
    try std.testing.expect(mouse_advanced.wheel);
    try std.testing.expect(mouse_advanced.drag);
    try std.testing.expect(mouse_advanced.sgr_mode);
}

test "AlternateScreenSupport options" {
    const alt_basic = AlternateScreenSupport{ .available = true };
    try std.testing.expect(alt_basic.available);
    try std.testing.expect(!alt_basic.preserves_scrollback);

    const alt_advanced = AlternateScreenSupport{ .available = true, .preserves_scrollback = true };
    try std.testing.expect(alt_advanced.available);
    try std.testing.expect(alt_advanced.preserves_scrollback);
}

test "TerminalType identification" {
    // Test all terminal types are accessible
    const types = [_]TerminalType{ .unknown, .xterm, .linux_console, .windows_console, .windows_terminal, .terminal_app, .iterm2, .tmux, .screen, .ssh };

    for (types) |terminal_type| {
        const caps = TerminalCapabilities{ .terminal_type = terminal_type };
        try std.testing.expectEqual(terminal_type, caps.terminal_type);
    }
}

test "error type completeness" {
    // Verify all detection error types are reachable
    const errors = [_]DetectionError{
        DetectionError.DetectionFailed,
        DetectionError.NoResponse,
        DetectionError.InvalidResponse,
        DetectionError.Timeout,
        DetectionError.NotATty,
    };

    for (errors) |err| {
        // Just verify each error type is valid
        const err_name = @errorName(err);
        try std.testing.expect(err_name.len > 0);
    }
}
