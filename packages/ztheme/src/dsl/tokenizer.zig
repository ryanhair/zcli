//! Compile-time tokenizer for markdown DSL
//!
//! Breaks down markdown source into tokens that can be parsed into an AST.
//! All tokenization happens at comptime for zero runtime overhead.

const std = @import("std");

/// Token types in the markdown DSL
pub const TokenType = enum {
    // Text content
    text, // Plain text content

    // Markdown delimiters
    asterisk, // *
    double_asterisk, // **
    triple_asterisk, // ***
    backtick, // `
    triple_backtick, // ```
    tilde, // ~
    tilde_tilde, // ~~

    // Semantic tag delimiters
    angle_open, // <
    angle_close, // >
    slash, // /

    // Special
    eof, // End of input
    newline, // \n

    pub fn isMarkdownDelimiter(self: TokenType) bool {
        return switch (self) {
            .asterisk, .double_asterisk, .triple_asterisk, .backtick, .triple_backtick, .tilde, .tilde_tilde => true,
            else => false,
        };
    }

    pub fn isSemanticDelimiter(self: TokenType) bool {
        return switch (self) {
            .angle_open, .angle_close, .slash => true,
            else => false,
        };
    }
};

/// A token in the markdown source
pub const Token = struct {
    token_type: TokenType,
    content: []const u8,
    start_pos: usize,
    end_pos: usize,

    pub fn len(self: Token) usize {
        return self.end_pos - self.start_pos;
    }

    pub fn isEmpty(self: Token) bool {
        return self.content.len == 0;
    }
};

/// Compile-time tokenizer for markdown DSL
pub const Tokenizer = struct {
    source: []const u8,
    pos: usize,

    pub fn init(comptime source: []const u8) Tokenizer {
        return Tokenizer{
            .source = source,
            .pos = 0,
        };
    }

    /// Tokenize the entire source at compile time
    pub fn tokenizeAll(comptime self: *Tokenizer) []const Token {
        // Pre-allocate a fixed-size buffer for tokens
        // Most markdown won't have more than this many tokens
        comptime var token_buffer: [1024]Token = undefined;
        comptime var token_count: usize = 0;

        while (self.pos < self.source.len) {
            const token = self.nextToken();
            if (token.token_type == .eof) break;
            if (!token.isEmpty() and token_count < token_buffer.len - 1) {
                token_buffer[token_count] = token;
                token_count += 1;
            }
        }

        // Add EOF token
        if (token_count < token_buffer.len) {
            token_buffer[token_count] = Token{
                .token_type = .eof,
                .content = "",
                .start_pos = self.pos,
                .end_pos = self.pos,
            };
            token_count += 1;
        }

        // Return only the used portion
        return token_buffer[0..token_count];
    }

    /// Get the next token from the source
    pub fn nextToken(comptime self: *Tokenizer) Token {
        if (self.pos >= self.source.len) {
            return Token{
                .token_type = .eof,
                .content = "",
                .start_pos = self.pos,
                .end_pos = self.pos,
            };
        }

        const start_pos = self.pos;
        const ch = self.source[self.pos];

        switch (ch) {
            '*' => {
                // Check for *, **, or ***
                if (self.pos + 2 < self.source.len and
                    self.source[self.pos + 1] == '*' and
                    self.source[self.pos + 2] == '*')
                {
                    self.pos += 3;
                    return Token{
                        .token_type = .triple_asterisk,
                        .content = self.source[start_pos..self.pos],
                        .start_pos = start_pos,
                        .end_pos = self.pos,
                    };
                } else if (self.pos + 1 < self.source.len and
                    self.source[self.pos + 1] == '*')
                {
                    self.pos += 2;
                    return Token{
                        .token_type = .double_asterisk,
                        .content = self.source[start_pos..self.pos],
                        .start_pos = start_pos,
                        .end_pos = self.pos,
                    };
                } else {
                    self.pos += 1;
                    return Token{
                        .token_type = .asterisk,
                        .content = self.source[start_pos..self.pos],
                        .start_pos = start_pos,
                        .end_pos = self.pos,
                    };
                }
            },
            '`' => {
                // Check for ```
                if (self.pos + 2 < self.source.len and
                    self.source[self.pos + 1] == '`' and
                    self.source[self.pos + 2] == '`')
                {
                    self.pos += 3;
                    return Token{
                        .token_type = .triple_backtick,
                        .content = self.source[start_pos..self.pos],
                        .start_pos = start_pos,
                        .end_pos = self.pos,
                    };
                } else {
                    // Single backtick
                    self.pos += 1;
                    return Token{
                        .token_type = .backtick,
                        .content = self.source[start_pos..self.pos],
                        .start_pos = start_pos,
                        .end_pos = self.pos,
                    };
                }
            },
            '~' => {
                // Check for ~~
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '~') {
                    self.pos += 2;
                    return Token{
                        .token_type = .tilde_tilde,
                        .content = self.source[start_pos..self.pos],
                        .start_pos = start_pos,
                        .end_pos = self.pos,
                    };
                } else {
                    // Single ~ for dim text
                    self.pos += 1;
                    return Token{
                        .token_type = .tilde,
                        .content = self.source[start_pos..self.pos],
                        .start_pos = start_pos,
                        .end_pos = self.pos,
                    };
                }
            },
            '<' => {
                self.pos += 1;
                return Token{
                    .token_type = .angle_open,
                    .content = self.source[start_pos..self.pos],
                    .start_pos = start_pos,
                    .end_pos = self.pos,
                };
            },
            '>' => {
                self.pos += 1;
                return Token{
                    .token_type = .angle_close,
                    .content = self.source[start_pos..self.pos],
                    .start_pos = start_pos,
                    .end_pos = self.pos,
                };
            },
            '/' => {
                self.pos += 1;
                return Token{
                    .token_type = .slash,
                    .content = self.source[start_pos..self.pos],
                    .start_pos = start_pos,
                    .end_pos = self.pos,
                };
            },
            '\n' => {
                self.pos += 1;
                return Token{
                    .token_type = .newline,
                    .content = self.source[start_pos..self.pos],
                    .start_pos = start_pos,
                    .end_pos = self.pos,
                };
            },
            else => {
                return self.readText();
            },
        }
    }

    /// Read a text token (everything until the next delimiter)
    fn readText(comptime self: *Tokenizer) Token {
        const start_pos = self.pos;

        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];

            // Stop at markdown or semantic delimiters
            switch (ch) {
                '*', '`', '~', '<', '>', '/', '\n' => break,
                else => self.pos += 1,
            }
        }

        // If we didn't advance, we have a single special character
        if (self.pos == start_pos) {
            self.pos += 1;
        }

        return Token{
            .token_type = .text,
            .content = self.source[start_pos..self.pos],
            .start_pos = start_pos,
            .end_pos = self.pos,
        };
    }
};

