//! Terminal capability detection and theme context management
//!
//! Detects terminal capabilities through environment variables and platform-specific
//! methods, providing graceful degradation for styling output.

const std = @import("std");
const builtin = @import("builtin");


/// Terminal color capabilities from no color to full true color
pub const TerminalCapability = enum {
    no_color,    // No color support
    ansi_16,     // Basic 16 ANSI colors
    ansi_256,    // 256-color palette
    true_color,  // 24-bit RGB color

    /// Detect terminal capabilities from environment variables and platform-specific context
    pub fn detect() TerminalCapability {
        // Check NO_COLOR environment variable first (universal standard)
        if (std.process.hasEnvVar(std.heap.page_allocator, "NO_COLOR") catch false) {
            return .no_color;
        }
        
        // Platform-specific detection
        switch (builtin.os.tag) {
            .windows => return detectWindows(),
            .macos, .linux, .freebsd, .openbsd, .netbsd => return detectUnix(),
            else => return detectGeneric(),
        }
    }
    
    /// Windows-specific terminal capability detection
    pub fn detectWindows() TerminalCapability {
        // Check for Windows Terminal (modern terminal with true color support)
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "WT_SESSION") catch null) |wt_session| {
            defer std.heap.page_allocator.free(wt_session);
            return .true_color;
        }
        
        // Check for ConEmu (supports 256 colors)
        if (std.process.hasEnvVar(std.heap.page_allocator, "ConEmuPID") catch false) {
            return .ansi_256;
        }
        
        // Check for modern Windows 10+ with VT support
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "TERM_PROGRAM") catch null) |term_program| {
            defer std.heap.page_allocator.free(term_program);
            if (std.mem.eql(u8, term_program, "vscode")) {
                return .true_color;
            }
        }
        
        // Check Windows version via registry or fallback to generic detection
        return detectGeneric();
    }
    
    /// Unix/Linux/macOS-specific terminal capability detection  
    pub fn detectUnix() TerminalCapability {
        // Check COLORTERM for modern terminal support
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLORTERM") catch null) |colorterm| {
            defer std.heap.page_allocator.free(colorterm);
            if (std.mem.eql(u8, colorterm, "truecolor") or std.mem.eql(u8, colorterm, "24bit")) {
                return .true_color;
            }
        }
        
        // Check for iTerm2 (macOS)
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "TERM_PROGRAM") catch null) |term_program| {
            defer std.heap.page_allocator.free(term_program);
            if (std.mem.eql(u8, term_program, "iTerm.app")) {
                return .true_color;
            }
            if (std.mem.eql(u8, term_program, "Apple_Terminal")) {
                return .ansi_256;
            }
            if (std.mem.eql(u8, term_program, "vscode")) {
                return .true_color;
            }
        }
        
        // Check SSH connection (might have limited capabilities)
        if (std.process.hasEnvVar(std.heap.page_allocator, "SSH_CONNECTION") catch false) {
            // More conservative detection over SSH
            return detectGeneric();
        }
        
        return detectGeneric();
    }
    
    /// Generic terminal capability detection based on TERM environment variable
    pub fn detectGeneric() TerminalCapability {
        // Check TERM environment variable for capability hints
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "TERM") catch null) |term| {
            defer std.heap.page_allocator.free(term);
            
            // True color terminals
            if (std.mem.indexOf(u8, term, "truecolor") != null or
                std.mem.indexOf(u8, term, "24bit") != null) {
                return .true_color;
            }
            
            // 256-color terminals
            if (std.mem.indexOf(u8, term, "256") != null or
                std.mem.indexOf(u8, term, "256color") != null) {
                return .ansi_256;
            }
            
            // Known terminals with good color support
            if (std.mem.indexOf(u8, term, "xterm") != null or
                std.mem.indexOf(u8, term, "screen") != null or
                std.mem.indexOf(u8, term, "tmux") != null or
                std.mem.indexOf(u8, term, "vt100") != null) {
                return .ansi_16;
            }
            
            // Fallback for unknown TERM values
            if (!std.mem.eql(u8, term, "dumb")) {
                return .ansi_16;
            }
        }
        
        // Conservative fallback
        return .no_color;
    }
};

