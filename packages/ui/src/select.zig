//! Select widget (ADR-0018): a single-select scrollable list.

const std = @import("std");
const theme_mod = @import("theme");
const terminal = @import("terminal");
const node_mod = @import("node.zig");
const surface_mod = @import("surface.zig");
const helpers = @import("input_helpers.zig");

const Node = node_mod.Node;
const Dim = node_mod.Dim;
const Limits = node_mod.Limits;
const Size = node_mod.Size;
const RenderCtx = node_mod.RenderCtx;
const Style = surface_mod.Style;
const Region = surface_mod.Region;
const Key = terminal.Key;
const Theme = theme_mod.Theme;

const scrollFor = helpers.scrollFor;
const scrollbarWrap = helpers.scrollbarWrap;

/// A single-select scrollable list. The options are caller-owned and passed in
/// each frame (immediate mode); the widget holds only the cursor. ↑/↓/Home/End
/// move the highlight and are consumed; Enter/Tab/Escape bubble to the form,
/// which reads the choice as `options[select.highlighted]`.
///
/// By default options are single-line: the list scrolls to keep the highlight
/// within `height` rows — `scroll` is persistent, so the window stays put and
/// slides only when the highlight crosses an edge (a stable viewport, not a
/// highlight glued to the fold). It renders its own window directly rather than
/// wrapping a `viewport`: it already knows which slice is visible, so
/// re-rendering every option into a scratch surface would be wasted work.
///
/// With `wrap = true`, options that overflow the field wrap to several physical
/// rows and `height` becomes a physical-row budget. The window is chosen by
/// growing whole options out from the cursor (`WrapSelectView` / `growWindow`),
/// cursor-anchored like the `prompts` list — persistent scroll can't apply here
/// because the per-option wrapped height isn't known until layout grants a
/// width, which `handle` never sees. `handle` is therefore unchanged; the wrap
/// path derives its window from `highlighted` alone each frame.
pub const Select = struct {
    highlighted: usize = 0,
    /// First visible option — persistent, maintained by `handle`.
    scroll: usize = 0,

    pub const ViewOpts = struct {
        focused: bool = false,
        options: []const []const u8,
        /// Visible rows. Single-line (`wrap = false`): a count of options. Wrapped
        /// (`wrap = true`): a budget of *physical* rows the window grows to fill.
        height: u16 = 6,
        theme: *const Theme = theme_mod.appTheme(),
        /// Opt in to multi-line options: each option wraps to the field width and
        /// the visible window is chosen by physical-row budget (grow-from-cursor)
        /// instead of option index. The single-line default is left untouched.
        wrap: bool = false,
        /// Opt in to a proportional scrollbar in the right gutter (ADR-0021 incr5),
        /// OFF by default. When on, the scrollbar *replaces* the ↑/↓/↕ overflow
        /// arrows in the same 1-cell gutter — the richer indicator for the same
        /// column. Single-line path only for now (the `wrap` path keeps its arrows).
        scrollbar: bool = false,
    };

    /// Handle a key; returns whether it was consumed. `count` (the option count)
    /// and `visible` (the window height) are what the caller passes to `view`,
    /// so the highlight and scroll stay in step with what's rendered.
    pub fn handle(self: *Select, key: Key, count: usize, visible: u16) bool {
        if (count == 0) return false;
        switch (key) {
            .up => if (self.highlighted > 0) {
                self.highlighted -= 1;
            },
            .down => if (self.highlighted + 1 < count) {
                self.highlighted += 1;
            },
            .home => self.highlighted = 0,
            .end => self.highlighted = count - 1,
            else => return false,
        }
        self.scroll = scrollFor(self.scroll, self.highlighted, visible, count);
        return true;
    }

    pub fn view(self: *const Select, a: std.mem.Allocator, opts: ViewOpts) !Node {
        const th = opts.theme;
        const count = opts.options.len;
        if (count == 0) return .{ .kind = .{ .text = .{ .content = "", .wrap = .clip } } };

        const hi = @min(self.highlighted, count - 1);

        // Wrapped options are a different windowing model (physical-row budget,
        // grow-from-cursor), rendered by a custom leaf that knows its granted
        // width. The single-line path below is unchanged.
        if (opts.wrap) {
            const ctx = try a.create(WrapSelectView);
            ctx.* = .{
                .options = opts.options,
                .highlighted = hi,
                .budget = @max(opts.height, 1),
                .focused = opts.focused,
                .selected = th.prompts.selected.resolve(th.palette),
                .hint = th.prompts.hint.resolve(th.palette),
            };
            return .{ .kind = .{ .custom = .{
                .context = ctx,
                .measureFn = WrapSelectView.measureFn,
                .renderFn = WrapSelectView.renderFn,
            } } };
        }

        const visible = @min(@max(@as(usize, opts.height), 1), count);
        // Persistent scroll, re-derived so the highlight is always in view even
        // if the caller set `highlighted` directly, bypassing `handle`.
        const scroll = scrollFor(self.scroll, hi, @intCast(visible), count);

        // A fixed label column (widest option + the `"{marker} "` prefix), so the
        // column doesn't jitter as you scroll and the 1-cell overflow gutter to
        // its right stays put. Measured over ALL options, not just the visible
        // ones, so the width is stable. A too-wide option truncates (`…`) only
        // when the granted width can't hold it.
        var opt_w: usize = 0;
        for (opts.options) |o| opt_w = @max(opt_w, terminal.displayWidth(o));
        const label_w: u16 = @intCast(opt_w + 2);

        // Overflow: dim ↑/↓ in the gutter when options are hidden above/below.
        // With a scrollbar the gutter carries the thumb instead (drawn over the
        // blank gutter cells by `scrollbarWrap`), so the arrows are suppressed.
        const more_above = scroll > 0;
        const more_below = scroll + visible < count;
        const hint = th.prompts.hint.resolve(th.palette);

        const rows = try a.alloc(Node, visible);
        for (rows, 0..) |*row_node, i| {
            const idx = scroll + i;
            const is_hi = idx == hi;
            const marker: []const u8 = if (is_hi and opts.focused) "›" else " ";
            const line = try std.fmt.allocPrint(a, "{s} {s}", .{ marker, opts.options[idx] });
            // The current option always stands out (the `selected` token), so it
            // reads as chosen whether or not the list is focused; the `›` marker
            // is what signals focus. Non-highlighted rows are plain.
            const style: Style = if (is_hi) th.prompts.selected.resolve(th.palette) else .{};
            const up = !opts.scrollbar and i == 0 and more_above;
            const down = !opts.scrollbar and i == visible - 1 and more_below;
            const arrow: []const u8 = if (up and down) "↕" else if (up) "↑" else if (down) "↓" else " ";
            const children = try a.dupe(Node, &.{
                .{ .width = .{ .len = label_w }, .kind = .{ .text = .{ .content = line, .style = style, .wrap = .truncate } } },
                .{ .width = .{ .len = 1 }, .kind = .{ .text = .{ .content = arrow, .style = hint, .wrap = .clip } } },
            });
            row_node.* = .{ .kind = .{ .box = .{ .dir = .row, .children = children } } };
        }
        const list: Node = .{ .kind = .{ .box = .{ .dir = .column, .children = rows } } };
        if (opts.scrollbar) return scrollbarWrap(a, th, list, count, visible, scroll);
        return list;
    }
};