// Tests
test "tokenizer basic functionality" {
    comptime {
        var tokenizer = Tokenizer.init("hello world");
        const tokens = tokenizer.tokenizeAll();

        // Now spaces are included in text tokens
        // Should be: "hello world", EOF
        std.testing.expect(tokens.len == 2) catch unreachable;
        std.testing.expectEqual(TokenType.text, tokens[0].token_type) catch unreachable;
        std.testing.expectEqualStrings("hello world", tokens[0].content) catch unreachable;
        std.testing.expectEqual(TokenType.eof, tokens[1].token_type) catch unreachable;
    }
}

test "tokenizer asterisk variants" {
    comptime {
        var tokenizer = Tokenizer.init("*italic* **bold** ***both***");
        const tokens = tokenizer.tokenizeAll();

        // Should tokenize: "*", "italic", "*", " ", "**", "bold", "**", " ", "***", "both", "***", EOF
        std.testing.expect(tokens.len >= 10) catch unreachable;
        std.testing.expectEqual(TokenType.asterisk, tokens[0].token_type) catch unreachable;

        // Find the double and triple asterisk tokens
        var found_double = false;
        var found_triple = false;
        for (tokens) |token| {
            if (token.token_type == .double_asterisk) found_double = true;
            if (token.token_type == .triple_asterisk) found_triple = true;
        }
        std.testing.expect(found_double) catch unreachable;
        std.testing.expect(found_triple) catch unreachable;
    }
}

test "tokenizer semantic tags" {
    comptime {
        var tokenizer = Tokenizer.init("<success>text</success>");
        const tokens = tokenizer.tokenizeAll();

        // Should tokenize: "<", "success", ">", "text", "<", "/", "success", ">", EOF
        std.testing.expect(tokens.len == 9) catch unreachable;
        std.testing.expectEqual(TokenType.angle_open, tokens[0].token_type) catch unreachable;
        std.testing.expectEqual(TokenType.text, tokens[1].token_type) catch unreachable;
        std.testing.expectEqualStrings("success", tokens[1].content) catch unreachable;
        std.testing.expectEqual(TokenType.angle_close, tokens[2].token_type) catch unreachable;
        std.testing.expectEqual(TokenType.slash, tokens[5].token_type) catch unreachable;
    }
}

test "tokenizer code and strikethrough" {
    comptime {
        var tokenizer = Tokenizer.init("`code` ~~strike~~");
        const tokens = tokenizer.tokenizeAll();

        // Should include backtick and tilde_tilde tokens
        var found_backtick = false;
        var found_tilde_tilde = false;
        for (tokens) |token| {
            if (token.token_type == .backtick) found_backtick = true;
            if (token.token_type == .tilde_tilde) found_tilde_tilde = true;
        }

        std.testing.expect(found_backtick) catch unreachable;
        std.testing.expect(found_tilde_tilde) catch unreachable;
    }
}

test "token type classifications" {
    const asterisk_token = Token{ .token_type = .asterisk, .content = "*", .start_pos = 0, .end_pos = 1 };
    const angle_token = Token{ .token_type = .angle_open, .content = "<", .start_pos = 0, .end_pos = 1 };
    const text_token = Token{ .token_type = .text, .content = "hello", .start_pos = 0, .end_pos = 5 };

    try std.testing.expect(asterisk_token.token_type.isMarkdownDelimiter());
    try std.testing.expect(angle_token.token_type.isSemanticDelimiter());
    try std.testing.expect(!text_token.token_type.isMarkdownDelimiter());
    try std.testing.expect(!text_token.token_type.isSemanticDelimiter());
}
