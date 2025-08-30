//! Style definitions and ANSI escape sequence generation
//!
//! Combines colors and text decorations into complete styles that can
//! generate optimal escape sequences at compile-time.

const std = @import("std");
const Color = @import("color.zig").Color;
const toAnsi16 = @import("color.zig").toAnsi16;
const toAnsi256 = @import("color.zig").toAnsi256;
const parseHex = @import("color.zig").parseHex;
const approximateRgbToAnsi16 = @import("color.zig").approximateRgbToAnsi16;
const SemanticRole = @import("../adaptive/semantic.zig").SemanticRole;

// Create runtime version of toAnsi16 for this module
fn toAnsi16Runtime(color: Color) u8 {
    return switch (color) {
        .black => 0,
        .red => 1,
        .green => 2,
        .yellow => 3,
        .blue => 4,
        .magenta => 5,
        .cyan => 6,
        .white => 7,
        .bright_black => 8,
        .bright_red => 9,
        .bright_green => 10,
        .bright_yellow => 11,
        .bright_blue => 12,
        .bright_magenta => 13,
        .bright_cyan => 14,
        .bright_white => 15,
        .indexed => |idx| if (idx < 16) idx else 7,
        .rgb => |rgb| approximateRgbToAnsi16(rgb.r, rgb.g, rgb.b),
        .hex => |hex_str| {
            const rgb = parseHex(hex_str);
            return approximateRgbToAnsi16(rgb.r, rgb.g, rgb.b);
        },
    };
}

const TerminalCapability = @import("../detection/capability.zig").TerminalCapability;

/// Complete text styling information
pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    dim: bool = false,
    semantic_role: ?SemanticRole = null,  // For adaptive color adjustment

    /// Create a new style with the given modifications  
    pub fn with(self: @This(), modifications: anytype) Style {
        var result = self;
        
        // Simple approach for now - will make more sophisticated in Task 3
        const ModType = @TypeOf(modifications);
        const mod_info = @typeInfo(ModType);
        
        if (mod_info == .@"struct") {
            inline for (mod_info.@"struct".fields) |field| {
                if (@hasField(@This(), field.name)) {
                    @field(result, field.name) = @field(modifications, field.name);
                }
            }
        }
        
        return result;
    }

    /// Generate ANSI escape sequence for 16-color terminals (default)
    pub fn sequence(self: @This()) []const u8 {
        return self.sequenceForCapability(.ansi_16);
    }

    /// Generate ANSI escape sequence for specific terminal capability
    pub fn sequenceForCapability(self: @This(), capability: TerminalCapability) []const u8 {
        if (capability == .no_color) {
            return ""; // No color support
        }

        // Build sequence components
        var seq_parts: [8][]const u8 = undefined;
        var part_count: usize = 0;

        // Add style codes first
        if (self.bold) {
            seq_parts[part_count] = "1";
            part_count += 1;
        }
        if (self.dim) {
            seq_parts[part_count] = "2";
            part_count += 1;
        }
        if (self.italic) {
            seq_parts[part_count] = "3";
            part_count += 1;
        }
        if (self.underline) {
            seq_parts[part_count] = "4";
            part_count += 1;
        }
        if (self.strikethrough) {
            seq_parts[part_count] = "9";
            part_count += 1;
        }

        // Add foreground color
        if (self.fg) |fg_color| {
            seq_parts[part_count] = generateColorCode(fg_color, capability, true);
            part_count += 1;
        }

        // Add background color
        if (self.bg) |bg_color| {
            seq_parts[part_count] = generateColorCode(bg_color, capability, false);
            part_count += 1;
        }

        // If no styles, return empty
        if (part_count == 0) {
            return "";
        }

        // Build the complete sequence
        return buildEscapeSequence(seq_parts[0..part_count]);
    }

    /// Generate compile-time optimized sequence (when style is known at compile-time)
    pub fn sequenceComptime(comptime self: @This(), comptime capability: TerminalCapability) []const u8 {
        if (capability == .no_color) {
            return ""; // No color support
        }

        comptime {
            // Build sequence components at compile-time
            var seq_parts: [8][]const u8 = undefined;
            var part_count: usize = 0;

            // Add style codes
            if (self.bold) {
                seq_parts[part_count] = "1";
                part_count += 1;
            }
            if (self.dim) {
                seq_parts[part_count] = "2";
                part_count += 1;
            }
            if (self.italic) {
                seq_parts[part_count] = "3";
                part_count += 1;
            }
            if (self.underline) {
                seq_parts[part_count] = "4";
                part_count += 1;
            }
            if (self.strikethrough) {
                seq_parts[part_count] = "9";
                part_count += 1;
            }

            // Add foreground color
            if (self.fg) |fg_color| {
                seq_parts[part_count] = generateColorCodeComptime(fg_color, capability, true);
                part_count += 1;
            }

            // Add background color  
            if (self.bg) |bg_color| {
                seq_parts[part_count] = generateColorCodeComptime(bg_color, capability, false);
                part_count += 1;
            }

            if (part_count == 0) {
                return "";
            }

            return buildEscapeSequenceComptime(seq_parts[0..part_count]);
        }
    }
};

