//! Compile-time markdown parser
//!
//! This module handles parsing of markdown syntax into an AST.

const std = @import("std");
const ast = @import("ast.zig");
const AstNode = ast.AstNode;
const AstBuilder = ast.AstBuilder;
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;
const TokenType = tokenizer.TokenType;
const SemanticRole = ast.SemanticRole;

/// Parse markdown into an AST at compile time
pub fn parseMarkdown(comptime source: []const u8) AstNode {
    comptime {
        // Set a reasonable branch quota for typical CLI usage
        // Handles strings up to ~10-20k characters without user intervention
        @setEvalBranchQuota(20000);

        var tok = Tokenizer.init(source);
        const tokens = tok.tokenizeAll();

        var parser = Parser.init(tokens);
        return parser.parse();
    }
}

/// Parsing context to track whether we should interpret markdown
const ParsingContext = enum {
    markdown, // Normal mode - interpret markdown syntax
    literal, // Literal mode - treat everything as plain text
};

/// Compile-time parser for converting tokens to AST
const Parser = struct {
    tokens: []const Token,
    pos: usize,
    context: ParsingContext,

    fn init(comptime tokens: []const Token) Parser {
        return Parser{
            .tokens = tokens,
            .pos = 0,
            .context = .markdown,
        };
    }

    /// Parse tokens into an AST
    fn parse(comptime self: *Parser) AstNode {
        var nodes: []const AstNode = &.{};

        while (self.pos < self.tokens.len and self.tokens[self.pos].token_type != .eof) {
            const node = self.parseNode();
            if (node.node_type != .text or node.content.len > 0) {
                nodes = nodes ++ &[_]AstNode{node};
            }
        }

        return AstBuilder.root(nodes);
    }

    /// Parse a single node (could be text, styled, or semantic)
    fn parseNode(comptime self: *Parser) AstNode {
        if (self.pos >= self.tokens.len) {
            return AstBuilder.text("");
        }

        const token = self.tokens[self.pos];

        switch (token.token_type) {
            .asterisk => {
                // Check if this is the start of italic
                if (self.canParseItalic()) {
                    return self.parseItalic();
                } else {
                    // Treat as plain text
                    self.pos += 1;
                    return AstBuilder.text(token.content);
                }
            },
            .tilde => {
                // Check if this is the start of dim
                if (self.canParseDim()) {
                    return self.parseDim();
                } else {
                    // Treat as plain text
                    self.pos += 1;
                    return AstBuilder.text(token.content);
                }
            },
            .double_asterisk => {
                // Check if this is the start of bold
                if (self.canParseBold()) {
                    return self.parseBold();
                } else {
                    // Treat as plain text
                    self.pos += 1;
                    return AstBuilder.text(token.content);
                }
            },
            .triple_asterisk => {
                // Check if this is the start of bold italic
                if (self.canParseBoldItalic()) {
                    return self.parseBoldItalic();
                } else {
                    // Treat as plain text
                    self.pos += 1;
                    return AstBuilder.text(token.content);
                }
            },
            .backtick => {
                // Check if this is the start of code
                if (self.canParseCode()) {
                    return self.parseCode();
                } else {
                    // Treat as plain text
                    self.pos += 1;
                    return AstBuilder.text(token.content);
                }
            },
            .triple_backtick => {
                // Check if this is the start of a code block
                if (self.canParseCodeBlock()) {
                    return self.parseCodeBlock();
                } else {
                    // Treat as plain text
                    self.pos += 1;
                    return AstBuilder.text(token.content);
                }
            },
            .angle_open => {
                // Check if this is the start of a semantic tag
                if (self.canParseSemanticTag()) {
                    return self.parseSemanticTag();
                } else {
                    // Treat as plain text
                    self.pos += 1;
                    return AstBuilder.text(token.content);
                }
            },
            .text => {
                self.pos += 1;
                return AstBuilder.text(token.content);
            },
            .slash, .angle_close, .newline => {
                // These tokens should be preserved as text when not part of a tag structure
                self.pos += 1;
                return AstBuilder.text(token.content);
            },
            else => {
                // Skip other tokens for now
                self.pos += 1;
                return AstBuilder.text("");
            },
        }
    }

    /// Check if we can parse italic at current position
    fn canParseItalic(comptime self: *Parser) bool {
        // Need at least 3 tokens: *, content, *
        if (self.pos + 2 >= self.tokens.len) return false;

        // Find closing asterisk
        var i = self.pos + 1;
        while (i < self.tokens.len) {
            if (self.tokens[i].token_type == .asterisk) {
                return true;
            }
            if (self.tokens[i].token_type == .eof) break;
            i += 1;
        }

        return false;
    }

    /// Check if we can parse dim at current position
    fn canParseDim(comptime self: *Parser) bool {
        // Need at least 3 tokens: ~, content, ~
        if (self.pos + 2 >= self.tokens.len) return false;

        // Find closing tilde
        var i = self.pos + 1;
        while (i < self.tokens.len) {
            if (self.tokens[i].token_type == .tilde) {
                return true;
            }
            if (self.tokens[i].token_type == .eof) break;
            i += 1;
        }

        return false;
    }

    /// Parse italic text between asterisks
    fn parseItalic(comptime self: *Parser) AstNode {
        self.pos += 1; // Skip opening *

        var children: []const AstNode = &.{};

        while (self.pos < self.tokens.len) {
            const token = self.tokens[self.pos];

            if (token.token_type == .asterisk) {
                self.pos += 1; // Skip closing *
                break;
            }

            if (token.token_type == .eof) break;

            // Recursively parse content to handle nested markdown and semantic tags
            const child_node = self.parseNode();
            if (child_node.node_type != .text or child_node.content.len > 0) {
                children = children ++ &[_]AstNode{child_node};
            }
        }

        return AstBuilder.italic(children);
    }

    /// Parse dim text between tildes
    fn parseDim(comptime self: *Parser) AstNode {
        self.pos += 1; // Skip opening ~

        var children: []const AstNode = &.{};

        while (self.pos < self.tokens.len) {
            const token = self.tokens[self.pos];

            if (token.token_type == .tilde) {
                self.pos += 1; // Skip closing ~
                break;
            }

            if (token.token_type == .eof) break;

            // Recursively parse content to handle nested markdown and semantic tags
            const child_node = self.parseNode();
            if (child_node.node_type != .text or child_node.content.len > 0) {
                children = children ++ &[_]AstNode{child_node};
            }
        }

        return AstBuilder.dim(children);
    }

    /// Check if we can parse bold at current position
    fn canParseBold(comptime self: *Parser) bool {
        // Need at least 3 tokens: **, content, **
        if (self.pos + 2 >= self.tokens.len) return false;

        // Find closing double asterisk
        var i = self.pos + 1;
        while (i < self.tokens.len) {
            if (self.tokens[i].token_type == .double_asterisk) {
                return true;
            }
            if (self.tokens[i].token_type == .eof) break;
            i += 1;
        }

        return false;
    }

    /// Parse bold text between double asterisks
    fn parseBold(comptime self: *Parser) AstNode {
        self.pos += 1; // Skip opening **

        var children: []const AstNode = &.{};

        while (self.pos < self.tokens.len) {
            const token = self.tokens[self.pos];

            if (token.token_type == .double_asterisk) {
                self.pos += 1; // Skip closing **
                break;
            }

            if (token.token_type == .eof) break;

            // Recursively parse content to handle nested markdown and semantic tags
            const child_node = self.parseNode();
            if (child_node.node_type != .text or child_node.content.len > 0) {
                children = children ++ &[_]AstNode{child_node};
            }
        }

        return AstBuilder.bold(children);
    }

    /// Check if we can parse bold italic at current position
    fn canParseBoldItalic(comptime self: *Parser) bool {
        // Need at least 3 tokens: ***, content, ***
        if (self.pos + 2 >= self.tokens.len) return false;

        // Find closing triple asterisk
        var i = self.pos + 1;
        while (i < self.tokens.len) {
            if (self.tokens[i].token_type == .triple_asterisk) {
                return true;
            }
            if (self.tokens[i].token_type == .eof) break;
            i += 1;
        }

        return false;
    }

    /// Parse bold italic text between triple asterisks
    fn parseBoldItalic(comptime self: *Parser) AstNode {
        self.pos += 1; // Skip opening ***

        var children: []const AstNode = &.{};

        while (self.pos < self.tokens.len) {
            const token = self.tokens[self.pos];

            if (token.token_type == .triple_asterisk) {
                self.pos += 1; // Skip closing ***
                break;
            }

            if (token.token_type == .eof) break;

            // Recursively parse content to handle nested markdown and semantic tags
            const child_node = self.parseNode();
            if (child_node.node_type != .text or child_node.content.len > 0) {
                children = children ++ &[_]AstNode{child_node};
            }
        }

        return AstBuilder.boldItalic(children);
    }

    /// Check if we can parse code at current position
    fn canParseCode(comptime self: *Parser) bool {
        // Need at least 3 tokens: `, content, `
        if (self.pos + 2 >= self.tokens.len) return false;

        // Find closing backtick
        var i = self.pos + 1;
        while (i < self.tokens.len) {
            if (self.tokens[i].token_type == .backtick) {
                return true;
            }
            if (self.tokens[i].token_type == .eof) break;
            i += 1;
        }

        return false;
    }

    /// Parse code text between backticks
    fn parseCode(comptime self: *Parser) AstNode {
        self.pos += 1; // Skip opening `

        var children: []const AstNode = &.{};

        while (self.pos < self.tokens.len) {
            const token = self.tokens[self.pos];

            if (token.token_type == .backtick) {
                self.pos += 1; // Skip closing `
                break;
            }

            if (token.token_type == .eof) break;

            // Code blocks should preserve text literally - no nested parsing
            // This maintains the behavior that code blocks are verbatim
            if (token.token_type == .text) {
                children = children ++ &[_]AstNode{AstBuilder.text(token.content)};
            }

            self.pos += 1;
        }

        return AstBuilder.code(children);
    }

    /// Check if we can parse a code block at current position
    fn canParseCodeBlock(comptime self: *Parser) bool {
        // Need at least 3 tokens: ```, content, ```
        if (self.pos + 2 >= self.tokens.len) return false;

        // Find closing triple backtick
        var i = self.pos + 1;
        while (i < self.tokens.len) {
            if (self.tokens[i].token_type == .triple_backtick) {
                return true;
            }
            if (self.tokens[i].token_type == .eof) break;
            i += 1;
        }

        return false;
    }

    /// Parse code block text between triple backticks
    fn parseCodeBlock(comptime self: *Parser) AstNode {
        self.pos += 1; // Skip opening ```

        var children: []const AstNode = &.{};

        while (self.pos < self.tokens.len) {
            const token = self.tokens[self.pos];

            if (token.token_type == .triple_backtick) {
                self.pos += 1; // Skip closing ```
                break;
            }

            if (token.token_type == .eof) break;

            // Code blocks should preserve text literally - no nested parsing
            // This maintains the behavior that code blocks are verbatim
            if (token.token_type == .text or token.token_type == .newline) {
                children = children ++ &[_]AstNode{AstBuilder.text(token.content)};
            }

            self.pos += 1;
        }

        return AstBuilder.codeBlock(children);
    }

    /// Check if we can parse a semantic tag at current position
    fn canParseSemanticTag(comptime self: *Parser) bool {
        // Need at least: <, tag_name, >, content, <, /, tag_name, >
        if (self.pos + 7 >= self.tokens.len) return false;

        // Check if we have a proper opening tag: < tag_name >
        if (self.pos + 2 >= self.tokens.len) return false;
        if (self.tokens[self.pos + 1].token_type != .text) return false;
        if (self.tokens[self.pos + 2].token_type != .angle_close) return false;

        const tag_name = self.tokens[self.pos + 1].content;

        // Find closing tag: < / tag_name >
        var i = self.pos + 3;
        while (i + 3 < self.tokens.len) {
            if (self.tokens[i].token_type == .angle_open and
                self.tokens[i + 1].token_type == .slash and
                self.tokens[i + 2].token_type == .text and
                std.mem.eql(u8, self.tokens[i + 2].content, tag_name) and
                self.tokens[i + 3].token_type == .angle_close)
            {
                return true;
            }
            i += 1;
        }

        return false;
    }

    /// Parse semantic tag: <tag>content</tag>
    fn parseSemanticTag(comptime self: *Parser) AstNode {
        self.pos += 1; // Skip <
        const tag_name = self.tokens[self.pos].content;
        self.pos += 1; // Skip tag name
        self.pos += 1; // Skip >

        // Parse semantic role from tag name
        const role = parseSemanticRole(tag_name);

        var children: []const AstNode = &.{};

        // Handle literal vs markdown content parsing
        if (role) |r| {
            if (isLiteralSemanticRole(r)) {
                // For literal semantic roles, collect all text until closing tag
                var literal_content: []const u8 = "";

                while (self.pos < self.tokens.len) {
                    const token = self.tokens[self.pos];

                    // Check for closing tag: < / tag_name >
                    if (token.token_type == .angle_open and
                        self.pos + 3 < self.tokens.len and
                        self.tokens[self.pos + 1].token_type == .slash and
                        self.tokens[self.pos + 2].token_type == .text and
                        std.mem.eql(u8, self.tokens[self.pos + 2].content, tag_name) and
                        self.tokens[self.pos + 3].token_type == .angle_close)
                    {
                        self.pos += 4; // Skip </tag>
                        break;
                    }

                    if (token.token_type == .eof) break;

                    // Collect all tokens as literal text
                    literal_content = literal_content ++ token.content;
                    self.pos += 1;
                }

                // Create a single text node with all the literal content
                if (literal_content.len > 0) {
                    children = children ++ &[_]AstNode{AstBuilder.text(literal_content)};
                }
            } else {
                // Normal markdown parsing for non-literal semantic roles
                while (self.pos < self.tokens.len) {
                    const token = self.tokens[self.pos];

                    // Check for closing tag: < / tag_name >
                    if (token.token_type == .angle_open and
                        self.pos + 3 < self.tokens.len and
                        self.tokens[self.pos + 1].token_type == .slash and
                        self.tokens[self.pos + 2].token_type == .text and
                        std.mem.eql(u8, self.tokens[self.pos + 2].content, tag_name) and
                        self.tokens[self.pos + 3].token_type == .angle_close)
                    {
                        self.pos += 4; // Skip </tag>
                        break;
                    }

                    if (token.token_type == .eof) break;

                    // Recursively parse content inside tags (allows nested markdown)
                    const child_node = self.parseNode();
                    if (child_node.node_type != .text or child_node.content.len > 0) {
                        children = children ++ &[_]AstNode{child_node};
                    }
                }
            }
        } else {
            // Unknown role - parse as markdown
            while (self.pos < self.tokens.len) {
                const token = self.tokens[self.pos];

                // Check for closing tag: < / tag_name >
                if (token.token_type == .angle_open and
                    self.pos + 3 < self.tokens.len and
                    self.tokens[self.pos + 1].token_type == .slash and
                    self.tokens[self.pos + 2].token_type == .text and
                    std.mem.eql(u8, self.tokens[self.pos + 2].content, tag_name) and
                    self.tokens[self.pos + 3].token_type == .angle_close)
                {
                    self.pos += 4; // Skip </tag>
                    break;
                }

                if (token.token_type == .eof) break;

                // Recursively parse content inside tags (allows nested markdown)
                const child_node = self.parseNode();
                if (child_node.node_type != .text or child_node.content.len > 0) {
                    children = children ++ &[_]AstNode{child_node};
                }
            }
        }

        if (role) |r| {
            return AstBuilder.semantic(r, children);
        } else {
            // Unknown semantic tag, treat as plain text
            var text_content: []const u8 = "<" ++ tag_name ++ ">";
            for (children) |child| {
                text_content = text_content ++ child.content;
            }
            text_content = text_content ++ "</" ++ tag_name ++ ">";

            return AstBuilder.text(text_content);
        }
    }

    /// Check if a semantic role should have literal content (no markdown parsing)
    fn isLiteralSemanticRole(role: SemanticRole) bool {
        return switch (role) {
            // Path semantic tags should preserve content literally
            .path => true,
            // All other semantic roles allow markdown inside
            else => false,
        };
    }

    /// Parse semantic role from tag name
    fn parseSemanticRole(comptime tag_name: []const u8) ?SemanticRole {
        if (std.mem.eql(u8, tag_name, "success")) return .success;
        if (std.mem.eql(u8, tag_name, "error")) return .err;
        if (std.mem.eql(u8, tag_name, "warning")) return .warning;
        if (std.mem.eql(u8, tag_name, "info")) return .info;
        if (std.mem.eql(u8, tag_name, "muted")) return .muted;
        if (std.mem.eql(u8, tag_name, "command")) return .command;
        if (std.mem.eql(u8, tag_name, "flag")) return .flag;
        if (std.mem.eql(u8, tag_name, "path")) return .path;
        if (std.mem.eql(u8, tag_name, "link")) return .link;
        if (std.mem.eql(u8, tag_name, "value")) return .value;
        if (std.mem.eql(u8, tag_name, "header")) return .header;
        if (std.mem.eql(u8, tag_name, "primary")) return .primary;
        if (std.mem.eql(u8, tag_name, "secondary")) return .secondary;
        if (std.mem.eql(u8, tag_name, "accent")) return .accent;
        return null;
    }
};