// ---- Wrapped-options rendering (Select `wrap = true`) ----------------------

/// The custom leaf behind a wrapped `Select`. It renders in its granted region,
/// so it wraps every option at the real field width — the width `Select.view`
/// can't know when it builds the node. Layout runs `column` [marker(1) space(1)
/// label(width-3)] and reserves the rightmost column as the overflow gutter, the
/// same shape as the single-line row.
const WrapSelectView = struct {
    options: []const []const u8,
    highlighted: usize,
    /// Physical-row budget the visible window grows to fill.
    budget: u16,
    focused: bool,
    /// The highlighted option's style (whole block); neighbours are plain.
    selected: Style,
    /// The dim overflow-arrow style.
    hint: Style,

    /// Columns available to the wrapped label: total minus the 2-cell marker
    /// prefix and the 1-cell overflow gutter. At least 1 (`wrapForEach` clamps).
    fn labelWidth(w: u16) usize {
        return @max(@as(usize, w) -| 3, 1);
    }

    fn measureFn(context: *anyopaque, _: *const RenderCtx, limits: Limits) Size {
        const self: *const WrapSelectView = @ptrCast(@alignCast(context));
        if (limits.max_w == 0 or limits.max_h == 0) return .{ .w = 0, .h = 0 };
        const lw = labelWidth(limits.max_w);
        var total: usize = 0;
        for (self.options) |o| total += terminal.wrapCount(o, lw);
        const h = @min(@min(total, @as(usize, self.budget)), @as(usize, limits.max_h));
        return .{ .w = limits.max_w, .h = @intCast(@max(h, 1)) };
    }

    fn renderFn(context: *anyopaque, _: *const RenderCtx, region: Region) anyerror!void {
        const self: *const WrapSelectView = @ptrCast(@alignCast(context));
        const w = region.width();
        if (w == 0) return;
        const budget = @min(self.budget, region.height());
        if (budget == 0) return;
        const lw = labelWidth(w);

        const wc = WrapCounts{ .options = self.options, .lw = lw };
        const win = growWindow(self.options.len, self.highlighted, budget, &wc, WrapCounts.at);

        var y: u16 = 0;
        for (win.start..win.end) |idx| {
            if (y >= budget) break;
            const is_hi = idx == self.highlighted;
            var painter = LinePainter{
                .region = region,
                .y = &y,
                .budget = budget,
                .width = w,
                .style = if (is_hi) self.selected else .{},
                .marker = if (is_hi and self.focused) "›" else " ",
                .first = true,
            };
            try terminal.wrapForEach(self.options[idx], lw, &painter, LinePainter.add);
        }

        // Overflow arrows in the gutter (rightmost column), in physical-row
        // terms: ↑ on the first painted row, ↓ on the last. They coincide (↕)
        // only when the whole window is a single row.
        const gx = w - 1;
        const more_above = win.start > 0;
        const more_below = win.end < self.options.len;
        const last = y -| 1;
        if (more_above and more_below and last == 0) {
            _ = try region.writeText(gx, 0, "↕", self.hint);
        } else {
            if (more_above) _ = try region.writeText(gx, 0, "↑", self.hint);
            if (more_below) _ = try region.writeText(gx, last, "↓", self.hint);
        }
    }
};

