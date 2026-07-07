const std = @import("std");
const testing = std.testing;

// Import from parent module
const theme = @import("../api/fluent.zig").theme;
const Theme = @import("../detection/capability.zig").Theme;

// Test that semantic roles exist and can be used
test "semantic roles are defined" {
    const SemanticRole = @import("semantic.zig").SemanticRole;

    // Core 5 semantic roles should exist
    _ = SemanticRole.success;
    _ = SemanticRole.err; // 'error' is reserved in Zig
    _ = SemanticRole.warning;
    _ = SemanticRole.info;
    _ = SemanticRole.muted;

    // Extended semantic roles
    _ = SemanticRole.command;
    _ = SemanticRole.flag;
    _ = SemanticRole.path;
    _ = SemanticRole.value;
    _ = SemanticRole.header;
    _ = SemanticRole.link;
}

// Test that core 5 semantic methods exist on Themed interface
test "core 5 semantic methods exist" {
    const text = theme("test");

    // These should all compile (testing the API exists)
    _ = text.success();
    _ = text.err(); // 'error' is reserved
    _ = text.warning();
    _ = text.info();
    _ = text.muted();
}

// Test that semantic methods return Themed for chaining
test "semantic methods support chaining" {
    const text = theme("test");

    // Should be able to chain semantic methods with other styles
    _ = text.success().bold();
    _ = text.err().underline(); // 'error' is reserved
    _ = text.warning().italic();
    _ = text.info().dim();
    _ = text.muted().strikethrough();
}

// Test that semantic colors produce output
test "semantic methods produce colored output" {
    const allocator = testing.allocator;
    var theme_ctx = Theme.initWithCapability(.ansi_16, std.testing.io);
    theme_ctx.color_enabled = true;

    // Test success (should use green-ish color)
    {
        const success_text = theme("OK").success();
        var buf_aw: std.Io.Writer.Allocating = .init(allocator);
        defer buf_aw.deinit();
        try success_text.render(&buf_aw.writer, &theme_ctx);

        const output = buf_aw.writer.buffer[0..buf_aw.writer.end];
        // Should contain ANSI escape codes
        try testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
        // Should contain the text
        try testing.expect(std.mem.indexOf(u8, output, "OK") != null);
        // Should have reset at the end
        try testing.expect(std.mem.indexOf(u8, output, "\x1b[0m") != null);
    }

    // Test error (should use red-ish color)
    {
        const error_text = theme("FAIL").err(); // 'error' is reserved
        var buf_aw: std.Io.Writer.Allocating = .init(allocator);
        defer buf_aw.deinit();
        try error_text.render(&buf_aw.writer, &theme_ctx);

        const output = buf_aw.writer.buffer[0..buf_aw.writer.end];
        try testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
        try testing.expect(std.mem.indexOf(u8, output, "FAIL") != null);
        try testing.expect(std.mem.indexOf(u8, output, "\x1b[0m") != null);
    }
}

// Test that semantic colors respect color disabled
test "semantic methods respect color disabled" {
    const allocator = testing.allocator;
    var theme_ctx = Theme.initWithCapability(.no_color, std.testing.io);

    const success_text = theme("OK").success();
    var buf_aw: std.Io.Writer.Allocating = .init(allocator);
    defer buf_aw.deinit();
    try success_text.render(&buf_aw.writer, &theme_ctx);

    // Should only contain the text, no escape codes
    try testing.expectEqualStrings("OK", buf_aw.writer.buffer[0..buf_aw.writer.end]);
}

// Test compile-time semantic usage
test "semantic methods work at compile-time" {
    const success_comptime = comptime theme("SUCCESS").success();
    const error_comptime = comptime theme("ERROR").err(); // 'error' is reserved

    // Compile-time rendering with buffer
    const success_str = comptime blk: {
        var buf: [256]u8 = undefined;
        var stream: std.Io.Writer = .fixed(&buf);
        success_comptime.renderComptime(&stream, .ansi_16) catch unreachable;
        const written = stream.buffer[0..stream.end];
        var result: [written.len]u8 = undefined;
        @memcpy(&result, written);
        break :blk result;
    };

    const error_str = comptime blk: {
        var buf: [256]u8 = undefined;
        var stream: std.Io.Writer = .fixed(&buf);
        error_comptime.renderComptime(&stream, .ansi_16) catch unreachable;
        const written = stream.buffer[0..stream.end];
        var result: [written.len]u8 = undefined;
        @memcpy(&result, written);
        break :blk result;
    };

    // Should contain escape codes and text
    try testing.expect(success_str.len > "SUCCESS".len);
    try testing.expect(error_str.len > "ERROR".len);
}