// Tests
test "parse plain text" {
    comptime {
        const ast_node = parseMarkdown("hello world");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len == 1) catch unreachable; // Now one token
        std.testing.expectEqualStrings("hello world", ast_node.children[0].content) catch unreachable;
    }
}

test "parse italic text" {
    comptime {
        const ast_node = parseMarkdown("*italic*");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len == 1) catch unreachable;
        std.testing.expectEqual(ast.NodeType.italic, ast_node.children[0].node_type) catch unreachable;
    }
}

test "parse bold text" {
    comptime {
        const ast_node = parseMarkdown("**bold**");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len == 1) catch unreachable;
        std.testing.expectEqual(ast.NodeType.bold, ast_node.children[0].node_type) catch unreachable;
    }
}

test "parse bold italic text" {
    comptime {
        const ast_node = parseMarkdown("***both***");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len == 1) catch unreachable;
        std.testing.expectEqual(ast.NodeType.bold_italic, ast_node.children[0].node_type) catch unreachable;
    }
}

test "parse code text" {
    comptime {
        const ast_node = parseMarkdown("`code`");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len == 1) catch unreachable;
        std.testing.expectEqual(ast.NodeType.code, ast_node.children[0].node_type) catch unreachable;
    }
}

test "parse dim text" {
    comptime {
        const ast_node = parseMarkdown("~dim text~");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len == 1) catch unreachable;
        std.testing.expectEqual(ast.NodeType.dim, ast_node.children[0].node_type) catch unreachable;
    }
}

