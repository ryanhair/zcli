//! ZTheme Demo CLI - Root command showcasing all ZTheme features
//!
//! This is a single-command CLI that demonstrates terminal styling capabilities

const std = @import("std");
const zcli = @import("zcli");
const ztheme = @import("ztheme");

// Command metadata for help generation
pub const meta = .{
    .description = "ZTheme Demo - Terminal Styling Showcase for Zig",
    .examples = &.{
        "ztheme-demo                    # Auto-detect terminal capabilities",
        "ztheme-demo --force-color      # Force colors even when piping output",
        "ztheme-demo --capability=16    # Test 16-color ANSI mode",
        "ztheme-demo --capability=256   # Test 256-color palette rendering",
        "ztheme-demo --capability=true  # Test true color RGB rendering",
        "ztheme-demo --no-color         # Disable all color output",
    },
};

// No positional arguments for this demo
pub const Args = zcli.NoArgs;

// Command options
pub const Options = struct {
    force_color: bool = false,
    no_color: bool = false,
    capability: ?enum {
        @"16", // 16-color ANSI
        @"256", // 256-color palette
        true, // True color (24-bit RGB)
    } = null,
};

pub fn execute(_: Args, options: Options, context: *zcli.Context) !void {
    const allocator = context.allocator;
    const writer = context.io.stdout;

    // Debug: print parsed options
    // std.debug.print("DEBUG: force_color={}, no_color={}, capability={?}\n", .{options.force_color, options.no_color, options.capability});

    // Initialize theme context based on options
    var theme_ctx = if (options.no_color)
        ztheme.Theme.initWithCapability(.no_color)
    else if (options.capability) |cap|
        // Capability override takes precedence, even with force_color
        switch (cap) {
            .@"16" => blk: {
                var t = ztheme.Theme.init();
                t.capability = .ansi_16;
                t.color_enabled = true; // Force enable if specified
                break :blk t;
            },
            .@"256" => blk: {
                var t = ztheme.Theme.init();
                t.capability = .ansi_256;
                t.color_enabled = true; // Force enable if specified
                break :blk t;
            },
            .true => blk: {
                var t = ztheme.Theme.init();
                t.capability = .true_color;
                t.color_enabled = true; // Force enable if specified
                break :blk t;
            },
        }
    else if (options.force_color)
        ztheme.Theme.initForced(true)
    else
        ztheme.Theme.init();

    // Display all demo sections
    try displayHeader(writer, &theme_ctx);
    try displayCapabilityInfo(writer, &theme_ctx);
    try displaySemanticTheming(writer, allocator, &theme_ctx);
    try displayBasicColors(writer, allocator, &theme_ctx);
    try displayBrightColors(writer, allocator, &theme_ctx);
    try displayAdvancedColors(writer, allocator, &theme_ctx);
    try displayTextStyles(writer, allocator, &theme_ctx);
    try displayBackgroundColors(writer, allocator, &theme_ctx);
    try displayComplexStyling(writer, allocator, &theme_ctx);
    try displayPracticalExamples(writer, allocator, &theme_ctx);
    try displayFooter(writer, &theme_ctx);
}

fn displayHeader(writer: anytype, theme_ctx: *const ztheme.Theme) !void {
    try writer.writeAll("\n");
    try writer.writeAll("╭────────────────────────────────────────────────────────────╮\n");
    try writer.writeAll("│                     ");

    const title = ztheme.theme("ZTheme Demo CLI").brightCyan().bold();
    try title.render(writer, theme_ctx);

    try writer.writeAll("                        │\n");
    try writer.writeAll("│           Powerful Terminal Styling for Zig                │\n");
    try writer.writeAll("╰────────────────────────────────────────────────────────────╯\n\n");
}

fn displayCapabilityInfo(writer: anytype, theme_ctx: *const ztheme.Theme) !void {
    try writer.writeAll("🔧 Terminal Capability Detection:\n");

    const cap_str = theme_ctx.capabilityString();
    const supports_color = if (theme_ctx.supportsColor()) "✅ Yes" else "❌ No";
    const supports_256 = if (theme_ctx.supports256Color()) "✅ Yes" else "❌ No";
    const supports_true = if (theme_ctx.supportsTrueColor()) "✅ Yes" else "❌ No";
    const is_tty = if (theme_ctx.is_tty) "✅ Yes" else "❌ No";
    try writer.print("   Detected Capability:  {s}\n", .{cap_str});
    try writer.print("   TTY Output:           {s}\n", .{is_tty});
    try writer.print("   Color Support:        {s}\n", .{supports_color});
    try writer.print("   256-Color Support:    {s}\n", .{supports_256});
    try writer.print("   True Color Support:   {s}\n", .{supports_true});
    try writer.writeAll("\n");
}

