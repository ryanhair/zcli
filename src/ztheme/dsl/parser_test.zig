//! Comprehensive tests for the markdown DSL parser
//!
//! This test file verifies that our parser correctly handles all Phase 1 features:
//! - Basic markdown syntax (*italic*, **bold**, ***bold italic***, `code`)
//! - Mixed content with multiple styles
//! - Edge cases and error conditions

const std = @import("std");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const AstNode = ast.AstNode;
const NodeType = ast.NodeType;

// Helper function to verify AST structure
fn expectNodeType(node: AstNode, expected_type: NodeType) !void {
    try std.testing.expectEqual(expected_type, node.node_type);
}

fn expectChildCount(node: AstNode, expected_count: usize) !void {
    try std.testing.expectEqual(expected_count, node.children.len);
}

// ====== Basic Markdown Tests (Phase 1) ======

test "parse plain text" {
    comptime {
        const result = parser.parseMarkdown("hello world");
        expectNodeType(result, .root) catch unreachable;
        std.testing.expect(result.children.len == 1) catch unreachable; // Now one token with spaces
        expectNodeType(result.children[0], .text) catch unreachable;
        std.testing.expectEqualStrings("hello world", result.children[0].content) catch unreachable;
    }
}

test "parse italic with single asterisk" {
    comptime {
        const result = parser.parseMarkdown("*italic text*");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .italic) catch unreachable;
        
        const italic_node = result.children[0];
        std.testing.expect(italic_node.children.len >= 1) catch unreachable;
        // Check that content is preserved
        var has_text = false;
        for (italic_node.children) |child| {
            if (child.node_type == .text and std.mem.indexOf(u8, child.content, "italic") != null) {
                has_text = true;
                break;
            }
        }
        std.testing.expect(has_text) catch unreachable;
    }
}

test "parse bold with double asterisk" {
    comptime {
        const result = parser.parseMarkdown("**bold text**");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .bold) catch unreachable;
        
        const bold_node = result.children[0];
        std.testing.expect(bold_node.children.len >= 1) catch unreachable;
    }
}

test "parse bold italic with triple asterisk" {
    comptime {
        const result = parser.parseMarkdown("***bold italic***");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .bold_italic) catch unreachable;
        
        const bold_italic_node = result.children[0];
        std.testing.expect(bold_italic_node.children.len >= 1) catch unreachable;
    }
}

test "parse code with backticks" {
    comptime {
        const result = parser.parseMarkdown("`code block`");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .code) catch unreachable;
        
        const code_node = result.children[0];
        std.testing.expect(code_node.children.len >= 1) catch unreachable;
    }
}

test "parse mixed markdown styles" {
    comptime {
        const result = parser.parseMarkdown("Hello *world* this is **bold** and `code`!");
        expectNodeType(result, .root) catch unreachable;
        
        // Should have multiple children with our new tokenization
        std.testing.expect(result.children.len >= 3) catch unreachable;
        
        // Find and verify each styled node
        var found_italic = false;
        var found_bold = false;
        var found_code = false;
        
        for (result.children) |child| {
            if (child.node_type == .italic) found_italic = true;
            if (child.node_type == .bold) found_bold = true;
            if (child.node_type == .code) found_code = true;
        }
        
        std.testing.expect(found_italic) catch unreachable;
        std.testing.expect(found_bold) catch unreachable;
        std.testing.expect(found_code) catch unreachable;
    }
}

test "unclosed italic treated as text" {
    comptime {
        const result = parser.parseMarkdown("*unclosed italic");
        expectNodeType(result, .root) catch unreachable;
        
        // Should be treated as plain text since there's no closing asterisk
        var all_text = true;
        for (result.children) |child| {
            if (child.node_type != .text) all_text = false;
        }
        std.testing.expect(all_text) catch unreachable;
    }
}

test "unclosed bold treated as text" {
    comptime {
        const result = parser.parseMarkdown("**unclosed bold");
        expectNodeType(result, .root) catch unreachable;
        
        // Should be treated as plain text since there's no closing double asterisk
        var all_text = true;
        for (result.children) |child| {
            if (child.node_type != .text) all_text = false;
        }
        std.testing.expect(all_text) catch unreachable;
    }
}