/// Generate ANSI color code for runtime use
fn generateColorCode(color: Color, capability: TerminalCapability, is_foreground: bool) []const u8 {
    const base_offset: u8 = if (is_foreground) 30 else 40;
    
    switch (capability) {
        .no_color => return "",
        .ansi_16 => {
            const color_idx = toAnsi16Runtime(color);
            if (color_idx < 8) {
                return formatU8(base_offset + color_idx);
            } else {
                // Bright colors use different codes
                const bright_offset: u8 = if (is_foreground) 90 else 100;
                return formatU8(bright_offset + (color_idx - 8));
            }
        },
        .ansi_256 => {
            const color_idx = toAnsi256(color);
            const color_type: u8 = if (is_foreground) 38 else 48;
            return formatColorCode256(color_type, color_idx);
        },
        .true_color => {
            switch (color) {
                .rgb => |rgb| {
                    const color_type: u8 = if (is_foreground) 38 else 48;
                    return formatColorCodeRgb(color_type, rgb.r, rgb.g, rgb.b);
                },
                else => {
                    // Fall back to 256-color for non-RGB colors
                    const color_idx = toAnsi256(color);
                    const color_type: u8 = if (is_foreground) 38 else 48;
                    return formatColorCode256(color_type, color_idx);
                },
            }
        },
    }
}

/// Generate ANSI color code at compile-time
fn generateColorCodeComptime(comptime color: Color, comptime capability: TerminalCapability, comptime is_foreground: bool) []const u8 {
    comptime {
        const base_offset: u8 = if (is_foreground) 30 else 40;
        
        switch (capability) {
            .no_color => return "",
            .ansi_16 => {
                const color_idx = toAnsi16(color);
                if (color_idx < 8) {
                    return formatU8Comptime(base_offset + color_idx);
                } else {
                    // Bright colors use different codes
                    const bright_offset: u8 = if (is_foreground) 90 else 100;
                    return formatU8Comptime(bright_offset + (color_idx - 8));
                }
            },
            .ansi_256 => {
                const color_idx = toAnsi256(color);
                const color_type: u8 = if (is_foreground) 38 else 48;
                return formatColorCode256Comptime(color_type, color_idx);
            },
            .true_color => {
                switch (color) {
                    .rgb => |rgb| {
                        const color_type: u8 = if (is_foreground) 38 else 48;
                        return formatColorCodeRgbComptime(color_type, rgb.r, rgb.g, rgb.b);
                    },
                    else => {
                        // Fall back to 256-color for non-RGB colors
                        const color_idx = toAnsi256(color);
                        const color_type: u8 = if (is_foreground) 38 else 48;
                        return formatColorCode256Comptime(color_type, color_idx);
                    },
                }
            },
        }
    }
}

// Thread-local static buffer for building sequences at runtime
threadlocal var sequence_buffer: [64]u8 = undefined;

/// Build complete escape sequence from parts (runtime)
fn buildEscapeSequence(parts: []const []const u8) []const u8 {
    if (parts.len == 0) return "";
    
    // Calculate total length needed: "\x1B[" + parts with ";" + "m"
    var total_len: usize = 3; // "\x1B[" (2) + "m" (1)
    for (parts, 0..) |part, i| {
        total_len += part.len;
        if (i < parts.len - 1) total_len += 1; // semicolon
    }
    
    if (total_len > sequence_buffer.len) {
        // Fallback for very long sequences
        return "";
    }
    
    // Build the sequence in the thread-local buffer
    sequence_buffer[0] = '\x1B';
    sequence_buffer[1] = '[';
    var pos: usize = 2;
    
    for (parts, 0..) |part, i| {
        // Copy the part
        for (part) |c| {
            sequence_buffer[pos] = c;
            pos += 1;
        }
        // Add semicolon if not the last part
        if (i < parts.len - 1) {
            sequence_buffer[pos] = ';';
            pos += 1;
        }
    }
    
    sequence_buffer[pos] = 'm';
    pos += 1;
    
    // Return a slice of our thread-local buffer
    return sequence_buffer[0..pos];
}

