//! Fluent API for intuitive theming with method chaining
//!
//! Provides the main developer interface with chainable methods like:
//! theme("text").red().bold().underline()

const std = @import("std");
const Color = @import("../core/color.zig").Color;
const Style = @import("../core/style.zig").Style;
const Theme = @import("../detection/capability.zig").Theme;
const TerminalCapability = @import("../detection/capability.zig").TerminalCapability;
const SemanticRole = @import("../adaptive/semantic.zig").SemanticRole;
const palettes = @import("../adaptive/palettes.zig");

/// Generic themed wrapper that can style any content type
pub fn Themed(comptime T: type) type {
    return struct {
        const Self = @This();

        content: T,
        style: Style = .{},

        // === Basic Colors ===
        /// Set foreground to black
        pub fn black(self: Self) Self {
            return self.withFgColor(.black);
        }

        /// Set foreground to red
        pub fn red(self: Self) Self {
            return self.withFgColor(.red);
        }

        /// Set foreground to green
        pub fn green(self: Self) Self {
            return self.withFgColor(.green);
        }

        /// Set foreground to yellow
        pub fn yellow(self: Self) Self {
            return self.withFgColor(.yellow);
        }

        /// Set foreground to blue
        pub fn blue(self: Self) Self {
            return self.withFgColor(.blue);
        }

        /// Set foreground to magenta
        pub fn magenta(self: Self) Self {
            return self.withFgColor(.magenta);
        }

        /// Set foreground to cyan
        pub fn cyan(self: Self) Self {
            return self.withFgColor(.cyan);
        }

        /// Set foreground to white
        pub fn white(self: Self) Self {
            return self.withFgColor(.white);
        }

        // === Bright Colors ===
        /// Set foreground to bright black (gray)
        pub fn brightBlack(self: Self) Self {
            return self.withFgColor(.bright_black);
        }

        /// Set foreground to bright red
        pub fn brightRed(self: Self) Self {
            return self.withFgColor(.bright_red);
        }

        /// Set foreground to bright green
        pub fn brightGreen(self: Self) Self {
            return self.withFgColor(.bright_green);
        }

        /// Set foreground to bright yellow
        pub fn brightYellow(self: Self) Self {
            return self.withFgColor(.bright_yellow);
        }

        /// Set foreground to bright blue
        pub fn brightBlue(self: Self) Self {
            return self.withFgColor(.bright_blue);
        }

        /// Set foreground to bright magenta
        pub fn brightMagenta(self: Self) Self {
            return self.withFgColor(.bright_magenta);
        }

        /// Set foreground to bright cyan
        pub fn brightCyan(self: Self) Self {
            return self.withFgColor(.bright_cyan);
        }

        /// Set foreground to bright white
        pub fn brightWhite(self: Self) Self {
            return self.withFgColor(.bright_white);
        }

        // === Convenience Aliases ===
        /// Alias for brightBlack - commonly used for gray text
        pub fn gray(self: Self) Self {
            return self.brightBlack();
        }

        /// Alias for brightBlack - alternative spelling
        pub fn grey(self: Self) Self {
            return self.brightBlack();
        }

        // === Advanced Colors ===
        /// Set foreground to RGB color
        pub fn rgb(self: Self, r: u8, g: u8, b: u8) Self {
            return self.withFgColor(.{ .rgb = .{ .r = r, .g = g, .b = b } });
        }

        /// Set foreground to hex color (compile-time only)
        pub fn hex(comptime self: Self, comptime color: []const u8) Self {
            return self.withFgColor(.{ .hex = color });
        }

        /// Set foreground to 256-color palette index
        pub fn color256(self: Self, index: u8) Self {
            return self.withFgColor(.{ .indexed = index });
        }

        // === Text Styles ===
        /// Make text bold
        pub fn bold(self: Self) Self {
            return self.withStyle(.{ .bold = true });
        }

        /// Make text dim/faint
        pub fn dim(self: Self) Self {
            return self.withStyle(.{ .dim = true });
        }

        /// Make text italic
        pub fn italic(self: Self) Self {
            return self.withStyle(.{ .italic = true });
        }

        /// Make text underlined
        pub fn underline(self: Self) Self {
            return self.withStyle(.{ .underline = true });
        }

        /// Make text strikethrough
        pub fn strikethrough(self: Self) Self {
            return self.withStyle(.{ .strikethrough = true });
        }

        // === Background Colors ===
        /// Set background to black
        pub fn onBlack(self: Self) Self {
            return self.withBgColor(.black);
        }

        /// Set background to red
        pub fn onRed(self: Self) Self {
            return self.withBgColor(.red);
        }

        /// Set background to green
        pub fn onGreen(self: Self) Self {
            return self.withBgColor(.green);
        }

        /// Set background to yellow
        pub fn onYellow(self: Self) Self {
            return self.withBgColor(.yellow);
        }

        /// Set background to blue
        pub fn onBlue(self: Self) Self {
            return self.withBgColor(.blue);
        }

        /// Set background to magenta
        pub fn onMagenta(self: Self) Self {
            return self.withBgColor(.magenta);
        }

        /// Set background to cyan
        pub fn onCyan(self: Self) Self {
            return self.withBgColor(.cyan);
        }

        /// Set background to white
        pub fn onWhite(self: Self) Self {
            return self.withBgColor(.white);
        }

        /// Set background to bright black (gray)
        pub fn onBrightBlack(self: Self) Self {
            return self.withBgColor(.bright_black);
        }

        /// Set background to bright red
        pub fn onBrightRed(self: Self) Self {
            return self.withBgColor(.bright_red);
        }

        /// Set background to bright green
        pub fn onBrightGreen(self: Self) Self {
            return self.withBgColor(.bright_green);
        }

        /// Set background to bright yellow
        pub fn onBrightYellow(self: Self) Self {
            return self.withBgColor(.bright_yellow);
        }

        /// Set background to bright blue
        pub fn onBrightBlue(self: Self) Self {
            return self.withBgColor(.bright_blue);
        }

        /// Set background to bright magenta
        pub fn onBrightMagenta(self: Self) Self {
            return self.withBgColor(.bright_magenta);
        }

        /// Set background to bright cyan
        pub fn onBrightCyan(self: Self) Self {
            return self.withBgColor(.bright_cyan);
        }

        /// Set background to bright white
        pub fn onBrightWhite(self: Self) Self {
            return self.withBgColor(.bright_white);
        }

        /// Set background to gray (alias for onBrightBlack)
        pub fn onGray(self: Self) Self {
            return self.onBrightBlack();
        }

        /// Set background to grey (alternative spelling)
        pub fn onGrey(self: Self) Self {
            return self.onBrightBlack();
        }

        /// Set background to RGB color
        pub fn onRgb(self: Self, r: u8, g: u8, b: u8) Self {
            return self.withBgColor(.{ .rgb = .{ .r = r, .g = g, .b = b } });
        }

        /// Set background to hex color (compile-time only)
        pub fn onHex(comptime self: Self, comptime color: []const u8) Self {
            return self.withBgColor(.{ .hex = color });
        }

        /// Set background to 256-color palette index
        pub fn onColor256(self: Self, index: u8) Self {
            return self.withBgColor(.{ .indexed = index });
        }

        // === Semantic Color Methods (Core 5) ===
        /// Style for successful operations (adaptive green-ish)
        pub fn success(self: Self) Self {
            return self.applySemantic(.success);
        }

        /// Style for errors and failures (adaptive red-ish)
        pub fn err(self: Self) Self {
            return self.applySemantic(.err);
        }

        /// Style for warnings and cautions (adaptive yellow-ish)
        pub fn warning(self: Self) Self {
            return self.applySemantic(.warning);
        }

        /// Style for informational messages (adaptive blue-ish)
        pub fn info(self: Self) Self {
            return self.applySemantic(.info);
        }

        /// Style for less important text (adaptive dimmed)
        pub fn muted(self: Self) Self {
            return self.applySemantic(.muted);
        }

        // === Extended Semantic Methods ===
        /// Style for command names (e.g., "git commit")
        pub fn command(self: Self) Self {
            return self.applySemantic(.command);
        }

        /// Style for flags and options (e.g., "--verbose")
        pub fn flag(self: Self) Self {
            return self.applySemantic(.flag);
        }

        /// Style for file paths and directories
        pub fn path(self: Self) Self {
            return self.applySemantic(.path);
        }

        /// Style for values and user input
        pub fn value(self: Self) Self {
            return self.applySemantic(.value);
        }

        /// Style for section headers and titles
        pub fn header(self: Self) Self {
            return self.applySemantic(.header);
        }

        /// Style for URLs and clickable items
        pub fn link(self: Self) Self {
            return self.applySemantic(.link);
        }

        /// Render styled content to writer with capability-aware styling
        pub fn render(self: Self, writer: anytype, theme_ctx: *const Theme) !void {
            const capability = theme_ctx.getCapability();

            // Apply semantic coloring if semantic role is present
            var effective_style = self.style;
            if (effective_style.semantic_role) |role| {
                effective_style.fg = palettes.getSemanticColor(role);
            }

            // Generate appropriate escape sequence for terminal capability
            const start_seq = effective_style.sequenceForCapability(capability);

            // Debug: check what sequence we got
            // std.debug.print("Start sequence: '{s}' (len={})\n", .{ start_seq, start_seq.len });

            // Apply starting style if any
            if (start_seq.len > 0) {
                try writer.writeAll(start_seq);
            }

            // Write the actual content
            const ContentType = @TypeOf(self.content);
            switch (@typeInfo(ContentType)) {
                .pointer => |ptr_info| {
                    if (ptr_info.child == u8) {
                        // Handle all string types ([]const u8, *const [N:0]u8, etc)
                        try writer.writeAll(self.content);
                    } else {
                        // Non-string pointer, format as string
                        try writer.print("{s}", .{self.content});
                    }
                },
                else => {
                    // Handle other types (numbers, bools, etc)
                    try writer.print("{any}", .{self.content});
                },
            }

            // Reset styling if we applied any
            if (start_seq.len > 0) {
                try writer.writeAll("\x1B[0m");
            }
        }

        /// Render with compile-time known capability for zero-cost styling
        pub fn renderComptime(comptime self: Self, writer: anytype, comptime capability: TerminalCapability) !void {
            const start_seq = comptime self.style.sequenceComptime(capability);

            // Apply starting style if any
            if (start_seq.len > 0) {
                try writer.writeAll(start_seq);
            }

            // Write the actual content - use same logic as runtime render method
            const ContentType = @TypeOf(self.content);
            switch (@typeInfo(ContentType)) {
                .pointer => |ptr_info| {
                    if (ptr_info.child == u8) {
                        try writer.writeAll(self.content);
                    } else {
                        try writer.print("{s}", .{self.content});
                    }
                },
                .array => |arr_info| {
                    if (arr_info.child == u8) {
                        // Handle string literals like *[8:0]u8 from "CompTime"
                        try writer.writeAll(&self.content);
                    } else {
                        try writer.print("{any}", .{self.content});
                    }
                },
                else => try writer.print("{any}", .{self.content}),
            }

            // Reset styling if we applied any
            if (start_seq.len > 0) {
                try writer.writeAll("\x1B[0m");
            }
        }

        /// Get the styled content as a string (requires allocator)
        pub fn toString(self: Self, allocator: std.mem.Allocator, theme_ctx: *const Theme) ![]u8 {
            var list = std.ArrayList(u8).init(allocator);
            try self.render(list.writer(), theme_ctx);
            return list.toOwnedSlice();
        }

        /// Create a copy with different content but same styling
        pub fn withContent(self: Self, new_content: anytype) Themed(@TypeOf(new_content)) {
            return .{
                .content = new_content,
                .style = self.style,
            };
        }

        /// Reset all styling to default (keeping content)
        pub fn reset(self: Self) Self {
            return .{
                .content = self.content,
                .style = .{},
            };
        }

        /// Check if any styling is applied
        pub fn hasStyle(self: Self) bool {
            const s = self.style;
            return s.fg != null or s.bg != null or s.bold or s.italic or s.underline or s.dim or s.strikethrough;
        }

        /// Clone the styled content
        pub fn clone(self: Self) Self {
            return .{
                .content = self.content,
                .style = self.style,
            };
        }

        // Internal helper methods
        fn withFgColor(self: Self, color: Color) Self {
            var new_style = self.style;
            new_style.fg = color;
            return .{ .content = self.content, .style = new_style };
        }

        fn withBgColor(self: Self, color: Color) Self {
            var new_style = self.style;
            new_style.bg = color;
            return .{ .content = self.content, .style = new_style };
        }

        fn withStyle(self: Self, style_mods: anytype) Self {
            return .{
                .content = self.content,
                .style = self.style.with(style_mods),
            };
        }

        fn applySemantic(self: Self, role: SemanticRole) Self {
            var new_style = self.style;

            // Apply semantic color
            // The color is applied immediately using our carefully designed palette
            new_style.fg = palettes.getSemanticColor(role);

            // Apply any default style attributes for this role
            const default_style = role.getDefaultStyle();
            if (default_style.bold) new_style.bold = true;
            if (default_style.italic) new_style.italic = true;
            if (default_style.dim) new_style.dim = true;

            // Store the semantic role for later adaptive rendering
            new_style.semantic_role = role;

            return .{ .content = self.content, .style = new_style };
        }
    };
}