fn displaySemanticTheming(writer: anytype, _: std.mem.Allocator, theme_ctx: *const ztheme.Theme) !void {
    try writer.writeAll("🎯 Semantic Theming:\n");

    // Core 5 semantic roles
    try writer.writeAll("   Core Semantic Roles:\n   ");

    const success = ztheme.theme("✓ Success").success();
    const err = ztheme.theme("✗ Error").err();
    const warning = ztheme.theme("⚠ Warning").warning();
    const info = ztheme.theme("ℹ Info").info();
    const muted = ztheme.theme("Muted").muted();

    try success.render(writer, theme_ctx);
    try writer.writeAll("  ");
    try err.render(writer, theme_ctx);
    try writer.writeAll("  ");
    try warning.render(writer, theme_ctx);
    try writer.writeAll("  ");
    try info.render(writer, theme_ctx);
    try writer.writeAll("  ");
    try muted.render(writer, theme_ctx);
    try writer.writeAll("\n\n");

    // Extended CLI semantic roles
    try writer.writeAll("   CLI-Specific Roles:\n   ");

    const command = ztheme.theme("git commit").command();
    const flag = ztheme.theme("--verbose").flag();
    const path = ztheme.theme("/usr/bin").path();
    const code = ztheme.theme("fn main()").value(); // Using value since code semantic role was removed

    try command.render(writer, theme_ctx);
    try writer.writeAll("  ");
    try flag.render(writer, theme_ctx);
    try writer.writeAll("  ");
    try path.render(writer, theme_ctx);
    try writer.writeAll("  ");
    try code.render(writer, theme_ctx);
    try writer.writeAll("\n\n");

    // Semantic vs Manual comparison
    try writer.writeAll("   Semantic vs Manual Colors:\n");

    // Semantic approach
    try writer.writeAll("   Semantic: ");
    try ztheme.theme("Build").info().render(writer, theme_ctx);
    try writer.writeAll(" ");
    try ztheme.theme("succeeded").success().render(writer, theme_ctx);
    try writer.writeAll(" with ");
    try ztheme.theme("3 warnings").warning().render(writer, theme_ctx);
    try writer.writeAll("\n");

    // Manual approach
    try writer.writeAll("   Manual:   ");
    try ztheme.theme("Build").blue().render(writer, theme_ctx);
    try writer.writeAll(" ");
    try ztheme.theme("succeeded").green().bold().render(writer, theme_ctx);
    try writer.writeAll(" with ");
    try ztheme.theme("3 warnings").yellow().bold().render(writer, theme_ctx);
    try writer.writeAll("\n\n");
}

fn displayBasicColors(writer: anytype, _: std.mem.Allocator, theme_ctx: *const ztheme.Theme) !void {
    try writer.writeAll("🎨 Basic ANSI Colors:\n   ");

    const colors = .{
        .{ "Black", ztheme.theme("■").black() },
        .{ "Red", ztheme.theme("■").red() },
        .{ "Green", ztheme.theme("■").green() },
        .{ "Yellow", ztheme.theme("■").yellow() },
        .{ "Blue", ztheme.theme("■").blue() },
        .{ "Magenta", ztheme.theme("■").magenta() },
        .{ "Cyan", ztheme.theme("■").cyan() },
        .{ "White", ztheme.theme("■").white() },
    };

    inline for (colors, 0..) |color, i| {
        if (i == (colors.len / 2)) {
            try writer.print("\n   ", .{});
        }
        try color[1].render(writer, theme_ctx);
        try writer.print(" {s:<12}", .{color[0]});
    }
    try writer.writeAll("\n\n");
}

fn displayBrightColors(writer: anytype, _: std.mem.Allocator, theme_ctx: *const ztheme.Theme) !void {
    try writer.writeAll("✨ Bright ANSI Colors:\n   ");

    const colors = .{
        .{ "Br.Black", ztheme.theme("■").gray() },
        .{ "Br.Red", ztheme.theme("■").brightRed() },
        .{ "Br.Green", ztheme.theme("■").brightGreen() },
        .{ "Br.Yellow", ztheme.theme("■").brightYellow() },
        .{ "Br.Blue", ztheme.theme("■").brightBlue() },
        .{ "Br.Magenta", ztheme.theme("■").brightMagenta() },
        .{ "Br.Cyan", ztheme.theme("■").brightCyan() },
        .{ "Br.White", ztheme.theme("■").brightWhite() },
    };

    inline for (colors, 0..) |color, i| {
        if (i == (colors.len / 2)) {
            try writer.print("\n   ", .{});
        }
        try color[1].render(writer, theme_ctx);
        try writer.print(" {s:<12}", .{color[0]});
    }
    try writer.writeAll("\n\n");
}

