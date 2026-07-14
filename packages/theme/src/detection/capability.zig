//! Terminal capability detection and theme context management
//!
//! Detects terminal capabilities through environment variables and platform-specific
//! methods, providing graceful degradation for styling output.

const std = @import("std");
const builtin = @import("builtin");

/// Terminal color capabilities from no color to full true color
pub const TerminalCapability = enum {
    no_color, // No color support
    ansi_16, // Basic 16 ANSI colors
    ansi_256, // 256-color palette
    true_color, // 24-bit RGB color

    /// Detect terminal capabilities from environment variables and platform-specific context
    pub fn detect(env: *const std.process.Environ.Map) TerminalCapability {
        // Check NO_COLOR environment variable first (universal standard).
        // Per the spec (no-color.org), the variable must be present AND
        // non-empty to disable color; `NO_COLOR=` should not.
        if (env.get("NO_COLOR")) |v| {
            if (v.len > 0) return .no_color;
        }

        // Platform-specific detection
        switch (builtin.os.tag) {
            .windows => return detectWindows(env),
            .macos, .linux, .freebsd, .openbsd, .netbsd => return detectUnix(env),
            else => return detectGeneric(env),
        }
    }

    /// Windows-specific terminal capability detection
    pub fn detectWindows(env: *const std.process.Environ.Map) TerminalCapability {
        if (env.get("WT_SESSION") != null) return .true_color;
        if (env.contains("ConEmuPID")) return .ansi_256;
        if (env.get("TERM_PROGRAM")) |tp| {
            if (std.mem.eql(u8, tp, "vscode")) return .true_color;
        }
        return detectGeneric(env);
    }

    /// Unix/Linux/macOS-specific terminal capability detection
    pub fn detectUnix(env: *const std.process.Environ.Map) TerminalCapability {
        if (env.get("COLORTERM")) |colorterm| {
            if (std.mem.eql(u8, colorterm, "truecolor") or std.mem.eql(u8, colorterm, "24bit")) {
                return .true_color;
            }
        }

        if (env.get("TERM_PROGRAM")) |term_program| {
            if (std.mem.eql(u8, term_program, "iTerm.app")) return .true_color;
            if (std.mem.eql(u8, term_program, "Apple_Terminal")) return .ansi_256;
            if (std.mem.eql(u8, term_program, "vscode")) return .true_color;
        }

        if (env.contains("SSH_CONNECTION")) {
            return detectGeneric(env);
        }

        return detectGeneric(env);
    }

    /// Generic terminal capability detection based on TERM environment variable
    pub fn detectGeneric(env: *const std.process.Environ.Map) TerminalCapability {
        if (env.get("TERM")) |term| {
            if (std.mem.indexOf(u8, term, "truecolor") != null or
                std.mem.indexOf(u8, term, "24bit") != null)
            {
                return .true_color;
            }

            if (std.mem.indexOf(u8, term, "256") != null or
                std.mem.indexOf(u8, term, "256color") != null)
            {
                return .ansi_256;
            }

            if (std.mem.indexOf(u8, term, "xterm") != null or
                std.mem.indexOf(u8, term, "screen") != null or
                std.mem.indexOf(u8, term, "tmux") != null or
                std.mem.indexOf(u8, term, "vt100") != null)
            {
                return .ansi_16;
            }

            if (!std.mem.eql(u8, term, "dumb")) {
                return .ansi_16;
            }
        }

        return .no_color;
    }
};