/// Paints one option's wrapped lines top-down: a full-width background over the
/// label area (so the highlight reads as a block), the marker on the first line,
/// and the label hung at column 2 (continuation lines keep the indent — their
/// marker cells stay blank). Rows past `budget` are dropped (a single option
/// taller than the whole window clips).
const LinePainter = struct {
    region: Region,
    y: *u16,
    budget: u16,
    width: u16,
    style: Style,
    marker: []const u8,
    first: bool,

    fn add(self: *LinePainter, line: []const u8) anyerror!void {
        if (self.y.* >= self.budget) return;
        // Background spans the label area but not the gutter (which carries the
        // dim arrows, never the highlight) — matching the single-line row.
        self.region.sub(.{ .x = 0, .y = self.y.*, .w = self.width -| 1, .h = 1 }).fill(self.style);
        if (self.first) _ = try self.region.writeText(0, self.y.*, self.marker, self.style);
        _ = try self.region.writeText(2, self.y.*, line, self.style);
        self.first = false;
        self.y.* += 1;
    }
};

const Window = struct { start: usize, end: usize };

const WrapCounts = struct {
    options: []const []const u8,
    lw: usize,
    fn at(self: *const WrapCounts, i: usize) usize {
        return terminal.wrapCount(self.options[i], self.lw);
    }
};

/// Grow a visible window of whole options out from `cursor` (upward first, to
/// match the prompts' scroll feel) until `budget` physical rows are used. The
/// ui-side mirror of `prompts`' `list_render.viewport` — kept private because
/// `Select` is its only consumer today; promote it if a second one appears.
fn growWindow(
    n: usize,
    cursor: usize,
    budget: usize,
    ctx: anytype,
    comptime rowCount: fn (@TypeOf(ctx), usize) usize,
) Window {
    if (n == 0) return .{ .start = 0, .end = 0 };
    var used = rowCount(ctx, cursor);
    var start = cursor;
    while (start > 0) {
        const c = rowCount(ctx, start - 1);
        if (used + c > budget) break;
        used += c;
        start -= 1;
    }
    var end = cursor + 1;
    while (end < n) {
        const c = rowCount(ctx, end);
        if (used + c > budget) break;
        used += c;
        end += 1;
    }
    return .{ .start = start, .end = end };
}