fn displayAdvancedColors(writer: anytype, _: std.mem.Allocator, theme_ctx: *const ztheme.Theme) !void {
    try writer.writeAll("🌈 Advanced Colors:\n");

    // RGB Colors
    try writer.writeAll("   RGB Colors: ");
    const rgb_colors = [_]struct { r: u8, g: u8, b: u8, name: []const u8 }{
        .{ .r = 255, .g = 100, .b = 100, .name = "Coral" },
        .{ .r = 100, .g = 255, .b = 100, .name = "Mint" },
        .{ .r = 100, .g = 100, .b = 255, .name = "Sky" },
        .{ .r = 255, .g = 200, .b = 50, .name = "Gold" },
        .{ .r = 200, .g = 50, .b = 255, .name = "Purple" },
    };

    for (rgb_colors) |color| {
        const themed = ztheme.theme("●").rgb(color.r, color.g, color.b);
        try themed.render(writer, theme_ctx);
        try writer.print(" {s} ", .{color.name});
    }
    try writer.writeAll("\n");

    // Hex Colors (compile-time)
    try writer.writeAll("   Hex Colors: ");
    const hex_colors = .{
        .{ comptime ztheme.theme("♦").hex("#FF6B6B"), "#FF6B6B" },
        .{ comptime ztheme.theme("♦").hex("#4ECDC4"), "#4ECDC4" },
        .{ comptime ztheme.theme("♦").hex("#45B7D1"), "#45B7D1" },
        .{ comptime ztheme.theme("♦").hex("#F7DC6F"), "#F7DC6F" },
    };

    inline for (hex_colors) |hex| {
        try hex[0].render(writer, theme_ctx);
        try writer.print(" {s} ", .{hex[1]});
    }
    try writer.writeAll("\n");

    // 256-color palette
    try writer.writeAll("   256-Color: ");
    const indices = [_]u8{ 196, 46, 21, 226, 129, 93 };
    for (indices) |idx| {
        const themed = ztheme.theme("█").color256(idx);
        try themed.render(writer, theme_ctx);
        try writer.print(" {d} ", .{idx});
    }
    try writer.writeAll("\n\n");
}

fn displayTextStyles(writer: anytype, _: std.mem.Allocator, theme_ctx: *const ztheme.Theme) !void {
    try writer.writeAll("📝 Text Styling:\n");

    const styles = .{
        .{ "Normal", ztheme.theme("Sample Text") },
        .{ "Bold", ztheme.theme("Sample Text").bold() },
        .{ "Italic", ztheme.theme("Sample Text").italic() },
        .{ "Underline", ztheme.theme("Sample Text").underline() },
        .{ "Dim", ztheme.theme("Sample Text").dim() },
        .{ "Strikethrough", ztheme.theme("Sample Text").strikethrough() },
    };

    inline for (styles) |style| {
        try writer.print("   {s:<14}: ", .{style[0]});
        try style[1].render(writer, theme_ctx);
        try writer.writeAll("\n");
    }
    try writer.writeAll("\n");
}

fn displayBackgroundColors(writer: anytype, _: std.mem.Allocator, theme_ctx: *const ztheme.Theme) !void {
    try writer.writeAll("🎯 Background Colors:\n   ");

    const backgrounds = .{
        ztheme.theme(" Text ").white().onRed(),
        ztheme.theme(" Text ").black().onGreen(),
        ztheme.theme(" Text ").white().onBlue(),
        ztheme.theme(" Text ").black().onYellow(),
        ztheme.theme(" Text ").white().onMagenta(),
        ztheme.theme(" Text ").black().onCyan(),
    };

    inline for (backgrounds) |bg| {
        try bg.render(writer, theme_ctx);
        try writer.writeAll(" ");
    }

    try writer.writeAll("\n   RGB BG: ");
    const rgb_bg = ztheme.theme(" Custom ").white().onRgb(120, 80, 200);
    try rgb_bg.render(writer, theme_ctx);
    try writer.writeAll("\n\n");
}

