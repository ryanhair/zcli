//! Fluent API for styling content with method chaining
//!
//! Provides the main developer interface with chainable methods like:
//! styled("text").red().bold().underline()
//!
//! Semantic methods (`.success()`, `.command()`, ...) tag the content with a
//! role; the role is resolved to a concrete style at render time through the
//! active ThemeContext, so a CLI's custom palette applies automatically.

const std = @import("std");
const Color = @import("../core/color.zig").Color;
const Style = @import("../core/style.zig").Style;
const definition = @import("../definition.zig");
const SemanticRole = definition.SemanticRole;
const ThemeContext = definition.ThemeContext;

/// Generic styled wrapper that can style any content type
pub fn Styled(comptime T: type) type {
    return struct {
        const Self = @This();

        content: T,
        style: Style = .{},
        role: ?SemanticRole = null,

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

        // === Semantic Roles (Core 5) ===
        // Roles are resolved against the active palette at render time, so a
        // CLI's custom theme applies automatically. Explicit fluent settings
        // override the role's style regardless of chain order.

        /// Style for successful operations
        pub fn success(self: Self) Self {
            return self.withRole(.success);
        }

        /// Style for errors and failures
        pub fn err(self: Self) Self {
            return self.withRole(.err);
        }

        /// Style for warnings and cautions
        pub fn warning(self: Self) Self {
            return self.withRole(.warning);
        }

        /// Style for informational messages
        pub fn info(self: Self) Self {
            return self.withRole(.info);
        }

        /// Style for less important text
        pub fn muted(self: Self) Self {
            return self.withRole(.muted);
        }

        // === Extended Semantic Roles ===
        /// Style for command names (e.g., "git commit")
        pub fn command(self: Self) Self {
            return self.withRole(.command);
        }

        /// Style for flags and options (e.g., "--verbose")
        pub fn flag(self: Self) Self {
            return self.withRole(.flag);
        }

        /// Style for file paths and directories
        pub fn path(self: Self) Self {
            return self.withRole(.path);
        }

        /// Style for values and user input
        pub fn value(self: Self) Self {
            return self.withRole(.value);
        }

        /// Style for inline code snippets
        pub fn code(self: Self) Self {
            return self.withRole(.code);
        }

        /// Style for section headers and titles
        pub fn header(self: Self) Self {
            return self.withRole(.header);
        }

        /// Style for URLs and clickable items
        pub fn link(self: Self) Self {
            return self.withRole(.link);
        }

        /// Style with the theme's accent (brand) color
        pub fn accent(self: Self) Self {
            return self.withRole(.accent);
        }

        /// Set an arbitrary semantic role
        pub fn semanticRole(self: Self, role: SemanticRole) Self {
            return self.withRole(role);
        }

        /// Render styled content to writer, resolving the semantic role (if
        /// any) through the active theme's palette
        pub fn render(self: Self, writer: anytype, ctx: *const ThemeContext) !void {
            const effective_style = if (self.role) |role|
                ctx.resolve(role).merge(self.style)
            else
                self.style;

            const wrote_style = try effective_style.writeSequence(writer, ctx.capability());

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
            if (wrote_style) {
                try writer.writeAll("\x1B[0m");
            }
        }

        /// Get the styled content as a string (requires allocator)
        pub fn toString(self: Self, allocator: std.mem.Allocator, ctx: *const ThemeContext) ![]u8 {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try self.render(&aw.writer, ctx);
            return allocator.dupe(u8, aw.written());
        }

        /// Create a copy with different content but same styling
        pub fn withContent(self: Self, new_content: anytype) Styled(@TypeOf(new_content)) {
            return .{
                .content = new_content,
                .style = self.style,
                .role = self.role,
            };
        }

        /// Reset all styling to default (keeping content)
        pub fn reset(self: Self) Self {
            return .{ .content = self.content };
        }

        /// Check if any styling is applied
        pub fn hasStyle(self: Self) bool {
            const s = self.style;
            return self.role != null or s.foreground != null or s.background != null or s.bold or s.italic or s.underline or s.dim or s.strikethrough or s.reverse;
        }

        // Internal helper methods
        fn withFgColor(self: Self, color: Color) Self {
            var new_style = self.style;
            new_style.foreground = color;
            return .{
                .content = self.content,
                .style = new_style,
                .role = self.role,
            };
        }

        fn withBgColor(self: Self, color: Color) Self {
            var new_style = self.style;
            new_style.background = color;
            return .{
                .content = self.content,
                .style = new_style,
                .role = self.role,
            };
        }

        fn withStyle(self: Self, style_mods: anytype) Self {
            return .{
                .content = self.content,
                .style = self.style.with(style_mods),
                .role = self.role,
            };
        }

        fn withRole(self: Self, role: SemanticRole) Self {
            return .{
                .content = self.content,
                .style = self.style,
                .role = role,
            };
        }
    };
}