/// Theme context manages capability detection and color output decisions
pub const Theme = struct {
    capability: TerminalCapability,
    is_tty: bool,
    color_enabled: bool,

    /// Initialize theme context with automatic detection
    pub fn init() Theme {
        const capability = TerminalCapability.detect();
        const is_tty = detectTTY();
        
        return .{
            .capability = capability,
            .is_tty = is_tty,
            .color_enabled = capability != .no_color and is_tty,
        };
    }
    
    /// Initialize with explicit capability (for testing or forced modes)
    pub fn initWithCapability(capability: TerminalCapability) Theme {
        const is_tty = detectTTY();
        return .{
            .capability = capability,
            .is_tty = is_tty,
            .color_enabled = capability != .no_color and is_tty,
        };
    }
    
    /// Initialize with forced color setting (override TTY detection)
    pub fn initForced(force_color: bool) Theme {
        const capability = TerminalCapability.detect();
        const is_tty = detectTTY();
        
        return .{
            .capability = capability,
            .is_tty = is_tty,
            .color_enabled = if (force_color) capability != .no_color else capability != .no_color and is_tty,
        };
    }

    /// Get the effective capability (accounting for color_enabled)
    pub fn getCapability(self: *const Theme) TerminalCapability {
        return if (self.color_enabled) self.capability else .no_color;
    }
    
    /// Check if colors are supported at all
    pub fn supportsColor(self: *const Theme) bool {
        return self.color_enabled;
    }
    
    /// Check if true color (24-bit RGB) is supported
    pub fn supportsTrueColor(self: *const Theme) bool {
        return self.color_enabled and self.capability == .true_color;
    }
    
    /// Check if 256-color palette is supported
    pub fn supports256Color(self: *const Theme) bool {
        return self.color_enabled and (self.capability == .ansi_256 or self.capability == .true_color);
    }
    
    /// Get capability as string for debugging
    pub fn capabilityString(self: *const Theme) []const u8 {
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
fn detectTTY() bool {
    // Check if stdout is a TTY
    return std.io.getStdOut().isTty();
}

test "capability detection basics" {
    const testing = std.testing;
    
    // Test basic capability enum
    const cap = TerminalCapability.ansi_16;
    try testing.expect(cap == .ansi_16);
    
    // Test theme initialization
    const theme_ctx = Theme.init();
    try testing.expect(@TypeOf(theme_ctx.capability) == TerminalCapability);
    
    // Test capability getter
    const effective = theme_ctx.getCapability();
    try testing.expect(@TypeOf(effective) == TerminalCapability);
    
    // Test that disabled color always returns no_color
    var disabled_theme = Theme{
        .capability = .true_color,
        .is_tty = true,
        .color_enabled = false,
    };
    try testing.expect(disabled_theme.getCapability() == .no_color);
}

test "capability detection from environment" {
    const testing = std.testing;
    
    // Test that detection doesn't crash (actual detection depends on environment)
    const capability = TerminalCapability.detect();
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
    const is_tty = detectTTY();
    try testing.expect(@TypeOf(is_tty) == bool);
    
    // Test theme includes TTY info
    const theme_ctx = Theme.init();
    try testing.expect(@TypeOf(theme_ctx.is_tty) == bool);
}

test "platform-specific detection functions" {
    const testing = std.testing;
    
    // Test Windows detection doesn't crash
    const windows_cap = TerminalCapability.detectWindows();
    try testing.expect(@TypeOf(windows_cap) == TerminalCapability);
    
    // Test Unix detection doesn't crash  
    const unix_cap = TerminalCapability.detectUnix();
    try testing.expect(@TypeOf(unix_cap) == TerminalCapability);
    
    // Test generic detection doesn't crash
    const generic_cap = TerminalCapability.detectGeneric();
    try testing.expect(@TypeOf(generic_cap) == TerminalCapability);
}

test "capability range validation" {
    const testing = std.testing;
    
    // Test all detection paths return valid capabilities
    const capabilities = [_]TerminalCapability{
        TerminalCapability.detectWindows(),
        TerminalCapability.detectUnix(), 
        TerminalCapability.detectGeneric(),
        TerminalCapability.detect(),
    };
    
    for (capabilities) |cap| {
        try testing.expect(cap == .no_color or 
                          cap == .ansi_16 or 
                          cap == .ansi_256 or 
                          cap == .true_color);
    }
}

test "enhanced Theme context methods" {
    const testing = std.testing;
    
    // Test explicit capability initialization
    const true_color_theme = Theme.initWithCapability(.true_color);
    try testing.expect(true_color_theme.capability == .true_color);
    try testing.expect(true_color_theme.supportsTrueColor() == true_color_theme.color_enabled);
    try testing.expect(true_color_theme.supports256Color() == true_color_theme.color_enabled);
    try testing.expect(true_color_theme.supportsColor() == true_color_theme.color_enabled);
    
    // Test forced color mode
    const forced_theme = Theme.initForced(true);
    try testing.expect(forced_theme.color_enabled == (forced_theme.capability != .no_color));
    
    // Test no-color theme
    const no_color_theme = Theme.initWithCapability(.no_color);
    try testing.expect(!no_color_theme.supportsColor());
    try testing.expect(!no_color_theme.supportsTrueColor());
    try testing.expect(!no_color_theme.supports256Color());
    
    // Test ANSI-16 theme
    const ansi16_theme = Theme.initWithCapability(.ansi_16);
    try testing.expect(ansi16_theme.supportsColor() == ansi16_theme.color_enabled);
    try testing.expect(!ansi16_theme.supportsTrueColor());
    try testing.expect(!ansi16_theme.supports256Color());
    
    // Test capability strings
    try testing.expect(std.mem.eql(u8, no_color_theme.capabilityString(), "no color"));
}

test "Theme capability hierarchy" {
    const testing = std.testing;
    
    // True color should support all lower capabilities
    const true_color = Theme.initWithCapability(.true_color);
    if (true_color.color_enabled) {
        try testing.expect(true_color.supportsTrueColor());
        try testing.expect(true_color.supports256Color());
        try testing.expect(true_color.supportsColor());
    }
    
    // 256-color should support color but not true color
    const ansi256 = Theme.initWithCapability(.ansi_256);
    if (ansi256.color_enabled) {
        try testing.expect(!ansi256.supportsTrueColor());
        try testing.expect(ansi256.supports256Color());
        try testing.expect(ansi256.supportsColor());
    }
}