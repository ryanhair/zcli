//! Progress widgets as component functions (ADR-0013 step 4: the consumer
//! port that validates the vocabulary). Everything here is composition —
//! spinner and percent are `text` nodes, a bar is one `custom` leaf, a
//! multi-bar is a column of rows. No widget owns a repaint loop or any
//! state: animation is the caller's tick, progress is the caller's
//! fraction, and the App's frame diff does the rest.
//!
//! Styling flows through the theme's component tokens (`ProgressTheme`),
//! the same tokens the progress package consumes today, so a future
//! migration of that package onto this engine keeps its look unchanged.

const std = @import("std");
const theme_mod = @import("theme");
const terminal = @import("terminal");
const node_mod = @import("node.zig");
const surface_mod = @import("surface.zig");

const Node = node_mod.Node;
const Dim = node_mod.Dim;
const Limits = node_mod.Limits;
const Size = node_mod.Size;
const RenderCtx = node_mod.RenderCtx;
const Style = surface_mod.Style;
const Region = surface_mod.Region;

pub const Theme = theme_mod.Theme;

/// The default spinner frames (the progress package's `.dots`).
pub const dots_frames: []const []const u8 =
    &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

pub const SpinnerOpts = struct {
    theme: *const Theme = &theme_mod.default_theme,
    frames: []const []const u8 = dots_frames,
};

/// An animated spinner glyph. `tick` is caller state — advance it on your
/// own cadence and the frame diff repaints exactly one cell.
pub fn spinner(opts: SpinnerOpts, tick: usize) Node {
    return .{ .kind = .{ .text = .{
        .content = opts.frames[tick % opts.frames.len],
        .style = opts.theme.progress.spinner.resolve(opts.theme.palette),
        .wrap = .clip,
    } } };
}

pub const BarOpts = struct {
    theme: *const Theme = &theme_mod.default_theme,
    /// Bars default to absorbing the row's leftover space.
    width: Dim = .{ .fill = 1 },
    /// Glyphs when the terminal supports unicode; a non-unicode RenderCtx
    /// falls back to `#`/`-` regardless.
    filled_char: []const u8 = "█",
    empty_char: []const u8 = "░",
};

/// A progress bar for `fraction` in [0, 1] — a `custom` leaf that paints
/// whatever width the layout grants it.
pub fn bar(a: std.mem.Allocator, opts: BarOpts, fraction: f32) !Node {
    const ctx = try a.create(BarCtx);
    ctx.* = .{
        .fraction = std.math.clamp(fraction, 0.0, 1.0),
        .filled = opts.theme.progress.bar_fill.resolve(opts.theme.palette),
        .empty = opts.theme.progress.bar_empty.resolve(opts.theme.palette),
        .filled_char = opts.filled_char,
        .empty_char = opts.empty_char,
    };
    return .{
        .width = opts.width,
        .kind = .{ .custom = .{
            .context = ctx,
            .measureFn = BarCtx.measureFn,
            .renderFn = BarCtx.renderFn,
        } },
    };
}

const BarCtx = struct {
    fraction: f32,
    filled: Style,
    empty: Style,
    filled_char: []const u8,
    empty_char: []const u8,

    fn measureFn(_: *anyopaque, _: *const RenderCtx, limits: Limits) Size {
        return .{ .w = @min(limits.max_w, 10), .h = @min(limits.max_h, 1) };
    }

    fn renderFn(context: *anyopaque, rctx: *const RenderCtx, region: Region) anyerror!void {
        const self: *const BarCtx = @ptrCast(@alignCast(context));
        const w = region.width();
        const filled: u16 = @intFromFloat(self.fraction * @as(f32, @floatFromInt(w)));
        const on_char = if (rctx.unicode) self.filled_char else "#";
        const off_char = if (rctx.unicode) self.empty_char else "-";
        var x: u16 = 0;
        while (x < w) : (x += 1) {
            const on = x < filled;
            _ = try region.writeText(
                x,
                0,
                if (on) on_char else off_char,
                if (on) self.filled else self.empty,
            );
        }
    }
};

pub const MultiBarItem = struct {
    label: []const u8,
    fraction: f32,
};

pub const MultiBarOpts = struct {
    theme: *const Theme = &theme_mod.default_theme,
    bar: BarOpts = .{},
    gap: u16 = 1,
    show_percent: bool = true,
    /// Column width for labels; `null` sizes to the widest label.
    label_width: ?u16 = null,
};

/// A stack of labeled progress bars: label column (truncated to fit), bar
/// absorbing the leftover width, right-aligned percent.
pub fn multiBar(a: std.mem.Allocator, opts: MultiBarOpts, items: []const MultiBarItem) !Node {
    var bar_opts = opts.bar;
    bar_opts.theme = opts.theme;

    var label_w: u16 = opts.label_width orelse 0;
    if (opts.label_width == null) {
        for (items) |item| {
            label_w = @max(label_w, @as(u16, @intCast(terminal.displayWidth(item.label))));
        }
    }

    const rows = try a.alloc(Node, items.len);
    for (items, rows) |item, *row_node| {
        const fraction = std.math.clamp(item.fraction, 0.0, 1.0);
        var cells: [3]Node = undefined;
        var n: usize = 0;
        cells[n] = .{
            .width = .{ .len = label_w },
            .kind = .{ .text = .{ .content = item.label, .wrap = .truncate } },
        };
        n += 1;
        cells[n] = try bar(a, bar_opts, fraction);
        n += 1;
        if (opts.show_percent) {
            const pct = try std.fmt.allocPrint(a, "{d:>3}%", .{
                @as(u8, @intFromFloat(fraction * 100)),
            });
            cells[n] = .{
                .width = .{ .len = 4 },
                .kind = .{ .text = .{
                    .content = pct,
                    .style = opts.theme.palette.get(.muted),
                    .wrap = .clip,
                } },
            };
            n += 1;
        }
        row_node.* = .{ .kind = .{ .box = .{
            .dir = .row,
            .children = try a.dupe(Node, cells[0..n]),
            .gap = opts.gap,
        } } };
    }

    return .{ .kind = .{ .box = .{ .dir = .column, .children = rows } } };
}

// ============================================================================
// Focusable input widgets (ADR-0018)
// ============================================================================

// These live in `input.zig` (interactive widgets, a distinct concern from the
// progress widgets above) but re-export here so the whole catalog is one
// namespace: `ui.widgets.TextInput`, `ui.widgets.Checkbox`, `ui.widgets.focusNext`.
pub const TextInput = @import("input.zig").TextInput;
pub const Checkbox = @import("input.zig").Checkbox;
pub const Select = @import("input.zig").Select;
pub const Button = @import("input.zig").Button;
pub const focusNext = @import("input.zig").focusNext;
pub const focusPrev = @import("input.zig").focusPrev;