test "parse mixed content" {
    comptime {
        const ast_node = parseMarkdown("Hello *world* this is **bold**!");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        // Should have: "Hello ", italic("world"), " this is ", bold("bold"), "!"
        std.testing.expect(ast_node.children.len >= 3) catch unreachable;
    }
}

test "parse mixed content with dim" {
    comptime {
        const ast_node = parseMarkdown("Hello *italic* ~dim~ **bold** text!");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len >= 4) catch unreachable;

        // Should contain italic, dim, and bold nodes
        var found_italic = false;
        var found_dim = false;
        var found_bold = false;
        for (ast_node.children) |child| {
            if (child.node_type == .italic) found_italic = true;
            if (child.node_type == .dim) found_dim = true;
            if (child.node_type == .bold) found_bold = true;
        }
        std.testing.expect(found_italic) catch unreachable;
        std.testing.expect(found_dim) catch unreachable;
        std.testing.expect(found_bold) catch unreachable;
    }
}

test "parse nested dim with other styles" {
    comptime {
        const ast_node = parseMarkdown("~*dim italic*~");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len == 1) catch unreachable;

        const dim_node = ast_node.children[0];
        std.testing.expectEqual(ast.NodeType.dim, dim_node.node_type) catch unreachable;

        // Should have italic inside dim
        std.testing.expect(dim_node.children.len >= 1) catch unreachable;

        var found_italic = false;
        for (dim_node.children) |child| {
            if (child.node_type == .italic) {
                found_italic = true;
                break;
            }
        }
        std.testing.expect(found_italic) catch unreachable;
    }
}