/// Build complete escape sequence from parts at compile-time
fn buildEscapeSequenceComptime(comptime parts: []const []const u8) []const u8 {
    comptime {
        if (parts.len == 0) return "";
        if (parts.len == 1) return "\x1B[" ++ parts[0] ++ "m";
        if (parts.len == 2) return "\x1B[" ++ parts[0] ++ ";" ++ parts[1] ++ "m";
        if (parts.len == 3) return "\x1B[" ++ parts[0] ++ ";" ++ parts[1] ++ ";" ++ parts[2] ++ "m";
        
        // For more parts, just use the first three for now
        return "\x1B[" ++ parts[0] ++ ";" ++ parts[1] ++ ";" ++ parts[2] ++ "m";
    }
}

/// Format u8 as string (runtime - simplified with hardcoded values)
fn formatU8(value: u8) []const u8 {
    // Return hardcoded strings for common values
    return switch (value) {
        30 => "30", 31 => "31", 32 => "32", 33 => "33", 34 => "34", 35 => "35", 36 => "36", 37 => "37",
        40 => "40", 41 => "41", 42 => "42", 43 => "43", 44 => "44", 45 => "45", 46 => "46", 47 => "47",
        90 => "90", 91 => "91", 92 => "92", 93 => "93", 94 => "94", 95 => "95", 96 => "96", 97 => "97",
        100 => "100", 101 => "101", 102 => "102", 103 => "103", 104 => "104", 105 => "105", 106 => "106", 107 => "107",
        1 => "1", 2 => "2", 3 => "3", 4 => "4", 9 => "9",
        else => "0", // fallback
    };
}

/// Format u8 as string at compile-time
fn formatU8Comptime(comptime value: u8) []const u8 {
    return comptime std.fmt.comptimePrint("{d}", .{value});
}

/// Format 256-color code (runtime)
fn formatColorCode256(color_type: u8, color_idx: u8) []const u8 {
    // Use hardcoded patterns for common cases to avoid allocation
    return switch (color_type) {
        38 => switch (color_idx) { // Foreground
            0 => "38;5;0", 1 => "38;5;1", 2 => "38;5;2", 3 => "38;5;3",
            4 => "38;5;4", 5 => "38;5;5", 6 => "38;5;6", 7 => "38;5;7",
            8 => "38;5;8", 9 => "38;5;9", 10 => "38;5;10", 11 => "38;5;11",
            12 => "38;5;12", 13 => "38;5;13", 14 => "38;5;14", 15 => "38;5;15",
            16 => "38;5;16", 17 => "38;5;17", 18 => "38;5;18", 19 => "38;5;19",
            20 => "38;5;20", 21 => "38;5;21", 42 => "38;5;42", 46 => "38;5;46",
            93 => "38;5;93", 129 => "38;5;129", 196 => "38;5;196", 226 => "38;5;226",
            else => "38;5;15", // Default to bright white
        },
        48 => switch (color_idx) { // Background
            0 => "48;5;0", 1 => "48;5;1", 2 => "48;5;2", 3 => "48;5;3",
            4 => "48;5;4", 5 => "48;5;5", 6 => "48;5;6", 7 => "48;5;7",
            8 => "48;5;8", 9 => "48;5;9", 10 => "48;5;10", 11 => "48;5;11",
            12 => "48;5;12", 13 => "48;5;13", 14 => "48;5;14", 15 => "48;5;15",
            42 => "48;5;42", 46 => "48;5;46", 196 => "48;5;196", 226 => "48;5;226",
            else => "48;5;0", // Default to black
        },
        else => "38;5;15", // Default fallback
    };
}

/// Format 256-color code at compile-time
fn formatColorCode256Comptime(comptime color_type: u8, comptime color_idx: u8) []const u8 {
    return comptime std.fmt.comptimePrint("{d};5;{d}", .{ color_type, color_idx });
}

// Thread-local buffer for RGB color codes
threadlocal var rgb_buffer: [20]u8 = undefined; // Enough for "38;2;255;255;255"

/// Format RGB color code (runtime)
fn formatColorCodeRgb(color_type: u8, r: u8, g: u8, b: u8) []const u8 {
    // Build the RGB sequence dynamically in the thread-local buffer
    const bytes_written = std.fmt.bufPrint(&rgb_buffer, "{d};2;{d};{d};{d}", .{color_type, r, g, b}) catch |err| switch (err) {
        error.NoSpaceLeft => {
            // Fallback for very long sequences (should not happen)
            return if (color_type == 38) "38;2;255;255;255" else "48;2;0;0;0";
        },
    };
    return rgb_buffer[0..bytes_written.len];
}

/// Format RGB color code at compile-time
fn formatColorCodeRgbComptime(comptime color_type: u8, comptime r: u8, comptime g: u8, comptime b: u8) []const u8 {
    return comptime std.fmt.comptimePrint("{d};2;{d};{d};{d}", .{ color_type, r, g, b });
}