test "unclosed code treated as text" {
    comptime {
        const result = parser.parseMarkdown("`unclosed code");
        expectNodeType(result, .root) catch unreachable;
        
        // Should be treated as plain text since there's no closing backtick
        var all_text = true;
        for (result.children) |child| {
            if (child.node_type != .text) all_text = false;
        }
        std.testing.expect(all_text) catch unreachable;
    }
}

test "empty italic" {
    comptime {
        const result = parser.parseMarkdown("**");
        expectNodeType(result, .root) catch unreachable;
        
        // Empty delimiters should be treated as text
        var all_text = true;
        for (result.children) |child| {
            if (child.node_type != .text) all_text = false;
        }
        std.testing.expect(all_text) catch unreachable;
    }
}

test "nested styles not yet supported" {
    comptime {
        // For Phase 1, nested styles are not supported
        // This should parse the outer style only
        const result = parser.parseMarkdown("**bold with *italic* inside**");
        expectNodeType(result, .root) catch unreachable;
        
        // Should have one bold node
        std.testing.expect(result.children.len == 1) catch unreachable;
        expectNodeType(result.children[0], .bold) catch unreachable;
    }
}

test "complex real-world example" {
    comptime {
        const result = parser.parseMarkdown(
            \\Starting *process*... **Done!**
            \\Result: `success` with no errors.
        );
        expectNodeType(result, .root) catch unreachable;
        
        // Should have multiple styled elements
        var found_italic = false;
        var found_bold = false;
        var found_code = false;
        
        for (result.children) |child| {
            if (child.node_type == .italic) found_italic = true;
            if (child.node_type == .bold) found_bold = true;
            if (child.node_type == .code) found_code = true;
        }
        
        std.testing.expect(found_italic) catch unreachable;
        std.testing.expect(found_bold) catch unreachable;
        std.testing.expect(found_code) catch unreachable;
    }
}

// Performance/compile-time tests
test "parser handles long text efficiently" {
    comptime {
        // Should NOT need @setEvalBranchQuota anymore!
        const long_text = "This is a very long text without any markdown styling " ** 10;
        const result = parser.parseMarkdown(long_text);
        expectNodeType(result, .root) catch unreachable;
        // Should complete without timeout
    }
}

test "parser handles many styled segments" {
    comptime {
        // Should NOT need @setEvalBranchQuota anymore!
        const many_styles = "*a* **b** `c` *d* **e** `f` *g* **h** `i`";
        const result = parser.parseMarkdown(many_styles);
        expectNodeType(result, .root) catch unreachable;
        
        // Count styled nodes
        var italic_count: usize = 0;
        var bold_count: usize = 0;
        var code_count: usize = 0;
        
        for (result.children) |child| {
            if (child.node_type == .italic) italic_count += 1;
            if (child.node_type == .bold) bold_count += 1;
            if (child.node_type == .code) code_count += 1;
        }
        
        std.testing.expect(italic_count == 3) catch unreachable;
        std.testing.expect(bold_count == 3) catch unreachable;
        std.testing.expect(code_count == 3) catch unreachable;
    }
}

// ====== Dim Text Tests ======

test "parse dim text with single tilde" {
    comptime {
        const result = parser.parseMarkdown("~dim text~");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .dim) catch unreachable;
        
        const dim_node = result.children[0];
        std.testing.expect(dim_node.children.len >= 1) catch unreachable;
        // Check that content is preserved
        var has_text = false;
        for (dim_node.children) |child| {
            if (child.node_type == .text and std.mem.indexOf(u8, child.content, "dim") != null) {
                has_text = true;
                break;
            }
        }
        std.testing.expect(has_text) catch unreachable;
    }
}