/// Create a styled wrapper for any content
pub fn styled(content: anytype) Styled(@TypeOf(content)) {
    return .{ .content = content };
}

const test_ctx = ThemeContext{
    .caps = .{ .capability = .ansi_16, .is_tty = true, .color_enabled = true },
};

test "fluent API basics" {
    const testing = std.testing;

    // Test styled creation
    const styled_text = styled("Hello");
    try testing.expect(std.mem.eql(u8, styled_text.content, "Hello"));

    // Test color chaining
    const red_text = styled("Error").red();
    try testing.expect(red_text.style.foreground != null);
    try testing.expect(red_text.style.foreground.? == Color.red);

    // Test style chaining
    const bold_red = styled("Error").red().bold();
    try testing.expect(bold_red.style.bold);
    try testing.expect(bold_red.style.foreground.? == Color.red);

    // Test render to buffer (basic)
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try styled("test").render(&aw.writer, &test_ctx);
    try testing.expectEqualStrings("test", aw.written());
}

test "toString returns the styled content" {
    const testing = std.testing;

    // Regression test: toString used to render into one writer but return the
    // owned slice of a different, empty list — always producing "".
    const result = try styled("hello").red().toString(testing.allocator, &test_ctx);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("\x1B[31mhello\x1B[0m", result);
}

test "semantic roles resolve through the active palette at render time" {
    const testing = std.testing;

    // Roles only tag; no eager style baking
    const tagged = styled("ok").success();
    try testing.expect(tagged.role == .success);
    try testing.expect(tagged.style.foreground == null);

    // Default palette: success is bold bright-ish green -> bold + color at ansi_16
    {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try tagged.render(&aw.writer, &test_ctx);
        try testing.expectEqualStrings("\x1B[1;92mok\x1B[0m", aw.written());
    }

    // Custom palette: the same tagged value renders differently
    const custom_theme = definition.Theme{
        .palette = .{ .success = .{ .foreground = .blue } },
    };
    const custom_ctx = ThemeContext{
        .theme = &custom_theme,
        .caps = .{ .capability = .ansi_16, .is_tty = true, .color_enabled = true },
    };
    {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try tagged.render(&aw.writer, &custom_ctx);
        try testing.expectEqualStrings("\x1B[34mok\x1B[0m", aw.written());
    }
}

test "explicit fluent settings override the role's style" {
    const testing = std.testing;

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    // success is green+bold in the default palette; explicit red wins,
    // the role's bold is kept, explicit underline is added
    try styled("x").success().red().underline().render(&aw.writer, &test_ctx);
    try testing.expectEqualStrings("\x1B[1;4;31mx\x1B[0m", aw.written());
}

test "no color renders plain content even with a role" {
    const testing = std.testing;

    const no_color_ctx = ThemeContext{
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = false },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try styled("plain").err().bold().render(&aw.writer, &no_color_ctx);
    try testing.expectEqualStrings("plain", aw.written());
}

test "comprehensive color methods" {
    const testing = std.testing;

    // Test all basic colors
    try testing.expect(styled("text").black().style.foreground.? == Color.black);
    try testing.expect(styled("text").red().style.foreground.? == Color.red);
    try testing.expect(styled("text").green().style.foreground.? == Color.green);
    try testing.expect(styled("text").yellow().style.foreground.? == Color.yellow);
    try testing.expect(styled("text").blue().style.foreground.? == Color.blue);
    try testing.expect(styled("text").magenta().style.foreground.? == Color.magenta);
    try testing.expect(styled("text").cyan().style.foreground.? == Color.cyan);
    try testing.expect(styled("text").white().style.foreground.? == Color.white);

    // Test bright colors
    try testing.expect(styled("text").brightRed().style.foreground.? == Color.bright_red);
    try testing.expect(styled("text").brightGreen().style.foreground.? == Color.bright_green);
    try testing.expect(styled("text").brightBlue().style.foreground.? == Color.bright_blue);

    // Test aliases
    try testing.expect(styled("text").gray().style.foreground.? == Color.bright_black);
    try testing.expect(styled("text").grey().style.foreground.? == Color.bright_black);
}

