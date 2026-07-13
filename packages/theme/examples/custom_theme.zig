//! Custom theme — one palette definition, applied everywhere.
//!
//! Defines a branded `Theme` and renders through it. The whole point of the
//! design system: role-tagged code written *before* the theme existed picks up
//! the new look with zero changes, because roles resolve against the active
//! palette at render time.
//!
//!     zig build run-custom-theme
//!
//! This example builds its own ThemeContext to point at a custom theme. In a
//! real zcli app you don't do this by hand — you declare the theme once as a
//! root-module override and every render path picks it up automatically:
//!
//!     // in your app's main.zig, next to `pub fn main`
//!     pub const zcli_theme: zcli.Theme = MY_THEME;
//!
//! That `pub const zcli_theme` is the `std_options`-style idiom (ADR-0012):
//! `theme.appTheme()` reads the root module's declaration at comptime, so help
//! output, prompts, and progress all resolve through your palette for free —
//! and because it's comptime-known, themed help costs nothing at runtime
//! (ADR-0020). Under `zig test` / a standalone binary with no such declaration,
//! `appTheme()` falls back to the default theme, which is why this example
//! passes its theme through an explicit ThemeContext instead.

const std = @import("std");
const theme = @import("theme");
const common = @import("common.zig");

const styled = theme.styled;
const Style = theme.Style;

/// A branded theme. Only the roles we care about are overridden; every field
/// left out keeps its default (see `Palette` field defaults). Component tokens
/// (`prompts`, `progress`, `surface`) reference roles by default, so overriding
/// `accent` alone re-colors the prompt cursor, the spinner, and panel borders.
const brand: theme.Theme = .{
    .palette = .{
        // A warm amber brand color, used directly and via the accent role.
        .accent = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } } },
        .command = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } }, .bold = true },
        // Repaint success/err to fit the palette.
        .success = .{ .foreground = .{ .rgb = .{ .r = 46, .g = 204, .b = 113 } }, .bold = true },
        .err = .{ .foreground = .{ .rgb = .{ .r = 231, .g = 76, .b = 60 } }, .bold = true },
    },
    .prompts = .{
        // Pin the selection highlight to a literal style instead of following
        // accent — a StyleRef is either `.role` (default) or `.style` (literal).
        .selected = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 255, .g = 179, .b = 71 } }, .bold = true, .underline = true } },
    },
};

pub fn main(init: std.process.Init) !void {
    var out: common.Out = .{};
    out.init(init.io);
    defer out.flush();
    const w = out.w();

    const default_ctx = theme.ThemeContext{
        .caps = caps(),
    };
    const brand_ctx = theme.ThemeContext{
        .theme = &brand,
        .caps = caps(),
    };

    try styled("Same role-tagged code, two themes").header().render(w, &default_ctx);
    try w.writeAll("\n\n");

    // The exact same styled() calls, rendered through each context. Nothing
    // about the call sites changes — only which theme the ctx points at.
    try renderSample(w, "default", &default_ctx);
    try renderSample(w, "brand  ", &brand_ctx);

    // --- Component tokens flow from the palette -----------------------------
    try w.writeAll("\n");
    try styled("Component tokens resolve through the same palette").header().render(w, &brand_ctx);
    try w.writeAll("\n");

    // The prompts cursor token defaults to `.role = .accent`, so it follows the
    // brand accent automatically. `selected` was pinned to a literal above.
    const prompt_tokens = brand_ctx.promptTokens();
    try w.writeAll("  cursor (follows accent):  ");
    try styledWithStyle("> selected item", brand_ctx.resolveRef(prompt_tokens.cursor)).render(w, &brand_ctx);
    try w.writeAll("\n  selected (literal pin):   ");
    try styledWithStyle("chosen", brand_ctx.resolveRef(prompt_tokens.selected)).render(w, &brand_ctx);
    try w.writeAll("\n");

    // The progress spinner + progress-bar fill also ride `accent` by default.
    const progress_tokens = brand_ctx.progressTokens();
    try w.writeAll("  spinner (follows accent):  ");
    try styledWithStyle("⠹ working…", brand_ctx.resolveRef(progress_tokens.spinner)).render(w, &brand_ctx);
    try w.writeAll("\n");

    // The surface border token also defaults to accent, so a full-screen panel
    // border matches the brand with no extra configuration.
    const surface_tokens = brand_ctx.surfaceTokens();
    try w.writeAll("  panel border (accent):    ");
    try styledWithStyle("┌── panel ──┐", brand_ctx.resolveRef(surface_tokens.border)).render(w, &brand_ctx);
    try w.writeAll("\n");
}

/// Render a fixed set of role-tagged samples, labeled with the theme name.
fn renderSample(w: *std.Io.Writer, label: []const u8, ctx: *const theme.ThemeContext) !void {
    try styled(label).muted().render(w, ctx);
    try w.writeAll("  ");
    try styled("git push").command().render(w, ctx);
    try w.writeAll("  ");
    try styled("done").success().render(w, ctx);
    try w.writeAll("  ");
    try styled("failed").err().render(w, ctx);
    try w.writeAll("  ");
    try styled("brand").accent().render(w, ctx);
    try w.writeAll("\n");
}

/// Wrap content with an already-resolved literal style (used to render the
/// component tokens after resolving their StyleRef through the palette).
fn styledWithStyle(content: []const u8, style: Style) StyledLiteral {
    return .{ .content = content, .style = style };
}

/// Minimal styled wrapper for a pre-resolved Style — the fluent `styled()`
/// builder tags roles, but here we already have a concrete Style in hand.
const StyledLiteral = struct {
    content: []const u8,
    style: Style,

    fn render(self: StyledLiteral, w: *std.Io.Writer, ctx: *const theme.ThemeContext) !void {
        const wrote = try self.style.writeSequence(w, ctx.capability());
        try w.writeAll(self.content);
        if (wrote) try w.writeAll("\x1B[0m");
    }
};

fn caps() theme.Capabilities {
    return .{ .capability = .true_color, .is_tty = true, .color_enabled = true };
}