test "dim text mixed with other styles" {
    comptime {
        const result = parser.parseMarkdown("*italic* **bold** ~dim~ `code`");
        expectNodeType(result, .root) catch unreachable;
        
        // Count different node types
        var italic_count: usize = 0;
        var bold_count: usize = 0;
        var dim_count: usize = 0;
        var code_count: usize = 0;
        
        for (result.children) |child| {
            if (child.node_type == .italic) italic_count += 1;
            if (child.node_type == .bold) bold_count += 1;
            if (child.node_type == .dim) dim_count += 1;
            if (child.node_type == .code) code_count += 1;
        }
        
        std.testing.expect(italic_count == 1) catch unreachable;
        std.testing.expect(bold_count == 1) catch unreachable;
        std.testing.expect(dim_count == 1) catch unreachable;
        std.testing.expect(code_count == 1) catch unreachable;
    }
}

test "nested dim with other styles" {
    comptime {
        const result = parser.parseMarkdown("~dim *italic inside dim*~");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .dim) catch unreachable;
        
        const dim_node = result.children[0];
        // Should have nested italic inside
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

test "dim vs strikethrough differentiation" {
    comptime {
        const result = parser.parseMarkdown("~dim~ ~~strikethrough~~");
        expectNodeType(result, .root) catch unreachable;
        
        // Should have one dim and one strikethrough node
        var dim_count: usize = 0;
        var strikethrough_count: usize = 0;
        
        for (result.children) |child| {
            if (child.node_type == .dim) dim_count += 1;
            if (child.node_type == .strikethrough) strikethrough_count += 1;
        }
        
        std.testing.expect(dim_count == 1) catch unreachable;
        std.testing.expect(strikethrough_count == 1) catch unreachable;
    }
}

test "unclosed dim text treated as literal" {
    comptime {
        const result = parser.parseMarkdown("~unclosed dim");
        expectNodeType(result, .root) catch unreachable;
        
        // Should be treated as plain text since it's not closed
        var found_literal_tilde = false;
        for (result.children) |child| {
            if (child.node_type == .text and std.mem.indexOf(u8, child.content, "~") != null) {
                found_literal_tilde = true;
                break;
            }
        }
        std.testing.expect(found_literal_tilde) catch unreachable;
    }
}

test "debug triple asterisk with double asterisk nesting" {
    comptime {
        // Simple test: triple asterisk containing double asterisk
        const result = parser.parseMarkdown("***bold **double** italic***");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .bold_italic) catch unreachable;
        
        // Should find nested bold inside
        const bold_italic_node = result.children[0];
        var found_bold = false;
        for (bold_italic_node.children) |child| {
            if (child.node_type == .bold) {
                found_bold = true;
                break;
            }
        }
        std.testing.expect(found_bold) catch unreachable;
    }
}

test "debug semantic inside triple asterisk" {
    comptime {
        // Test semantic tag inside triple asterisk
        const result = parser.parseMarkdown("***<primary>content</primary>***");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .bold_italic) catch unreachable;
        
        // Should find semantic primary inside
        const bold_italic_node = result.children[0];
        var found_primary = false;
        for (bold_italic_node.children) |child| {
            if (child.node_type == .semantic and child.semantic_role != null and child.semantic_role.? == .primary) {
                found_primary = true;
                break;
            }
        }
        std.testing.expect(found_primary) catch unreachable;
    }
}

// ====== Code Block Tests ======

test "parse code block with triple backticks" {
    comptime {
        const result = parser.parseMarkdown("```console.log('hello')```");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .code_block) catch unreachable;
        
        const code_block_node = result.children[0];
        std.testing.expect(code_block_node.children.len >= 1) catch unreachable;
        // Check that content is preserved
        var has_text = false;
        for (code_block_node.children) |child| {
            if (child.node_type == .text and std.mem.indexOf(u8, child.content, "hello") != null) {
                has_text = true;
                break;
            }
        }
        std.testing.expect(has_text) catch unreachable;
    }
}

test "code blocks preserve markdown literally" {
    comptime {
        const result = parser.parseMarkdown("```*not italic* **not bold**```");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .code_block) catch unreachable;
        
        const code_block_node = result.children[0];
        // Should only contain text nodes, no italic or bold nodes
        for (code_block_node.children) |child| {
            std.testing.expect(child.node_type == .text) catch unreachable;
        }
    }
}

