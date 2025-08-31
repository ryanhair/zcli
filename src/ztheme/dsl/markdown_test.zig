const std = @import("std");
const testing = std.testing;
const ztheme = @import("../ztheme.zig");

// Note: This is our comprehensive test suite for the markdown DSL
// These tests will initially fail but serve as our development target

// =============================================================================
// PHASE 1: BASIC MARKDOWN TESTS
// =============================================================================

test "basic italic text" {
    const styled = ztheme.md("*italic text*");

    const expected_content = "italic text";
    const expected_ansi_true_color = "\x1b[3mitalic text\x1b[0m";
    const expected_ansi_no_color = "italic text";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    // Test rendering across different capabilities
    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_true_color = ztheme.Theme.initWithCapability(.true_color);
    const theme_no_color = ztheme.Theme.initWithCapability(.no_color);

    try styled.render(list.writer(), &theme_true_color);
    try testing.expectEqualStrings(expected_ansi_true_color, list.items);

    list.clearRetainingCapacity();
    try styled.render(list.writer(), &theme_no_color);
    try testing.expectEqualStrings(expected_ansi_no_color, list.items);
}

test "basic bold text" {
    const styled = ztheme.md("**bold text**");

    const expected_content = "bold text";
    const expected_ansi = "\x1b[1mbold text\x1b[0m";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);
    try testing.expectEqualStrings(expected_ansi, list.items);
}

test "basic code text" {
    const styled = ztheme.md("`code text`");

    const expected_content = "code text";
    // Should render with code semantic role
    const expected_contains = "code text";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);
    try testing.expect(std.mem.indexOf(u8, list.items, expected_contains) != null);
}

test "bold italic combination" {
    const styled = ztheme.md("***bold italic***");

    const expected_content = "bold italic";
    const expected_ansi = "\x1b[1;3mbold italic\x1b[0m";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);
    try testing.expectEqualStrings(expected_ansi, list.items);
}

test "mixed text with styles" {
    const styled = ztheme.md("Hello *italic* and **bold** text!");

    const expected_content = "Hello italic and bold text!";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain both italic and bold sequences
    try testing.expect(std.mem.indexOf(u8, list.items, "\x1b[3m") != null); // italic
    try testing.expect(std.mem.indexOf(u8, list.items, "\x1b[1m") != null); // bold
    try testing.expect(std.mem.indexOf(u8, list.items, "Hello") != null);
    try testing.expect(std.mem.indexOf(u8, list.items, "text!") != null);
}

test "nested markdown styles" {
    const styled = ztheme.md("*italic with **bold inside***");

    const expected_content = "italic with bold inside";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should handle nested styles properly
    try testing.expect(std.mem.indexOf(u8, list.items, expected_content) != null);
}

// =============================================================================
// PHASE 2: SEMANTIC TAG TESTS
// =============================================================================

test "success semantic tag" {
    const styled = ztheme.md("<success>Build completed</success>");

    const expected_content = "Build completed";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain success color (RGB: 76,217,100)
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;76;217;100") != null);
    try testing.expect(std.mem.indexOf(u8, list.items, "Build completed") != null);
}

test "error semantic tag" {
    const styled = ztheme.md("<error>Connection failed</error>");

    const expected_content = "Connection failed";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain error color (RGB: 255,105,97)
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;255;105;97") != null);
    try testing.expect(std.mem.indexOf(u8, list.items, "Connection failed") != null);
}

test "warning semantic tag" {
    const styled = ztheme.md("<warning>Deprecated API</warning>");

    const expected_content = "Deprecated API";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain warning color (RGB: 255,206,84)
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;255;206;84") != null);
    try testing.expect(std.mem.indexOf(u8, list.items, "Deprecated API") != null);
}

test "info semantic tag" {
    const styled = ztheme.md("<info>Processing data</info>");

    const expected_content = "Processing data";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain info color (RGB: 116,169,250)
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;116;169;250") != null);
    try testing.expect(std.mem.indexOf(u8, list.items, "Processing data") != null);
}