/// Create a themed wrapper for any content
pub fn theme(content: anytype) Themed(@TypeOf(content)) {
    return .{ .content = content };
}

test "fluent API basics" {
    const testing = std.testing;

    // Test theme creation
    const themed_text = theme("Hello");
    try testing.expect(std.mem.eql(u8, themed_text.content, "Hello"));

    // Test color chaining
    const red_text = theme("Error").red();
    try testing.expect(red_text.style.fg != null);
    try testing.expect(red_text.style.fg.? == Color.red);

    // Test style chaining
    const bold_red = theme("Error").red().bold();
    try testing.expect(bold_red.style.bold);
    try testing.expect(bold_red.style.fg.? == Color.red);

    // Test render to buffer (basic)
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const theme_ctx = Theme.init();
    try theme("test").render(buffer.writer(), &theme_ctx);

    try testing.expect(buffer.items.len >= 4); // At least "test"
}

test "comprehensive color methods" {
    const testing = std.testing;

    // Test all basic colors
    try testing.expect(theme("text").black().style.fg.? == Color.black);
    try testing.expect(theme("text").red().style.fg.? == Color.red);
    try testing.expect(theme("text").green().style.fg.? == Color.green);
    try testing.expect(theme("text").yellow().style.fg.? == Color.yellow);
    try testing.expect(theme("text").blue().style.fg.? == Color.blue);
    try testing.expect(theme("text").magenta().style.fg.? == Color.magenta);
    try testing.expect(theme("text").cyan().style.fg.? == Color.cyan);
    try testing.expect(theme("text").white().style.fg.? == Color.white);

    // Test bright colors
    try testing.expect(theme("text").brightRed().style.fg.? == Color.bright_red);
    try testing.expect(theme("text").brightGreen().style.fg.? == Color.bright_green);
    try testing.expect(theme("text").brightBlue().style.fg.? == Color.bright_blue);

    // Test aliases
    try testing.expect(theme("text").gray().style.fg.? == Color.bright_black);
    try testing.expect(theme("text").grey().style.fg.? == Color.bright_black);
}

