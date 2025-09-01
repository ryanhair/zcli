//! Markdown DSL parser and renderer for ZTheme
//!
//! This module provides the main entry point for the markdown DSL,
//! parsing markdown syntax at compile time and generating styled output.
//!
//! Performance: The parser sets a reasonable branch quota internally to handle
//! typical CLI usage including long help text (up to ~10-20k characters).
//! Only extremely long strings would require additional `@setEvalBranchQuota`.

const std = @import("std");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const AstNode = ast.AstNode;

/// Result of parsing markdown - contains the AST and provides rendering methods
pub const MarkdownStyled = struct {
    ast: AstNode,

    /// Get the plain text content without any styling
    pub fn getContent(_: MarkdownStyled) []const u8 {
        // TODO: Implement proper text extraction from AST
        return "placeholder content";
    }

    /// Render the styled content to a writer
    pub fn render(self: MarkdownStyled, writer: anytype, theme_ctx: anytype) !void {
        try renderAstNode(self.ast, writer, theme_ctx);
    }
};

/// Parse markdown syntax at compile time
pub fn md(comptime source: []const u8) MarkdownStyled {
    // The comptime parameter ensures this is evaluated at compile time
    return MarkdownStyled{
        .ast = parser.parseMarkdown(source),
    };
}

/// Render an AST node to a writer
fn renderAstNode(node: AstNode, writer: anytype, theme_ctx: anytype) !void {
    switch (node.node_type) {
        .root => {
            // Render all children
            for (node.children) |child| {
                try renderAstNode(child, writer, theme_ctx);
            }
        },
        .text => {
            // Plain text - just write it
            try writer.writeAll(node.content);
        },
        .italic => {
            // Apply italic styling using ZTheme Style system
            const Style = @import("../core/style.zig").Style;
            const style = Style{ .italic = true };
            const seq = style.sequenceForCapability(theme_ctx.getCapability());
            try writer.writeAll(seq);

            for (node.children) |child| {
                try renderAstNode(child, writer, theme_ctx);
            }
            try writer.writeAll("\x1b[0m");
        },
        .bold => {
            // Apply bold styling using ZTheme Style system
            const Style = @import("../core/style.zig").Style;
            const style = Style{ .bold = true };
            const seq = style.sequenceForCapability(theme_ctx.getCapability());
            try writer.writeAll(seq);

            for (node.children) |child| {
                try renderAstNode(child, writer, theme_ctx);
            }
            try writer.writeAll("\x1b[0m");
        },
        .bold_italic => {
            // Apply bold + italic styling using ZTheme Style system
            const Style = @import("../core/style.zig").Style;
            const style = Style{ .bold = true, .italic = true };
            const seq = style.sequenceForCapability(theme_ctx.getCapability());
            try writer.writeAll(seq);

            for (node.children) |child| {
                try renderAstNode(child, writer, theme_ctx);
            }
            try writer.writeAll("\x1b[0m");
        },
        .code => {
            // Apply code styling using a direct color (gold for code)
            const Color = @import("../core/color.zig").Color;
            const Style = @import("../core/style.zig").Style;
            const code_color = Color{ .rgb = .{ .r = 255, .g = 215, .b = 0 } }; // Gold
            const style = Style{ .fg = code_color };
            const seq = style.sequenceForCapability(theme_ctx.getCapability());
            try writer.writeAll(seq);

            for (node.children) |child| {
                try renderAstNode(child, writer, theme_ctx);
            }
            try writer.writeAll("\x1b[0m");
        },
        .code_block => {
            // Apply code block styling - same as inline code but for multiline
            const Color = @import("../core/color.zig").Color;
            const Style = @import("../core/style.zig").Style;
            const code_color = Color{ .rgb = .{ .r = 255, .g = 215, .b = 0 } }; // Gold
            const style = Style{ .fg = code_color };
            const seq = style.sequenceForCapability(theme_ctx.getCapability());
            try writer.writeAll(seq);

            for (node.children) |child| {
                try renderAstNode(child, writer, theme_ctx);
            }
            try writer.writeAll("\x1b[0m");
        },
        .dim => {
            // Apply dim styling using ZTheme Style system
            const Style = @import("../core/style.zig").Style;
            const style = Style{ .dim = true };
            const seq = style.sequenceForCapability(theme_ctx.getCapability());
            try writer.writeAll(seq);

            for (node.children) |child| {
                try renderAstNode(child, writer, theme_ctx);
            }
            try writer.writeAll("\x1b[0m");
        },
        .semantic => {
            // Apply semantic color using ZTheme palettes
            if (node.semantic_role) |role| {
                const palettes = @import("../adaptive/palettes.zig");
                const Style = @import("../core/style.zig").Style;
                const semantic_color = palettes.getSemanticColor(role);
                const style = Style{ .fg = semantic_color };
                const seq = style.sequenceForCapability(theme_ctx.getCapability());
                try writer.writeAll(seq);
            }

            for (node.children) |child| {
                try renderAstNode(child, writer, theme_ctx);
            }

            try writer.writeAll("\x1b[0m");
        },
        else => {
            // Handle other node types
            for (node.children) |child| {
                try renderAstNode(child, writer, theme_ctx);
            }
        },
    }
}