test "muted semantic tag" {
    const styled = ztheme.md("<muted>Less important</muted>");

    const expected_content = "Less important";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain muted color (RGB: 156,163,175)
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;156;163;175") != null);
    try testing.expect(std.mem.indexOf(u8, list.items, "Less important") != null);
}

test "multiple semantic tags" {
    const styled = ztheme.md("<success>✓ Passed</success> <error>✗ Failed</error> <warning>⚠ Warning</warning>");

    const expected_content = "✓ Passed ✗ Failed ⚠ Warning";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain all three colors
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;76;217;100") != null); // success
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;255;105;97") != null); // error
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;255;206;84") != null); // warning
}

// =============================================================================
// PHASE 3: MIXED SYNTAX TESTS
// =============================================================================

test "markdown inside semantic tags" {
    const styled = ztheme.md("<success>**Build completed successfully!**</success>");

    const expected_content = "Build completed successfully!";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain both success color and bold styling
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;76;217;100") != null); // success color
    try testing.expect(std.mem.indexOf(u8, list.items, "1") != null); // bold
    try testing.expect(std.mem.indexOf(u8, list.items, "Build completed successfully!") != null);
}

test "semantic tags inside markdown" {
    const styled = ztheme.md("*Status: <success>Completed</success>*");

    const expected_content = "Status: Completed";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should handle both italic and success color
    try testing.expect(std.mem.indexOf(u8, list.items, "Status: Completed") != null);
}

test "complex mixed syntax" {
    const styled = ztheme.md("**Error:** <error>Failed to connect</error> to `database`");

    const expected_content = "Error: Failed to connect to database";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should handle bold, error color, and code styling
    try testing.expect(std.mem.indexOf(u8, list.items, "Error: Failed to connect to database") != null);
}

// =============================================================================
// PHASE 4: EXTENDED SEMANTIC TAGS
// =============================================================================

test "command semantic tag" {
    const styled = ztheme.md("Run <command>cargo build</command> to compile");

    const expected_content = "Run cargo build to compile";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain command color (RGB: 64,224,208)
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;64;224;208") != null);
    try testing.expect(std.mem.indexOf(u8, list.items, "Run cargo build to compile") != null);
}

test "path semantic tag" {
    const styled = ztheme.md("Output saved to <path>/usr/local/bin/app</path>");

    const expected_content = "Output saved to /usr/local/bin/app";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain path color (RGB: 100,221,221)
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;100;221;221") != null);
    try testing.expect(std.mem.indexOf(u8, list.items, "Output saved to /usr/local/bin/app") != null);
}

test "flag semantic tag" {
    const styled = ztheme.md("Use <flag>--verbose</flag> for detailed output");

    const expected_content = "Use --verbose for detailed output";

    try testing.expectEqualStrings(expected_content, styled.getContent());

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain flag color (RGB: 218,112,214)
    try testing.expect(std.mem.indexOf(u8, list.items, "38;2;218;112;214") != null);
    try testing.expect(std.mem.indexOf(u8, list.items, "Use --verbose for detailed output") != null);
}

// =============================================================================
// ERROR HANDLING TESTS
// =============================================================================

test "unclosed italic marker" {
    // This should be a compile-time error
    // const styled = ztheme.md("*unclosed italic");
    // Note: We'll implement proper compile-time error checking
}

test "unclosed bold marker" {
    // This should be a compile-time error
    // const styled = ztheme.md("**unclosed bold");
}

test "unclosed semantic tag" {
    // This should be a compile-time error
    // const styled = ztheme.md("<success>unclosed tag");
}

test "unknown semantic tag" {
    // This should be a compile-time error
    // const styled = ztheme.md("<unknown>invalid tag</unknown>");
}

test "malformed semantic tag" {
    // This should be a compile-time error
    // const styled = ztheme.md("<success unclosed>");
}

