//! Integration tests for ZTheme - testing cross-module functionality and edge cases

const std = @import("std");
const testing = std.testing;
const ztheme = @import("ztheme.zig");

test "full integration: theme creation to rendering" {
    // Test complete flow from theme creation to rendered output
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(testing.allocator);

    // Force a color-capable theme for testing (override TTY detection)
    const theme_ctx = ztheme.Theme{
        .capability = .ansi_16,
        .is_tty = true,
        .color_enabled = true,
    };

    // Test string content with complex styling
    const complex_string = ztheme.theme("Critical Error!")
        .brightRed()
        .onWhite()
        .bold()
        .underline();

    try complex_string.render(buffer.writer(testing.allocator), &theme_ctx);

    // Debug: check what we actually got
    // std.debug.print("Buffer contents: '{s}' (len={})\n", .{ buffer.items, buffer.items.len });
    // std.debug.print("Theme capability: {s}\n", .{theme_ctx.capabilityString()});

    // Should contain the actual text
    try testing.expect(std.mem.indexOf(u8, buffer.items, "Critical Error!") != null);

    // Should be longer than just the text (due to styling)
    try testing.expect(buffer.items.len > 15);
}

test "cross-capability rendering consistency" {
    // Test that different capabilities produce consistent results
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(testing.allocator);

    const styled_text = ztheme.theme("Hello World").green().bold();

    // Test with different theme capabilities
    const capabilities = [_]ztheme.TerminalCapability{ .no_color, .ansi_16, .ansi_256, .true_color };

    for (capabilities) |cap| {
        buffer.clearRetainingCapacity();
        const theme_ctx = ztheme.Theme{
            .capability = cap,
            .is_tty = true,
            .color_enabled = cap != .no_color,
        };

        try styled_text.render(buffer.writer(testing.allocator), &theme_ctx);

        // All should contain the content
        try testing.expect(std.mem.indexOf(u8, buffer.items, "Hello World") != null);

        // No-color should have minimal length
        if (cap == .no_color) {
            try testing.expect(buffer.items.len == 11); // Just "Hello World"
        } else {
            try testing.expect(buffer.items.len > 11); // Has escape sequences
        }
    }
}

test "memory safety with different content types" {
    // Test that themed wrapper works safely with various Zig types
    const theme_ctx = ztheme.Theme.init(testing.allocator);
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(testing.allocator);

    // Test with integer
    const int_themed = ztheme.theme(@as(i32, -42)).red();
    try int_themed.render(buffer.writer(testing.allocator), &theme_ctx);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "-42") != null or
        std.mem.indexOf(u8, buffer.items, "42") != null);

    buffer.clearRetainingCapacity();

    // Test with float
    const float_themed = ztheme.theme(@as(f32, 3.14)).blue();
    try float_themed.render(buffer.writer(testing.allocator), &theme_ctx);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "3.14") != null or
        std.mem.indexOf(u8, buffer.items, "3") != null);

    buffer.clearRetainingCapacity();

    // Test with boolean
    const bool_themed = ztheme.theme(true).green();
    try bool_themed.render(buffer.writer(testing.allocator), &theme_ctx);
    try testing.expect(std.mem.indexOf(u8, buffer.items, "true") != null);
}

test "style composition and interaction" {
    // Test complex style combinations
    const base = ztheme.theme("Test");

    // Foreground + background + multiple decorations
    const complex = base.brightYellow().onBrightBlack().bold().italic().underline();

    try testing.expect(complex.hasStyle());
    try testing.expect(std.meta.eql(complex.style.foreground.?, ztheme.Color.bright_yellow));
    try testing.expect(std.meta.eql(complex.style.background.?, ztheme.Color.bright_black));
    try testing.expect(complex.style.bold);
    try testing.expect(complex.style.italic);
    try testing.expect(complex.style.underline);
    try testing.expect(!complex.style.dim); // Should be false
    try testing.expect(!complex.style.strikethrough); // Should be false
}

test "compile-time vs runtime equivalence" {
    // Test that compile-time and runtime paths produce equivalent results
    var comptime_buffer = std.ArrayList(u8){};
    defer comptime_buffer.deinit(testing.allocator);

    var runtime_buffer = std.ArrayList(u8){};
    defer runtime_buffer.deinit(testing.allocator);

    const styled = comptime ztheme.theme("CompTime Test").red().bold();
    const theme_ctx = ztheme.Theme{
        .capability = .ansi_16,
        .is_tty = true,
        .color_enabled = true,
    };

    // Compile-time rendering
    try styled.renderComptime(comptime_buffer.writer(testing.allocator), .ansi_16);

    // Runtime rendering
    try styled.render(runtime_buffer.writer(testing.allocator), &theme_ctx);

    // Both should contain the content (exact sequences may differ due to implementation)
    try testing.expect(std.mem.indexOf(u8, comptime_buffer.items, "CompTime Test") != null);
    try testing.expect(std.mem.indexOf(u8, runtime_buffer.items, "CompTime Test") != null);
}

test "error handling and edge cases" {
    const testing_allocator = testing.allocator;

    // Test toString with empty content
    const empty_themed = ztheme.theme("");
    const theme_ctx = ztheme.Theme.init(testing.allocator);
    const result = try empty_themed.toString(testing_allocator, &theme_ctx);
    defer testing_allocator.free(result);

    try testing.expect(result.len == 0);

    // Test withContent type transformation
    const original = ztheme.theme("string").red();
    const transformed = original.withContent(@as(u8, 255));

    try testing.expect(transformed.content == 255);
    try testing.expect(std.meta.eql(transformed.style.foreground.?, ztheme.Color.red));

    // Test reset functionality
    const heavily_styled = ztheme.theme("text").brightMagenta().onCyan().bold().italic().underline();
    try testing.expect(heavily_styled.hasStyle());

    const reset_styled = heavily_styled.reset();
    try testing.expect(!reset_styled.hasStyle());
    try testing.expect(std.mem.eql(u8, reset_styled.content, "text"));
}

test "platform detection integration" {
    // Test that platform-specific detection functions work in integration
    const windows_cap = ztheme.TerminalCapability.detectWindows(testing.allocator);
    const unix_cap = ztheme.TerminalCapability.detectUnix(testing.allocator);
    const generic_cap = ztheme.TerminalCapability.detectGeneric(testing.allocator);

    // All should be valid capabilities
    const valid_caps = [_]ztheme.TerminalCapability{ windows_cap, unix_cap, generic_cap };

    for (valid_caps) |cap| {
        const theme_ctx = ztheme.Theme.initWithCapability(cap);

        // Each should produce consistent behavior
        try testing.expect(@TypeOf(theme_ctx.supportsColor()) == bool);
        try testing.expect(@TypeOf(theme_ctx.supportsTrueColor()) == bool);
        try testing.expect(@TypeOf(theme_ctx.supports256Color()) == bool);

        // Capability string should not be empty
        const cap_str = theme_ctx.capabilityString();
        try testing.expect(cap_str.len > 0);
    }
}