// Basic functionality tests
test "md function exists" {
    comptime {
        const styled = md("hello world");
        _ = styled;
    }
}

test "basic text rendering" {
    comptime {
        const styled = md("hello world");
        // Just verify it compiles for now
        _ = styled;
    }

    // Runtime test
    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    // Create a test AST directly for runtime testing
    const test_ast = ast.AstBuilder.root(&.{
        ast.AstBuilder.text("hello"),
        ast.AstBuilder.text(" "),
        ast.AstBuilder.text("world"),
    });

    // Create a mock theme context for testing
    const MockTheme = struct {
        pub fn getCapability(_: @This()) @import("../detection/capability.zig").TerminalCapability {
            return .no_color;
        }
    };
    const mock_theme = MockTheme{};

    try renderAstNode(test_ast, list.writer(), &mock_theme);
    try std.testing.expectEqualStrings("hello world", list.items);
}

test "italic rendering" {
    comptime {
        const styled = md("*italic*");
        // Just verify it compiles for now
        _ = styled;
    }

    // Runtime test
    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    // Create a test AST directly for runtime testing
    const test_ast = ast.AstBuilder.root(&.{
        ast.AstBuilder.italic(&.{
            ast.AstBuilder.text("italic"),
        }),
    });

    // Create a mock theme context for testing
    const MockTheme = struct {
        pub fn getCapability(_: @This()) @import("../detection/capability.zig").TerminalCapability {
            return .ansi_16; // Use ANSI 16 to get actual styling codes
        }
    };
    const mock_theme = MockTheme{};

    try renderAstNode(test_ast, list.writer(), &mock_theme);

    // Should contain some form of styling and the text content
    try std.testing.expect(std.mem.indexOf(u8, list.items, "italic") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\x1b[0m") != null);
}

test "bold rendering" {
    comptime {
        const styled = md("**bold**");
        // Just verify it compiles for now
        _ = styled;
    }

    // Runtime test
    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    // Create a test AST directly for runtime testing
    const test_ast = ast.AstBuilder.root(&.{
        ast.AstBuilder.bold(&.{
            ast.AstBuilder.text("bold"),
        }),
    });

    // Create a mock theme context for testing
    const MockTheme = struct {
        pub fn getCapability(_: @This()) @import("../detection/capability.zig").TerminalCapability {
            return .ansi_16;
        }
    };
    const mock_theme = MockTheme{};

    try renderAstNode(test_ast, list.writer(), &mock_theme);

    // Should contain some form of styling and the text content
    try std.testing.expect(std.mem.indexOf(u8, list.items, "bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\x1b[0m") != null);
}