/// Capabilities context manages capability detection and color output decisions
pub const Capabilities = struct {
    capability: TerminalCapability,
    is_tty: bool,
    color_enabled: bool,

    /// Initialize theme context with automatic detection
    pub fn init(env: *const std.process.Environ.Map, io: std.Io) Capabilities {
        const capability = TerminalCapability.detect(env);
        const is_tty = detectTTY(io);

        return .{
            .capability = capability,
            .is_tty = is_tty,
            .color_enabled = capability != .no_color and is_tty,
        };
    }

    /// Initialize with explicit capability (for testing or forced modes)
    pub fn initWithCapability(capability: TerminalCapability, io: std.Io) Capabilities {
        const is_tty = detectTTY(io);
        return .{
            .capability = capability,
            .is_tty = is_tty,
            .color_enabled = capability != .no_color and is_tty,
        };
    }

    /// Initialize with forced color setting (override TTY detection)
    pub fn initForced(env: *const std.process.Environ.Map, io: std.Io, force_color: bool) Capabilities {
        const capability = TerminalCapability.detect(env);
        const is_tty = detectTTY(io);

        return .{
            .capability = capability,
            .is_tty = is_tty,
            .color_enabled = if (force_color) capability != .no_color else capability != .no_color and is_tty,
        };
    }

    /// Get the effective capability (accounting for color_enabled)
    pub fn getCapability(self: *const Capabilities) TerminalCapability {
        return if (self.color_enabled) self.capability else .no_color;
    }

    /// Check if colors are supported at all
    pub fn supportsColor(self: *const Capabilities) bool {
        return self.color_enabled;
    }

    /// Check if true color (24-bit RGB) is supported
    pub fn supportsTrueColor(self: *const Capabilities) bool {
        return self.color_enabled and self.capability == .true_color;
    }

    /// Check if 256-color palette is supported
    pub fn supports256Color(self: *const Capabilities) bool {
        return self.color_enabled and (self.capability == .ansi_256 or self.capability == .true_color);
    }

    /// Get capability as string for debugging
    pub fn capabilityString(self: *const Capabilities) []const u8 {
        const effective = self.getCapability();
        return switch (effective) {
            .no_color => "no color",
            .ansi_16 => "16-color ANSI",
            .ansi_256 => "256-color",
            .true_color => "true color (24-bit)",
        };
    }
};

/// Detect if output is to a TTY (terminal)
fn detectTTY(io: std.Io) bool {
    return std.Io.File.stdout().isTty(io) catch false;
}

test "NO_COLOR: empty string does not disable color" {
    const testing = std.testing;

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("NO_COLOR", "");
    try env.put("TERM", "xterm-256color");

    // Empty NO_COLOR must not force no_color; detection should fall through
    // to the generic TERM-based path.
    try testing.expect(TerminalCapability.detect(&env) != .no_color);
}

test "NO_COLOR: non-empty value disables color" {
    const testing = std.testing;

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("NO_COLOR", "1");
    try env.put("TERM", "xterm-256color");

    try testing.expect(TerminalCapability.detect(&env) == .no_color);
}

test "capability detection basics" {
    const testing = std.testing;

    // Test basic capability enum
    const cap = TerminalCapability.ansi_16;
    try testing.expect(cap == .ansi_16);

    // Test theme initialization
    const theme_ctx = Capabilities.init(&(std.process.Environ.Map.init(std.testing.allocator)), std.testing.io);
    try testing.expect(@TypeOf(theme_ctx.capability) == TerminalCapability);

    // Test capability getter
    const effective = theme_ctx.getCapability();
    try testing.expect(@TypeOf(effective) == TerminalCapability);

    // Test that disabled color always returns no_color
    var disabled_theme = Capabilities{
        .capability = .true_color,
        .is_tty = true,
        .color_enabled = false,
    };
    try testing.expect(disabled_theme.getCapability() == .no_color);
}

test "capability detection from environment" {
    const testing = std.testing;

    // Test that detection doesn't crash (actual detection depends on environment)
    const capability = TerminalCapability.detect(&(std.process.Environ.Map.init(std.testing.allocator)));
    try testing.expect(@TypeOf(capability) == TerminalCapability);

    // Should be one of the valid capability values
    try testing.expect(capability == .no_color or
        capability == .ansi_16 or
        capability == .ansi_256 or
        capability == .true_color);
}

test "TTY detection" {
    const testing = std.testing;

    // Test TTY detection doesn't crash
    const is_tty = detectTTY(std.testing.io);
    try testing.expect(@TypeOf(is_tty) == bool);

    // Test theme includes TTY info
    const theme_ctx = Capabilities.init(&(std.process.Environ.Map.init(std.testing.allocator)), std.testing.io);
    try testing.expect(@TypeOf(theme_ctx.is_tty) == bool);
}