test "advanced color methods" {
    const testing = std.testing;

    // Test RGB color
    const rgb_themed = theme("rainbow").rgb(255, 128, 64);
    try testing.expect(rgb_themed.style.fg != null);
    switch (rgb_themed.style.fg.?) {
        .rgb => |rgb| {
            try testing.expect(rgb.r == 255);
            try testing.expect(rgb.g == 128);
            try testing.expect(rgb.b == 64);
        },
        else => try testing.expect(false), // Should be RGB
    }

    // Test hex color (compile-time)
    const hex_themed = comptime theme("hex").hex("#FF8040");
    try testing.expect(hex_themed.style.fg != null);
    switch (hex_themed.style.fg.?) {
        .hex => |hex| try testing.expect(std.mem.eql(u8, hex, "#FF8040")),
        else => try testing.expect(false), // Should be hex
    }

    // Test 256-color
    const indexed_themed = theme("indexed").color256(196);
    try testing.expect(indexed_themed.style.fg != null);
    switch (indexed_themed.style.fg.?) {
        .indexed => |idx| try testing.expect(idx == 196),
        else => try testing.expect(false), // Should be indexed
    }
}

test "text style methods" {
    const testing = std.testing;

    // Test all text decorations
    const styled = theme("fancy").bold().dim().italic().underline().strikethrough();
    try testing.expect(styled.style.bold);
    try testing.expect(styled.style.dim);
    try testing.expect(styled.style.italic);
    try testing.expect(styled.style.underline);
    try testing.expect(styled.style.strikethrough);
}