// =============================================================================
// OPTIMIZATION TESTS
// =============================================================================

test "ansi sequence optimization" {
    const styled = ztheme.md("***bold italic***");

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should use optimized combined sequence, not separate sequences
    try testing.expect(std.mem.indexOf(u8, list.items, "\x1b[1;3m") != null); // combined
    try testing.expect(std.mem.indexOf(u8, list.items, "\x1b[1m\x1b[3m") == null); // separate
}

test "minimal ansi output for no color" {
    const styled = ztheme.md("*italic* **bold** <success>success</success>");

    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.no_color);
    try styled.render(list.writer(), &theme_ctx);

    // Should contain no ANSI sequences when no color support
    try testing.expect(std.mem.indexOf(u8, list.items, "\x1b[") == null);
    try testing.expectEqualStrings("italic bold success", list.items);
}

// =============================================================================
// PERFORMANCE TESTS
// =============================================================================

test "comptime performance" {
    // Test that complex markdown doesn't blow up compile times
    const complex_styled = ztheme.md(
        \\## Build Report
        \\
        \\<success>**✓ Compilation succeeded**</success>
        \\<info>**Duration:** `2.3s`</info>
        \\<warning>**Warnings:** `3`</warning>
        \\<muted>*See build log for details*</muted>
        \\
        \\**Commands executed:**
        \\- <command>`cargo clean`</command>
        \\- <command>`cargo build --release`</command>
        \\- <command>`cargo test`</command>
        \\
        \\**Output:** <path>`target/release/app`</path>
    );

    const expected_content_contains = "Build Report";

    var buffer: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try complex_styled.render(list.writer(), &theme_ctx);

    try testing.expect(std.mem.indexOf(u8, list.items, expected_content_contains) != null);
}

// =============================================================================
// INTEGRATION TESTS
// =============================================================================

test "integration with existing ztheme api" {
    // Test that markdown DSL works alongside existing fluent API
    const manual_style = ztheme.theme("Manual styling").success().bold();
    const md_style = ztheme.md("<success>**Markdown styling**</success>");

    var buffer1: [512]u8 = undefined;
    var fba1 = std.heap.FixedBufferAllocator.init(&buffer1);
    var list1 = std.ArrayList(u8).init(fba1.allocator());

    var buffer2: [512]u8 = undefined;
    var fba2 = std.heap.FixedBufferAllocator.init(&buffer2);
    var list2 = std.ArrayList(u8).init(fba2.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try manual_style.render(list1.writer(), &theme_ctx);
    try md_style.render(list2.writer(), &theme_ctx);

    // Both should produce similar output for equivalent styling
    try testing.expect(std.mem.indexOf(u8, list1.items, "38;2;76;217;100") != null); // success color
    try testing.expect(std.mem.indexOf(u8, list2.items, "38;2;76;217;100") != null); // success color
    try testing.expect(std.mem.indexOf(u8, list1.items, "1") != null); // bold
    try testing.expect(std.mem.indexOf(u8, list2.items, "1") != null); // bold
}

test "real world cli example" {
    const cli_output = ztheme.md(
        \\<success>**✓ Build completed successfully**</success>
        \\
        \\**Summary:**
        \\- <info>Duration: `2.3s`</info>
        \\- <warning>Warnings: `3`</warning> 
        \\- <success>Tests: `45 passed`</success>
        \\
        \\**Next steps:**
        \\1. Run <command>`./app --version`</command> to verify
        \\2. Deploy with <command>`docker build -t app .`</command>
        \\3. Check logs at <path>`/var/log/app.log`</path>
    );

    var buffer: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var list = std.ArrayList(u8).init(fba.allocator());

    const theme_ctx = ztheme.Theme.initWithCapability(.true_color);
    try cli_output.render(list.writer(), &theme_ctx);

    // Should produce colorized, well-formatted CLI output
    try testing.expect(list.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, list.items, "Build completed successfully") != null);
}