test "platform-specific detection functions" {
    const testing = std.testing;

    // Test Windows detection doesn't crash
    const windows_cap = TerminalCapability.detectWindows(&(std.process.Environ.Map.init(std.testing.allocator)));
    try testing.expect(@TypeOf(windows_cap) == TerminalCapability);

    // Test Unix detection doesn't crash
    const unix_cap = TerminalCapability.detectUnix(&(std.process.Environ.Map.init(std.testing.allocator)));
    try testing.expect(@TypeOf(unix_cap) == TerminalCapability);

    // Test generic detection doesn't crash
    const generic_cap = TerminalCapability.detectGeneric(&(std.process.Environ.Map.init(std.testing.allocator)));
    try testing.expect(@TypeOf(generic_cap) == TerminalCapability);
}

test "capability range validation" {
    const testing = std.testing;

    // Test all detection paths return valid capabilities
    const capabilities = [_]TerminalCapability{
        TerminalCapability.detectWindows(&(std.process.Environ.Map.init(std.testing.allocator))),
        TerminalCapability.detectUnix(&(std.process.Environ.Map.init(std.testing.allocator))),
        TerminalCapability.detectGeneric(&(std.process.Environ.Map.init(std.testing.allocator))),
        TerminalCapability.detect(&(std.process.Environ.Map.init(std.testing.allocator))),
    };

    for (capabilities) |cap| {
        try testing.expect(cap == .no_color or
            cap == .ansi_16 or
            cap == .ansi_256 or
            cap == .true_color);
    }
}

test "enhanced Capabilities context methods" {
    const testing = std.testing;

    // Test explicit capability initialization
    const true_color_theme = Capabilities.initWithCapability(.true_color, std.testing.io);
    try testing.expect(true_color_theme.capability == .true_color);
    try testing.expect(true_color_theme.supportsTrueColor() == true_color_theme.color_enabled);
    try testing.expect(true_color_theme.supports256Color() == true_color_theme.color_enabled);
    try testing.expect(true_color_theme.supportsColor() == true_color_theme.color_enabled);

    // Test forced color mode
    const forced_theme = Capabilities.initForced(&(std.process.Environ.Map.init(testing.allocator)), std.testing.io, true);
    try testing.expect(forced_theme.color_enabled == (forced_theme.capability != .no_color));

    // Test no-color theme
    const no_color_theme = Capabilities.initWithCapability(.no_color, std.testing.io);
    try testing.expect(!no_color_theme.supportsColor());
    try testing.expect(!no_color_theme.supportsTrueColor());
    try testing.expect(!no_color_theme.supports256Color());

    // Test ANSI-16 theme
    const ansi16_theme = Capabilities.initWithCapability(.ansi_16, std.testing.io);
    try testing.expect(ansi16_theme.supportsColor() == ansi16_theme.color_enabled);
    try testing.expect(!ansi16_theme.supportsTrueColor());
    try testing.expect(!ansi16_theme.supports256Color());

    // Test capability strings
    try testing.expect(std.mem.eql(u8, no_color_theme.capabilityString(), "no color"));
}

test "Capabilities capability hierarchy" {
    const testing = std.testing;

    // True color should support all lower capabilities
    const true_color = Capabilities.initWithCapability(.true_color, std.testing.io);
    if (true_color.color_enabled) {
        try testing.expect(true_color.supportsTrueColor());
        try testing.expect(true_color.supports256Color());
        try testing.expect(true_color.supportsColor());
    }

    // 256-color should support color but not true color
    const ansi256 = Capabilities.initWithCapability(.ansi_256, std.testing.io);
    if (ansi256.color_enabled) {
        try testing.expect(!ansi256.supportsTrueColor());
        try testing.expect(ansi256.supports256Color());
        try testing.expect(ansi256.supportsColor());
    }
}