test "advanced color methods" {
    const testing = std.testing;

    // Test RGB color
    const rgb_styled = styled("rainbow").rgb(255, 128, 64);
    try testing.expect(rgb_styled.style.foreground != null);
    switch (rgb_styled.style.foreground.?) {
        .rgb => |rgb| {
            try testing.expect(rgb.r == 255);
            try testing.expect(rgb.g == 128);
            try testing.expect(rgb.b == 64);
        },
        else => try testing.expect(false), // Should be RGB
    }

    // Test hex color (compile-time)
    const hex_styled = comptime styled("hex").hex("#FF8040");
    try testing.expect(hex_styled.style.foreground != null);
    switch (hex_styled.style.foreground.?) {
        .hex => |hex| try testing.expect(std.mem.eql(u8, hex, "#FF8040")),
        else => try testing.expect(false), // Should be hex
    }

    // Test 256-color
    const indexed_styled = styled("indexed").color256(196);
    try testing.expect(indexed_styled.style.foreground != null);
    switch (indexed_styled.style.foreground.?) {
        .indexed => |idx| try testing.expect(idx == 196),
        else => try testing.expect(false), // Should be indexed
    }
}

test "text style methods" {
    const testing = std.testing;

    // Test all text decorations
    const decorated = styled("fancy").bold().dim().italic().underline().strikethrough();
    try testing.expect(decorated.style.bold);
    try testing.expect(decorated.style.dim);
    try testing.expect(decorated.style.italic);
    try testing.expect(decorated.style.underline);
    try testing.expect(decorated.style.strikethrough);
}

test "background color methods" {
    const testing = std.testing;

    // Test basic background colors
    try testing.expect(styled("text").onRed().style.background.? == Color.red);
    try testing.expect(styled("text").onBlue().style.background.? == Color.blue);
    try testing.expect(styled("text").onGreen().style.background.? == Color.green);

    // Test bright background colors
    try testing.expect(styled("text").onBrightYellow().style.background.? == Color.bright_yellow);
    try testing.expect(styled("text").onGray().style.background.? == Color.bright_black);
    try testing.expect(styled("text").onGrey().style.background.? == Color.bright_black);

    // Test advanced background colors
    const rgb_bg = styled("text").onRgb(100, 150, 200);
    switch (rgb_bg.style.background.?) {
        .rgb => |rgb| {
            try testing.expect(rgb.r == 100);
            try testing.expect(rgb.g == 150);
            try testing.expect(rgb.b == 200);
        },
        else => try testing.expect(false),
    }

    const indexed_bg = styled("text").onColor256(42);
    switch (indexed_bg.style.background.?) {
        .indexed => |idx| try testing.expect(idx == 42),
        else => try testing.expect(false),
    }
}

test "complex chaining and rendering" {
    const testing = std.testing;

    // Test complex chaining
    const complex = styled("Complex Style")
        .brightRed()
        .onBlue()
        .bold()
        .underline()
        .italic();

    try testing.expect(complex.style.foreground.? == Color.bright_red);
    try testing.expect(complex.style.background.? == Color.blue);
    try testing.expect(complex.style.bold);
    try testing.expect(complex.style.underline);
    try testing.expect(complex.style.italic);

    // Test rendering with different content types
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try styled("Hello").red().render(&aw.writer, &test_ctx);
    try testing.expect(aw.writer.end > 5); // Has styling + "Hello"
}

test "generic interface utilities" {
    const testing = std.testing;

    // Test withContent (changing content type)
    const original = styled("Hello").red().bold();
    const with_number = original.withContent(@as(i32, 42));
    try testing.expect(with_number.content == 42);
    try testing.expect(with_number.style.foreground.? == Color.red);
    try testing.expect(with_number.style.bold);

    // Test reset
    const decorated = styled("text").green().italic().underline();
    const reset_styled = decorated.reset();
    try testing.expect(std.mem.eql(u8, reset_styled.content, "text"));
    try testing.expect(!reset_styled.hasStyle());

    // Test hasStyle
    try testing.expect(!styled("plain").hasStyle());
    try testing.expect(styled("colored").red().hasStyle());
    try testing.expect(styled("bold").bold().hasStyle());
    try testing.expect(styled("bg").onBlue().hasStyle());
    try testing.expect(styled("semantic").success().hasStyle());
}