fn displayComplexStyling(writer: anytype, _: std.mem.Allocator, theme_ctx: *const ztheme.Theme) !void {
    try writer.writeAll("🔥 Complex Style Combinations:\n   ");

    // Using semantic methods (adaptive colors)
    const error_msg = ztheme.theme("ERROR").err().underline();
    try error_msg.render(writer, theme_ctx);
    try writer.writeAll(": Critical system failure!\n   ");

    const warn_msg = ztheme.theme("WARNING").warning();
    try warn_msg.render(writer, theme_ctx);
    try writer.writeAll(": Deprecated function usage detected\n   ");

    const success_msg = ztheme.theme("SUCCESS").success();
    try success_msg.render(writer, theme_ctx);
    try writer.writeAll(": All tests passed!\n   ");

    const info_msg = ztheme.theme("INFO").info().italic();
    try info_msg.render(writer, theme_ctx);
    try writer.writeAll(": Processing 1,234 items...\n\n");

    // Rainbow text effect
    try writer.writeAll("   Rainbow Text: ");
    const rainbow = "ZTheme is awesome!";
    const rainbow_colors = [_]ztheme.Color{
        .red,   .bright_red,   .yellow,  .bright_yellow,
        .green, .bright_green, .cyan,    .bright_cyan,
        .blue,  .bright_blue,  .magenta, .bright_magenta,
        .red,   .bright_red,   .yellow,  .bright_yellow,
        .green, .bright_green,
    };

    for (rainbow, 0..) |char, i| {
        const color_idx = i % rainbow_colors.len;
        var themed = ztheme.theme(&[_]u8{char});
        themed.style.foreground = rainbow_colors[color_idx];
        if (i == rainbow.len - 1) {
            themed = themed.bold();
        }
        try themed.render(writer, theme_ctx);
    }
    try writer.writeAll("\n\n");
}

fn displayPracticalExamples(writer: anytype, _: std.mem.Allocator, theme_ctx: *const ztheme.Theme) !void {
    try writer.writeAll("💡 Practical CLI Examples:\n\n");

    // Progress bar example
    try writer.writeAll("   Progress Bar:\n   [");
    const progress_filled = ztheme.theme("████████████").brightGreen().onBrightGreen();
    const progress_empty = ztheme.theme("░░░░░░░░").dim().onBrightBlack();
    const progress_text = ztheme.theme("75%").brightWhite().bold();

    try progress_filled.render(writer, theme_ctx);
    try progress_empty.render(writer, theme_ctx);
    try writer.writeAll("] ");
    try progress_text.render(writer, theme_ctx);
    try writer.writeAll("\n\n");

    // File listing example
    try writer.writeAll("   File Listing:\n");
    const files = .{
        .{ "📁", "src/", ztheme.theme("src/").brightBlue().bold() },
        .{ "📄", "main.zig", ztheme.theme("main.zig").white() },
        .{ "⚙️ ", "build.zig", ztheme.theme("build.zig").brightYellow() },
        .{ "📋", "README.md", ztheme.theme("README.md").brightCyan() },
        .{ "🔒", ".gitignore", ztheme.theme(".gitignore").dim() },
    };

    inline for (files) |file| {
        try writer.print("   {s} ", .{file[0]});
        try file[2].render(writer, theme_ctx);
        try writer.writeAll("\n");
    }

    try writer.writeAll("\n");

    // Code syntax highlighting example
    try writer.writeAll("   Code Syntax Highlighting:\n   ");
    const keyword = ztheme.theme("const").brightMagenta().bold();
    const type_name = ztheme.theme("std").brightBlue();
    const func_name = ztheme.theme("print").brightYellow();
    const string_lit = ztheme.theme("\"Hello, ZTheme!\"").brightGreen();

    try keyword.render(writer, theme_ctx);
    try writer.writeAll(" ");
    try type_name.render(writer, theme_ctx);
    try writer.writeAll(" = @import(");
    try string_lit.render(writer, theme_ctx);
    try writer.writeAll(");\n   ");

    try type_name.render(writer, theme_ctx);
    try writer.writeAll(".debug.");
    try func_name.render(writer, theme_ctx);
    try writer.writeAll("(");
    try string_lit.render(writer, theme_ctx);
    try writer.writeAll(");\n\n");
}

fn displayFooter(writer: anytype, theme_ctx: *const ztheme.Theme) !void {
    try writer.writeAll("╭────────────────────────────────────────────────────────────╮\n│ ");

    const footer_text = ztheme.theme("ZTheme").brightCyan().bold();
    const version_text = ztheme.theme("v0.1.0").dim();

    try footer_text.render(writer, theme_ctx);
    try writer.writeAll(" ");
    try version_text.render(writer, theme_ctx);
    try writer.writeAll(" - Powerful terminal styling for Zig");

    try writer.writeAll("          │\n");
    try writer.writeAll("│ Integrated with zcli framework for seamless CLI building   │\n");
    try writer.writeAll("╰────────────────────────────────────────────────────────────╯\n\n");

    const thanks = ztheme.theme("Thanks for trying ztheme with zcli!").brightGreen().italic();
    try thanks.render(writer, theme_ctx);
    try writer.writeAll("\n\n");
}
