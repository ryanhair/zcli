const std = @import("std");
const md = @import("markdown_fmt");

pub fn main() !void {
    // Get stdout file
    const stdout_file = std.fs.File.stdout();

    // Create writer with a buffer
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);

    // Create a formatter - configure once, use many times
    // Pass the address of the writer's interface
    var fmt = md.formatter(&stdout_writer.interface);

    try stdout_writer.interface.writeAll("\n╔═══════════════════════════════════════════════════════════╗\n");
    try stdout_writer.interface.writeAll("║         markdown_fmt: Comprehensive Feature Demo          ║\n");
    try stdout_writer.interface.writeAll("╚═══════════════════════════════════════════════════════════╝\n\n");

    // Runtime data for examples
    const tests_passed: u32 = 247;
    const tests_failed: u32 = 3;
    const build_time: f64 = 12.4;
    const coverage: f64 = 94.2;

    try stdout_writer.interface.writeAll("═══════════════════════════════════════════════════════════\n");
    try stdout_writer.interface.writeAll("  📝 HEADERS\n");
    try stdout_writer.interface.writeAll("═══════════════════════════════════════════════════════════\n\n");

    try fmt.write(
        \\# Level 1 Header
        \\
        \\## Level 2 Header
        \\
        \\### Level 3 Header
        \\
        \\#### Level 4 Header with **bold** text
        \\
    , .{});

    try stdout_writer.interface.writeAll("\n═══════════════════════════════════════════════════════════\n");
    try stdout_writer.interface.writeAll("  📋 LISTS\n");
    try stdout_writer.interface.writeAll("═══════════════════════════════════════════════════════════\n\n");

    try fmt.write(
        \\## Unordered Lists
        \\
        \\- First item with **bold**
        \\- Second item with *italic*
        \\- Third item with `inline code`
        \\  - Nested item
        \\  - Another nested item
        \\    - Deeply nested item
        \\
        \\## Ordered Lists
        \\
        \\1. First step: Run the tests
        \\2. Second step: **{d}** tests passed
        \\3. Third step: Fix *{d}* failures
        \\   1. Review logs
        \\   2. Debug issues
        \\
    , .{ tests_passed, tests_failed });

    try stdout_writer.interface.writeAll("\n═══════════════════════════════════════════════════════════\n");
    try stdout_writer.interface.writeAll("  💻 CODE BLOCKS\n");
    try stdout_writer.interface.writeAll("═══════════════════════════════════════════════════════════\n\n");

    try fmt.write(
        \\## Fenced Code Blocks
        \\
        \\```zig
        \\const fmt = md.formatter(stdout);
        \\try fmt.write("**Hello** World!", .{});
        \\```
        \\
        \\```bash
        \\$ zig build test
        \\$ zig build run
        \\```
        \\
    , .{});

    try stdout_writer.interface.writeAll("\n═══════════════════════════════════════════════════════════\n");
    try stdout_writer.interface.writeAll("  💬 BLOCKQUOTES\n");
    try stdout_writer.interface.writeAll("═══════════════════════════════════════════════════════════\n\n");

    try fmt.write(
        \\## Quotes
        \\
        \\> This is a **blockquote** with *formatting*
        \\> It can span multiple lines
        \\
        \\> Another quote with `inline code` and ~~strikethrough~~
        \\
    , .{});

    try stdout_writer.interface.writeAll("\n═══════════════════════════════════════════════════════════\n");
    try stdout_writer.interface.writeAll("  ✏️  INLINE FORMATTING\n");
    try stdout_writer.interface.writeAll("═══════════════════════════════════════════════════════════\n\n");

    try fmt.write(
        \\**Bold text** and *italic text* and ~dim text~
        \\
        \\Inline `code` and ~~strikethrough~~ text
        \\
        \\Combined: **bold *italic* together** and `code with **bold**`
        \\
        \\Escape sequences: \*not italic\* and \**not bold\**
        \\
    , .{});

    try stdout_writer.interface.writeAll("\n═══════════════════════════════════════════════════════════\n");
    try stdout_writer.interface.writeAll("  🔗 LINKS\n");
    try stdout_writer.interface.writeAll("═══════════════════════════════════════════════════════════\n\n");

    try fmt.write(
        \\Check out [our documentation](https://example.com/docs) for more info.
        \\
        \\Visit [**GitHub**](https://github.com) or [*GitLab*](https://gitlab.com) for source code.
        \\
    , .{});

    try stdout_writer.interface.writeAll("\n═══════════════════════════════════════════════════════════\n");
    try stdout_writer.interface.writeAll("  ➖ HORIZONTAL RULES\n");
    try stdout_writer.interface.writeAll("═══════════════════════════════════════════════════════════\n\n");

    try fmt.write(
        \\Content above the rule
        \\
        \\---
        \\
        \\Content below the rule
        \\
    , .{});

    try stdout_writer.interface.writeAll("\n═══════════════════════════════════════════════════════════\n");
    try stdout_writer.interface.writeAll("  🎨 SEMANTIC TAGS\n");
    try stdout_writer.interface.writeAll("═══════════════════════════════════════════════════════════\n\n");

    try fmt.write(
        \\<success>**{d}** tests passed</success>
        \\
        \\<error>**{d}** tests failed</error>
        \\
        \\<warning>Coverage: *{d:.1}%*</warning>
        \\
        \\<info>Build time: **{d:.1}s**</info>
        \\
        \\<command>zig build test</command>
        \\
        \\<path>/path/to/file.zig</path>
        \\
        \\<code>const value = 42;</code>
        \\
    , .{ tests_passed, tests_failed, coverage, build_time });

    try stdout_writer.interface.writeAll("\n═══════════════════════════════════════════════════════════\n");
    try stdout_writer.interface.writeAll("  📊 REAL-WORLD EXAMPLE: BUILD REPORT\n");
    try stdout_writer.interface.writeAll("═══════════════════════════════════════════════════════════\n\n");

    try fmt.write(
        \\# Build Report
        \\
        \\Build completed in **{d:.1}s**
        \\
        \\## Test Results
        \\
        \\- **{d}** tests passed ✓
        \\- **{d}** tests failed ✗
        \\- Coverage: **{d:.1}%**
        \\
        \\## Failed Tests
        \\
        \\1. `auth_test.zig` - Authentication failure
        \\2. `parser_test.zig` - Parse error
        \\3. `network_test.zig` - Connection timeout
        \\
        \\## Next Steps
        \\
        \\> **Important:** Fix failing tests before deployment
        \\
        \\Run the following commands:
        \\
        \\```bash
        \\$ zig test src/auth_test.zig
        \\$ zig test src/parser_test.zig
        \\```
        \\
        \\---
        \\
        \\For more information, visit [our docs](https://example.com/docs)
        \\
    , .{ build_time, tests_passed, tests_failed, coverage });

    try stdout_writer.interface.writeAll("\n═══════════════════════════════════════════════════════════\n");
    try stdout_writer.interface.writeAll("  🔧 CUSTOM PALETTE EXAMPLE\n");
    try stdout_writer.interface.writeAll("═══════════════════════════════════════════════════════════\n\n");

    const custom_palette = md.SemanticPalette{
        .success = .{ .r = 100, .g = 255, .b = 100 }, // Bright green
        .err = .{ .r = 255, .g = 50, .b = 50 }, // Bright red
    };

    var custom_fmt = md.formatterWithPalette(&stdout_writer.interface, custom_palette);

    try custom_fmt.write(
        \\<success>Custom success color!</success>
        \\
        \\<error>Custom error color!</error>
        \\
    , .{});

    try stdout_writer.interface.writeAll("\n╔═══════════════════════════════════════════════════════════╗\n");
    try stdout_writer.interface.writeAll("║                    FORMATTER API                          ║\n");
    try stdout_writer.interface.writeAll("╠═══════════════════════════════════════════════════════════╣\n");
    try stdout_writer.interface.writeAll("║  const fmt = md.formatter(writer);                        ║\n");
    try stdout_writer.interface.writeAll("║  try fmt.write(\"**{s}**\", .{\"text\"});                     ║\n");
    try stdout_writer.interface.writeAll("║                                                           ║\n");
    try stdout_writer.interface.writeAll("║  ✨ Comptime parsing • Zero runtime overhead • Pure Zig   ║\n");
    try stdout_writer.interface.writeAll("╚═══════════════════════════════════════════════════════════╝\n\n");

    try stdout_writer.end();
}
