//! Integration tests for theme - testing cross-module functionality and edge cases

const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");

fn ctxWith(capability: theme.TerminalCapability) theme.ThemeContext {
    return .{
        .caps = .{
            .capability = capability,
            .is_tty = true,
            .color_enabled = capability != .no_color,
        },
    };
}

test "full integration: styling to rendered output" {
    // Test complete flow from styling to rendered output
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const ctx = ctxWith(.ansi_16);

    // Test string content with complex styling
    const complex_string = theme.styled("Critical Error!")
        .brightRed()
        .onWhite()
        .bold()
        .underline();

    try complex_string.render(&aw.writer, &ctx);

    // Should contain the actual text
    try testing.expect(std.mem.indexOf(u8, aw.written(), "Critical Error!") != null);

    // Should be longer than just the text (due to styling)
    try testing.expect(aw.written().len > 15);
}

test "cross-capability rendering consistency" {
    // Test that different capabilities produce consistent results
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const styled_text = theme.styled("Hello World").green().bold();

    // Test with different terminal capabilities
    const capabilities = [_]theme.TerminalCapability{ .no_color, .ansi_16, .ansi_256, .true_color };

    for (capabilities) |cap| {
        aw.writer.end = 0;
        const ctx = ctxWith(cap);

        try styled_text.render(&aw.writer, &ctx);

        // All should contain the content
        try testing.expect(std.mem.indexOf(u8, aw.written(), "Hello World") != null);

        // No-color should have minimal length
        if (cap == .no_color) {
            try testing.expect(aw.written().len == 11); // Just "Hello World"
        } else {
            try testing.expect(aw.written().len > 11); // Has escape sequences
        }
    }
}

test "semantic role rendering degrades across capabilities" {
    // The same role-tagged value renders appropriately at every capability
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const tagged = theme.styled("done").success();

    // no_color: plain text
    try tagged.render(&aw.writer, &ctxWith(.no_color));
    try testing.expectEqualStrings("done", aw.written());

    // true_color: exact palette RGB
    aw.writer.end = 0;
    try tagged.render(&aw.writer, &ctxWith(.true_color));
    try testing.expectEqualStrings("\x1B[1;38;2;76;217;100mdone\x1B[0m", aw.written());
}

test "memory safety with different content types" {
    // Test that the styled wrapper works safely with various Zig types
    const ctx = ctxWith(.ansi_16);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    // Test with integer
    const int_styled = theme.styled(@as(i32, -42)).red();
    try int_styled.render(&aw.writer, &ctx);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "-42") != null);

    aw.writer.end = 0;

    // Test with float
    const float_styled = theme.styled(@as(f32, 3.14)).blue();
    try float_styled.render(&aw.writer, &ctx);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "3.14") != null or
        std.mem.indexOf(u8, aw.written(), "3") != null);

    aw.writer.end = 0;

    // Test with boolean
    const bool_styled = theme.styled(true).green();
    try bool_styled.render(&aw.writer, &ctx);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "true") != null);
}

test "style composition and interaction" {
    // Test complex style combinations
    const base = theme.styled("Test");

    // Foreground + background + multiple decorations
    const complex = base.brightYellow().onBrightBlack().bold().italic().underline();

    try testing.expect(complex.hasStyle());
    try testing.expect(std.meta.eql(complex.style.foreground.?, theme.Color.bright_yellow));
    try testing.expect(std.meta.eql(complex.style.background.?, theme.Color.bright_black));
    try testing.expect(complex.style.bold);
    try testing.expect(complex.style.italic);
    try testing.expect(complex.style.underline);
    try testing.expect(!complex.style.dim); // Should be false
    try testing.expect(!complex.style.strikethrough); // Should be false
}

test "error handling and edge cases" {
    const testing_allocator = testing.allocator;

    // Test toString with empty content
    const empty_styled = theme.styled("");
    const ctx = ctxWith(.ansi_16);
    const result = try empty_styled.toString(testing_allocator, &ctx);
    defer testing_allocator.free(result);

    try testing.expect(result.len == 0);

    // Test withContent type transformation
    const original = theme.styled("string").red();
    const transformed = original.withContent(@as(u8, 255));

    try testing.expect(transformed.content == 255);
    try testing.expect(std.meta.eql(transformed.style.foreground.?, theme.Color.red));

    // Test reset functionality
    const heavily_styled = theme.styled("text").brightMagenta().onCyan().bold().italic().underline();
    try testing.expect(heavily_styled.hasStyle());

    const reset_styled = heavily_styled.reset();
    try testing.expect(!reset_styled.hasStyle());
    try testing.expect(std.mem.eql(u8, reset_styled.content, "text"));
}

test "platform detection integration" {
    // Test that platform-specific detection functions work in integration
    const windows_cap = theme.TerminalCapability.detectWindows(&(std.process.Environ.Map.init(testing.allocator)));
    const unix_cap = theme.TerminalCapability.detectUnix(&(std.process.Environ.Map.init(testing.allocator)));
    const generic_cap = theme.TerminalCapability.detectGeneric(&(std.process.Environ.Map.init(testing.allocator)));

    // All should be valid capabilities
    const valid_caps = [_]theme.TerminalCapability{ windows_cap, unix_cap, generic_cap };

    for (valid_caps) |cap| {
        const caps = theme.Capabilities.initWithCapability(cap, std.testing.io);

        // Each should produce consistent behavior
        try testing.expect(@TypeOf(caps.supportsColor()) == bool);
        try testing.expect(@TypeOf(caps.supportsTrueColor()) == bool);
        try testing.expect(@TypeOf(caps.supports256Color()) == bool);

        // Capability string should not be empty
        const cap_str = caps.capabilityString();
        try testing.expect(cap_str.len > 0);
    }
}