test "parse semantic success tag" {
    comptime {
        const ast_node = parseMarkdown("<success>Build passed!</success>");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len == 1) catch unreachable;
        std.testing.expectEqual(ast.NodeType.semantic, ast_node.children[0].node_type) catch unreachable;
        std.testing.expectEqual(SemanticRole.success, ast_node.children[0].semantic_role.?) catch unreachable;
    }
}

test "parse semantic error tag" {
    comptime {
        const ast_node = parseMarkdown("<error>Failed to connect</error>");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len == 1) catch unreachable;
        std.testing.expectEqual(ast.NodeType.semantic, ast_node.children[0].node_type) catch unreachable;
        std.testing.expectEqual(SemanticRole.err, ast_node.children[0].semantic_role.?) catch unreachable;
    }
}

test "parse mixed markdown and semantic" {
    comptime {
        const ast_node = parseMarkdown("**Status**: <success>All tests passed!</success>");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;

        // Should have bold "Status" and semantic success
        std.testing.expect(ast_node.children.len >= 2) catch unreachable;

        // Find the semantic node
        var found_semantic = false;
        for (ast_node.children) |child| {
            if (child.node_type == .semantic and child.semantic_role == .success) {
                found_semantic = true;
                break;
            }
        }
        std.testing.expect(found_semantic) catch unreachable;
    }
}