test "background color methods" {
    const testing = std.testing;

    // Test basic background colors
    try testing.expect(theme("text").onRed().style.bg.? == Color.red);
    try testing.expect(theme("text").onBlue().style.bg.? == Color.blue);
    try testing.expect(theme("text").onGreen().style.bg.? == Color.green);

    // Test bright background colors
    try testing.expect(theme("text").onBrightYellow().style.bg.? == Color.bright_yellow);
    try testing.expect(theme("text").onGray().style.bg.? == Color.bright_black);
    try testing.expect(theme("text").onGrey().style.bg.? == Color.bright_black);

    // Test advanced background colors
    const rgb_bg = theme("text").onRgb(100, 150, 200);
    switch (rgb_bg.style.bg.?) {
        .rgb => |rgb| {
            try testing.expect(rgb.r == 100);
            try testing.expect(rgb.g == 150);
            try testing.expect(rgb.b == 200);
        },
        else => try testing.expect(false),
    }

    const indexed_bg = theme("text").onColor256(42);
    switch (indexed_bg.style.bg.?) {
        .indexed => |idx| try testing.expect(idx == 42),
        else => try testing.expect(false),
    }
}

test "complex chaining and rendering" {
    const testing = std.testing;

    // Test complex chaining
    const complex = theme("Complex Style")
        .brightRed()
        .onBlue()
        .bold()
        .underline()
        .italic();

    try testing.expect(complex.style.fg.? == Color.bright_red);
    try testing.expect(complex.style.bg.? == Color.blue);
    try testing.expect(complex.style.bold);
    try testing.expect(complex.style.underline);
    try testing.expect(complex.style.italic);

    // Test rendering with different content types
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const theme_ctx = Theme{ .capability = .ansi_16, .is_tty = true, .color_enabled = true };

    // Render string content
    try theme("Hello").red().render(buffer.writer(), &theme_ctx);
    try testing.expect(buffer.items.len > 5); // Has styling + "Hello"

    // Clear and test number content
    buffer.clearRetainingCapacity();
    try theme(@as(i32, 42)).green().render(buffer.writer(), &theme_ctx);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "42") != null);
}