test "single vs triple backticks" {
    comptime {
        const result = parser.parseMarkdown("`inline` and ```block```");
        expectNodeType(result, .root) catch unreachable;
        
        // Should have text, code (inline), text, and code_block nodes
        var inline_code_count: usize = 0;
        var code_block_count: usize = 0;
        
        for (result.children) |child| {
            if (child.node_type == .code) inline_code_count += 1;
            if (child.node_type == .code_block) code_block_count += 1;
        }
        
        std.testing.expect(inline_code_count == 1) catch unreachable;
        std.testing.expect(code_block_count == 1) catch unreachable;
    }
}

test "extremely deep nesting from ztheme-demo line 391" {
    comptime {
        // This is the updated example from line 391 (changed code to value to allow nesting)
        const result = parser.parseMarkdown("***<primary>**<value>*<accent>`ultra deep`</accent>*</value>**</primary>***");
        expectNodeType(result, .root) catch unreachable;
        
        // Should have triple asterisk (bold_italic) at the top level
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .bold_italic) catch unreachable;
        
        // Inside bold_italic should be a semantic node
        const bold_italic_node = result.children[0];
        var found_primary = false;
        for (bold_italic_node.children) |child| {
            if (child.node_type == .semantic and child.semantic_role != null and child.semantic_role.? == .primary) {
                found_primary = true;
                
                // Inside primary should be more nested content
                var found_value = false;
                for (child.children) |grandchild| {
                    if (grandchild.node_type == .semantic and grandchild.semantic_role != null and grandchild.semantic_role.? == .value) {
                        found_value = true;
                        
                        // Inside value should be italic with accent
                        var found_italic = false;
                        for (grandchild.children) |great_grandchild| {
                            if (great_grandchild.node_type == .italic) {
                                found_italic = true;
                                
                                // Inside italic should be semantic accent
                                var found_accent = false;
                                for (great_grandchild.children) |gg_grandchild| {
                                    if (gg_grandchild.node_type == .semantic and gg_grandchild.semantic_role != null and gg_grandchild.semantic_role.? == .accent) {
                                        found_accent = true;
                                        break;
                                    }
                                }
                                std.testing.expect(found_accent) catch unreachable;
                                break;
                            }
                        }
                        std.testing.expect(found_italic) catch unreachable;
                        break;
                    }
                }
                std.testing.expect(found_value) catch unreachable;
                break;
            }
        }
        std.testing.expect(found_primary) catch unreachable;
    }
}

// ====== Code Block Tests ======

test "parse code block with triple backticks" {
    comptime {
        const result = parser.parseMarkdown("```console.log('hello')```");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .code_block) catch unreachable;
        
        const code_block_node = result.children[0];
        std.testing.expect(code_block_node.children.len >= 1) catch unreachable;
        // Check that content is preserved
        var has_text = false;
        for (code_block_node.children) |child| {
            if (child.node_type == .text and std.mem.indexOf(u8, child.content, "hello") != null) {
                has_text = true;
                break;
            }
        }
        std.testing.expect(has_text) catch unreachable;
    }
}

test "code blocks preserve markdown literally" {
    comptime {
        const result = parser.parseMarkdown("```*not italic* **not bold**```");
        expectNodeType(result, .root) catch unreachable;
        expectChildCount(result, 1) catch unreachable;
        expectNodeType(result.children[0], .code_block) catch unreachable;
        
        const code_block_node = result.children[0];
        // Should only contain text nodes, no italic or bold nodes
        for (code_block_node.children) |child| {
            std.testing.expect(child.node_type == .text) catch unreachable;
        }
    }
}

test "single vs triple backticks" {
    comptime {
        const result = parser.parseMarkdown("`inline` and ```block```");
        expectNodeType(result, .root) catch unreachable;
        
        // Should have text, code (inline), text, and code_block nodes
        var inline_code_count: usize = 0;
        var code_block_count: usize = 0;
        
        for (result.children) |child| {
            if (child.node_type == .code) inline_code_count += 1;
            if (child.node_type == .code_block) code_block_count += 1;
        }
        
        std.testing.expect(inline_code_count == 1) catch unreachable;
        std.testing.expect(code_block_count == 1) catch unreachable;
    }
}