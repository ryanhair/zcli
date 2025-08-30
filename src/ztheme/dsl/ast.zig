//! Abstract Syntax Tree definitions for the markdown DSL
//!
//! This module defines the AST node types that represent parsed markdown
//! with semantic tags. The AST is built at compile time and used to
//! generate optimal ANSI escape sequences.

// Import SemanticRole from the real adaptive module
pub const SemanticRole = @import("../adaptive/semantic.zig").SemanticRole;

/// Node types in the markdown AST
pub const NodeType = enum {
    // Container nodes
    root,           // Top-level container
    
    // Text nodes
    text,           // Plain text content
    
    // Markdown styling nodes
    italic,         // *text*
    bold,           // **text**
    bold_italic,    // ***text***
    code,           // `text`
    code_block,     // ```text```
    dim,            // ~text~
    strikethrough,  // ~~text~~
    
    // Semantic nodes
    semantic,       // <tag>text</tag>
    
    // Future extensions
    header,         // # text (future)
    link,           // [text](url) (future)
    list_item,      // - item (future)
};

/// AST node representing a styled piece of content
pub const AstNode = struct {
    /// Type of this node
    node_type: NodeType,
    
    /// Raw text content (for text nodes)
    content: []const u8 = "",
    
    /// Semantic role (for semantic nodes)
    semantic_role: ?SemanticRole = null,
    
    /// Child nodes (for container nodes)
    children: []const AstNode = &.{},
    
    /// Get the plain text content of this node and all its children
    pub fn getTextContent(self: AstNode, allocator: std.mem.Allocator) ![]const u8 {
        switch (self.node_type) {
            .text => return self.content,
            .root, .italic, .bold, .bold_italic, .code, .code_block, .dim, .strikethrough, .semantic, .header => {
                var result = std.ArrayList(u8).init(allocator);
                defer result.deinit();
                
                if (self.content.len > 0) {
                    try result.appendSlice(self.content);
                }
                
                for (self.children) |child| {
                    const child_content = try child.getTextContent(allocator);
                    defer allocator.free(child_content);
                    try result.appendSlice(child_content);
                }
                
                return result.toOwnedSlice();
            },
            else => return "",
        }
    }
    
    /// Check if this node has any styling (non-text node)
    pub fn hasStyle(self: AstNode) bool {
        return self.node_type != .text and self.node_type != .root;
    }
    
    /// Get the semantic role if this is a semantic node
    pub fn getSemanticRole(self: AstNode) ?SemanticRole {
        return if (self.node_type == .semantic) self.semantic_role else null;
    }
};

/// Builder for constructing AST nodes at compile time
pub const AstBuilder = struct {
    /// Create a root node with children
    pub fn root(comptime children: []const AstNode) AstNode {
        return AstNode{
            .node_type = .root,
            .children = children,
        };
    }
    
    /// Create a plain text node
    pub fn text(comptime content: []const u8) AstNode {
        return AstNode{
            .node_type = .text,
            .content = content,
        };
    }
    
    /// Create an italic node
    pub fn italic(comptime children: []const AstNode) AstNode {
        return AstNode{
            .node_type = .italic,
            .children = children,
        };
    }
    
    /// Create a bold node
    pub fn bold(comptime children: []const AstNode) AstNode {
        return AstNode{
            .node_type = .bold,
            .children = children,
        };
    }
    
    /// Create a bold italic node
    pub fn boldItalic(comptime children: []const AstNode) AstNode {
        return AstNode{
            .node_type = .bold_italic,
            .children = children,
        };
    }
    
    /// Create a code node
    pub fn code(comptime children: []const AstNode) AstNode {
        return AstNode{
            .node_type = .code,
            .children = children,
        };
    }
    
    /// Create a code block node
    pub fn codeBlock(comptime children: []const AstNode) AstNode {
        return AstNode{
            .node_type = .code_block,
            .children = children,
        };
    }
    
    /// Create a dim node
    pub fn dim(comptime children: []const AstNode) AstNode {
        return AstNode{
            .node_type = .dim,
            .children = children,
        };
    }
    
    /// Create a semantic node
    pub fn semantic(comptime role: SemanticRole, comptime children: []const AstNode) AstNode {
        return AstNode{
            .node_type = .semantic,
            .semantic_role = role,
            .children = children,
        };
    }
};

const std = @import("std");

// Tests for AST functionality
test "ast node creation" {
    const text_node = AstBuilder.text("Hello");
    try std.testing.expectEqual(NodeType.text, text_node.node_type);
    try std.testing.expectEqualStrings("Hello", text_node.content);
}

test "ast node with children" {
    const italic_node = AstBuilder.italic(&.{
        AstBuilder.text("italic text")
    });
    
    try std.testing.expectEqual(NodeType.italic, italic_node.node_type);
    try std.testing.expectEqual(@as(usize, 1), italic_node.children.len);
    try std.testing.expectEqualStrings("italic text", italic_node.children[0].content);
}

test "semantic node" {
    const success_node = AstBuilder.semantic(.success, &.{
        AstBuilder.text("Success!")
    });
    
    try std.testing.expectEqual(NodeType.semantic, success_node.node_type);
    try std.testing.expectEqual(SemanticRole.success, success_node.semantic_role.?);
    try std.testing.expectEqual(@as(usize, 1), success_node.children.len);
}