test "compile-time rendering optimization" {
    const testing = std.testing;

    // Test compile-time rendering
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const styled = comptime theme("CompTime").red().bold();
    try styled.renderComptime(buffer.writer(), .ansi_16);

    // Should contain red and bold codes
    try testing.expect(std.mem.indexOf(u8, buffer.items, "CompTime") != null);
    try testing.expect(buffer.items.len > 8); // Has styling + content + reset
}

test "generic interface utilities" {
    const testing = std.testing;

    // Test withContent (changing content type)
    const original = theme("Hello").red().bold();
    const with_number = original.withContent(@as(i32, 42));
    try testing.expect(with_number.content == 42);
    try testing.expect(with_number.style.fg.? == Color.red);
    try testing.expect(with_number.style.bold);

    // Test reset
    const styled = theme("text").green().italic().underline();
    const reset_styled = styled.reset();
    try testing.expect(std.mem.eql(u8, reset_styled.content, "text"));
    try testing.expect(!reset_styled.hasStyle());

    // Test hasStyle
    try testing.expect(!theme("plain").hasStyle());
    try testing.expect(theme("colored").red().hasStyle());
    try testing.expect(theme("bold").bold().hasStyle());
    try testing.expect(theme("bg").onBlue().hasStyle());

    // Test clone
    const original_themed = theme("original").cyan().bold();
    const cloned = original_themed.clone();
    try testing.expect(std.mem.eql(u8, cloned.content, original_themed.content));
    try testing.expect(std.meta.eql(cloned.style.fg.?, original_themed.style.fg.?));
    try testing.expect(cloned.style.bold == original_themed.style.bold);
}