test "parse nested markdown inside semantic tags" {
    comptime {
        const ast_node = parseMarkdown("<success>Build **completed** successfully!</success>");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len == 1) catch unreachable;

        const semantic_node = ast_node.children[0];
        std.testing.expectEqual(ast.NodeType.semantic, semantic_node.node_type) catch unreachable;

        // Should have nested bold inside the semantic tag
        std.testing.expect(semantic_node.children.len >= 2) catch unreachable;

        // Find the bold node
        var found_bold = false;
        for (semantic_node.children) |child| {
            if (child.node_type == .bold) {
                found_bold = true;
                break;
            }
        }
        std.testing.expect(found_bold) catch unreachable;
    }
}

test "parse unknown semantic tag" {
    comptime {
        const ast_node = parseMarkdown("<unknown>Some content</unknown>");
        std.testing.expectEqual(ast.NodeType.root, ast_node.node_type) catch unreachable;
        std.testing.expect(ast_node.children.len == 1) catch unreachable;

        // Unknown tags should be treated as plain text
        std.testing.expectEqual(ast.NodeType.text, ast_node.children[0].node_type) catch unreachable;
    }
}

test "parse extended semantic roles" {
    comptime {
        // Test primary role
        const primary_ast = parseMarkdown("<primary>Main content</primary>");
        std.testing.expectEqual(ast.NodeType.root, primary_ast.node_type) catch unreachable;
        std.testing.expect(primary_ast.children.len == 1) catch unreachable;
        std.testing.expectEqual(SemanticRole.primary, primary_ast.children[0].semantic_role.?) catch unreachable;

        // Test secondary role
        const secondary_ast = parseMarkdown("<secondary>Supporting text</secondary>");
        std.testing.expectEqual(SemanticRole.secondary, secondary_ast.children[0].semantic_role.?) catch unreachable;

        // Test accent role
        const accent_ast = parseMarkdown("<accent>Highlighted text</accent>");
        std.testing.expectEqual(SemanticRole.accent, accent_ast.children[0].semantic_role.?) catch unreachable;
    }
}