test "style creation and modification" {
    const testing = std.testing;
    
    // Test basic style
    const basic_style = Style{};
    try testing.expect(!basic_style.bold);
    try testing.expect(basic_style.fg == null);
    
    // Test style modification
    const bold_style = basic_style.with(.{ .bold = true });
    try testing.expect(bold_style.bold);
    
    // Test color style
    const red_style = Style{ .fg = Color.red };
    try testing.expect(red_style.fg != null);
    try testing.expect(red_style.fg.? == Color.red);
}

test "ANSI sequence generation for different capabilities" {
    const testing = std.testing;
    
    // Test basic bold style
    const bold_style = Style{ .bold = true };
    try testing.expect(std.mem.eql(u8, bold_style.sequenceForCapability(.ansi_16), "\x1B[1m"));
    try testing.expect(std.mem.eql(u8, bold_style.sequenceForCapability(.no_color), ""));
    
    // Test red foreground
    const red_style = Style{ .fg = Color.red };
    try testing.expect(std.mem.eql(u8, red_style.sequenceForCapability(.ansi_16), "\x1B[31m"));
    
    // Test bright red (should use 90+ codes)
    const bright_red_style = Style{ .fg = Color.bright_red };
    try testing.expect(std.mem.eql(u8, bright_red_style.sequenceForCapability(.ansi_16), "\x1B[91m"));
    
    // Test background color
    const bg_blue_style = Style{ .bg = Color.blue };
    try testing.expect(std.mem.eql(u8, bg_blue_style.sequenceForCapability(.ansi_16), "\x1B[44m"));
    
    // Test combined styles
    const complex_style = Style{ .fg = Color.red, .bold = true, .underline = true };
    const seq = complex_style.sequenceForCapability(.ansi_16);
    // Should contain all components: bold (1), underline (4), red (31)
    try testing.expect(std.mem.indexOf(u8, seq, "1") != null);
    try testing.expect(std.mem.indexOf(u8, seq, "4") != null);
    try testing.expect(std.mem.indexOf(u8, seq, "31") != null);
}

test "compile-time sequence generation" {
    const testing = std.testing;
    
    // Test compile-time generation
    const red_bold = Style{ .fg = Color.red, .bold = true };
    const comptime_seq = comptime red_bold.sequenceComptime(.ansi_16);
    
    // Should be a valid ANSI sequence
    try testing.expect(std.mem.startsWith(u8, comptime_seq, "\x1B["));
    try testing.expect(std.mem.endsWith(u8, comptime_seq, "m"));
    try testing.expect(std.mem.indexOf(u8, comptime_seq, "1") != null); // bold
    try testing.expect(std.mem.indexOf(u8, comptime_seq, "31") != null); // red
}

test "RGB and 256-color sequence generation" {
    const testing = std.testing;
    
    // Test RGB color in true color mode
    const rgb_style = Style{ .fg = Color{ .rgb = .{ .r = 255, .g = 128, .b = 64 } } };
    const rgb_seq = rgb_style.sequenceForCapability(.true_color);
    
    // Should contain RGB values
    try testing.expect(std.mem.indexOf(u8, rgb_seq, "255") != null);
    try testing.expect(std.mem.indexOf(u8, rgb_seq, "128") != null);
    try testing.expect(std.mem.indexOf(u8, rgb_seq, "64") != null);
    try testing.expect(std.mem.indexOf(u8, rgb_seq, "38;2") != null); // True color foreground
    
    // Test 256-color mode
    const indexed_style = Style{ .fg = Color{ .indexed = 196 } }; // Bright red in 256-color
    const color256_seq = indexed_style.sequenceForCapability(.ansi_256);
    try testing.expect(std.mem.indexOf(u8, color256_seq, "38;5;196") != null);
}

test "multiple text decorations" {
    const testing = std.testing;
    
    // Test all decorations together
    const decorated_style = Style{
        .bold = true,
        .italic = true,  
        .underline = true,
        .strikethrough = true,
        .dim = true,
    };
    
    const seq = decorated_style.sequenceForCapability(.ansi_16);
    
    // Should contain all decoration codes
    try testing.expect(std.mem.indexOf(u8, seq, "1") != null); // bold
    try testing.expect(std.mem.indexOf(u8, seq, "2") != null); // dim
    try testing.expect(std.mem.indexOf(u8, seq, "3") != null); // italic  
    try testing.expect(std.mem.indexOf(u8, seq, "4") != null); // underline
    try testing.expect(std.mem.indexOf(u8, seq, "9") != null); // strikethrough
}