test "complex nested styling" {
    comptime {
        // Test deeply nested combinations
        const complex_ast = parseMarkdown("<success>***Very bold*** and <code>**bold `code`**</code> <accent>*highlighted*</accent></success>");
        std.testing.expectEqual(ast.NodeType.root, complex_ast.node_type) catch unreachable;
        std.testing.expect(complex_ast.children.len == 1) catch unreachable;

        const success_node = complex_ast.children[0];
        std.testing.expectEqual(ast.NodeType.semantic, success_node.node_type) catch unreachable;
        std.testing.expectEqual(SemanticRole.success, success_node.semantic_role.?) catch unreachable;

        // Should contain multiple nested elements
        std.testing.expect(success_node.children.len >= 3) catch unreachable;
    }
}

test "maximum nesting depth" {
    comptime {
        // Test extreme nesting that might cause compile-time issues
        const deep_ast = parseMarkdown("***<success>**<code>*<accent>`very deep`</accent>*</code>**</success>***");
        std.testing.expectEqual(ast.NodeType.root, deep_ast.node_type) catch unreachable;

        // Verify it parses without crashing
        std.testing.expect(deep_ast.children.len == 1) catch unreachable;
    }
}

test "deep nesting bug - markdown wrapping semantic tags" {
    comptime {
        // This is the exact case from the demo that's failing
        const deep_ast = parseMarkdown("***<primary>**<code>*<accent>`ultra deep`</accent>*</code>**</primary>***");
        std.testing.expectEqual(ast.NodeType.root, deep_ast.node_type) catch unreachable;

        // The root should have one child: bold_italic (***...***)
        std.testing.expect(deep_ast.children.len == 1) catch unreachable;
        const bold_italic_node = deep_ast.children[0];
        std.testing.expectEqual(ast.NodeType.bold_italic, bold_italic_node.node_type) catch unreachable;

        // Inside bold_italic should be a semantic primary node
        std.testing.expect(bold_italic_node.children.len >= 1) catch unreachable;

        // Let's check if the first child is semantic or text
        const first_child = bold_italic_node.children[0];

        // It should be a semantic node with role primary
        std.testing.expectEqual(ast.NodeType.semantic, first_child.node_type) catch unreachable;
        std.testing.expectEqual(SemanticRole.primary, first_child.semantic_role.?) catch unreachable;
    }
}

test "semantic tags with paths containing slashes and asterisks" {
    comptime {
        // Test that paths with slashes and asterisks work inside semantic tags
        const path_ast = parseMarkdown("<path>/app/src/*.zig</path>");
        std.testing.expectEqual(ast.NodeType.root, path_ast.node_type) catch unreachable;
        std.testing.expect(path_ast.children.len == 1) catch unreachable;

        const path_node = path_ast.children[0];
        std.testing.expectEqual(ast.NodeType.semantic, path_node.node_type) catch unreachable;
        std.testing.expectEqual(SemanticRole.path, path_node.semantic_role.?) catch unreachable;

        // The path should have child nodes containing the full path including the asterisk
        // Path semantic tags should preserve asterisks literally, not as markdown
        std.testing.expect(path_node.children.len > 0) catch unreachable;

        // Check that the asterisk is preserved in the content
        var has_asterisk = false;
        for (path_node.children) |child| {
            if (child.node_type == .text and std.mem.indexOf(u8, child.content, "*") != null) {
                has_asterisk = true;
                break;
            }
        }
        std.testing.expect(has_asterisk) catch unreachable;
    }
}
