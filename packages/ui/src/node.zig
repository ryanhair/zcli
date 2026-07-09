//! The node tree and layout: measure (constraints down, sizes up) and render
//! (paint into a clipped region) for the four-node vocabulary of ADR-0013.
//!
//! Both passes are pure functions over `Limits` — no terminal I/O, no
//! retained state — which is what makes layout unit-testable without a TTY
//! and cheap enough to re-run from scratch every frame. Text measurement is
//! `terminal.wrap`: the same greedy wrapper paints and measures, so layout
//! and rendering can never disagree about where a line breaks.
//!
//! Axis mapping: a box distributes its MAIN axis (width for `.row`, height
//! for `.column`) among children by their `Dim`; the CROSS axis stretches by
//! default, with `align_self` placing children that resolve smaller. A `Dim`
//! of `.auto` resolves per context: fit on the main axis, stretch on the
//! cross axis — and `fill(1)` for a spacer's main axis. That one rule is
//! what makes the ADR's zero-config defaults fall out.

const std = @import("std");
const Graphemes = @import("Graphemes");
const terminal = @import("terminal");
const surface_mod = @import("surface.zig");

pub const Style = surface_mod.Style;
pub const Region = surface_mod.Region;

pub const Size = struct { w: u16, h: u16 };

/// What a parent offers a child: at most this much. Minimums are implicit
/// zero; a leaf with an intrinsic minimum clamps itself and clips at render.
pub const Limits = struct {
    max_w: u16,
    max_h: u16,

    pub fn shrink(self: Limits, dw: u32, dh: u32) Limits {
        return .{
            .max_w = @intCast(self.max_w -| @min(dw, self.max_w)),
            .max_h = @intCast(self.max_h -| @min(dh, self.max_h)),
        };
    }
};

/// The sizing vocabulary. `.auto` is the context-dependent default (see the
/// module docs); the other three are the ADR's three words.
pub const Dim = union(enum) {
    auto,
    fit,
    len: u16,
    fill: u16,
};

pub const Align = enum { start, center, end };
/// How a box arranges its children. `row`/`column` distribute space along that
/// axis; `stack` overlaps them in the same region (z-layers, ADR-0016) —
/// declaration order is z-order, later children composite over earlier ones.
pub const Direction = enum { row, column, stack };
pub const WrapMode = enum { wrap, truncate, clip };

pub const BorderStyle = enum { none, single, rounded, double, ascii };

pub const Padding = struct {
    top: u16 = 0,
    right: u16 = 0,
    bottom: u16 = 0,
    left: u16 = 0,

    pub fn all(n: u16) Padding {
        return .{ .top = n, .right = n, .bottom = n, .left = n };
    }

    pub fn symmetric(x: u16, y: u16) Padding {
        return .{ .top = y, .right = x, .bottom = y, .left = x };
    }
};

/// Context threaded through measure/render. Deliberately small: styles are
/// structured data on the nodes themselves, so the core needs no theme — a
/// `custom` leaf that wants one carries it in its own context pointer.
pub const RenderCtx = struct {
    /// The frame arena. Layout scratch and builder child-copies live here and
    /// are freed wholesale when the frame ends.
    allocator: std.mem.Allocator,
    /// Chooses border/ellipsis glyphs (`terminal.unicodeSupported` upstream).
    unicode: bool = true,
};

pub const Node = struct {
    width: Dim = .auto,
    height: Dim = .auto,
    /// Cross-axis placement when this node resolves smaller than the space
    /// its parent offers. (`align` is a Zig keyword.)
    align_self: Align = .start,
    min_width: ?u16 = null,
    max_width: ?u16 = null,
    min_height: ?u16 = null,
    max_height: ?u16 = null,
    kind: Kind,
};

pub const Kind = union(enum) {
    box: Box,
    text: Text,
    spacer,
    custom: Custom,
};

pub const Box = struct {
    dir: Direction = .column,
    children: []const Node = &.{},
    gap: u16 = 0,
    padding: Padding = .{},
    border: BorderStyle = .none,
    border_style: Style = .{},
    /// Background: every cell of the box's region is blanked in this style
    /// before children paint.
    style: Style = .{},
};

pub const Text = struct {
    content: []const u8,
    style: Style = .{},
    wrap: WrapMode = .wrap,
};

pub const Custom = struct {
    context: *anyopaque,
    measureFn: *const fn (context: *anyopaque, ctx: *const RenderCtx, limits: Limits) Size,
    renderFn: *const fn (context: *anyopaque, ctx: *const RenderCtx, region: Region) anyerror!void,
};

// ============================================================================
// Measure
// ============================================================================

/// What size does `node` want, given at most `limits`? Never exceeds them.
pub fn measure(ctx: *const RenderCtx, node: *const Node, limits: Limits) Size {
    const clamped = clampLimits(node, limits);
    var size: Size = switch (node.kind) {
        .box => |*b| measureBox(ctx, b, clamped),
        .text => |*t| measureText(t, clamped),
        .spacer => .{ .w = 0, .h = 0 },
        .custom => |c| c.measureFn(c.context, ctx, clamped),
    };
    size.w = @min(size.w, clamped.max_w);
    size.h = @min(size.h, clamped.max_h);
    // `.len` means exactly n cells (clamped to the offer), not content size —
    // the render pass grants exactly n, so measure must report the same.
    switch (node.width) {
        .len => |n| size.w = @min(n, clamped.max_w),
        else => {},
    }
    switch (node.height) {
        .len => |n| size.h = @min(n, clamped.max_h),
        else => {},
    }
    if (node.min_width) |m| size.w = @max(size.w, @min(m, clamped.max_w));
    if (node.min_height) |m| size.h = @max(size.h, @min(m, clamped.max_h));
    return size;
}

/// Apply the node's own caps to what the parent offered: explicit `max_*`
/// clamps, and a `.len` dim IS the size on that axis — measuring inside it
/// (e.g. wrapping text at a fixed width) must see the fixed extent.
fn clampLimits(node: *const Node, limits: Limits) Limits {
    var l = limits;
    if (node.max_width) |m| l.max_w = @min(l.max_w, m);
    if (node.max_height) |m| l.max_h = @min(l.max_h, m);
    switch (node.width) {
        .len => |n| l.max_w = @min(l.max_w, n),
        else => {},
    }
    switch (node.height) {
        .len => |n| l.max_h = @min(l.max_h, n),
        else => {},
    }
    return l;
}

fn measureText(t: *const Text, limits: Limits) Size {
    if (limits.max_w == 0 or limits.max_h == 0) return .{ .w = 0, .h = 0 };
    switch (t.wrap) {
        .truncate, .clip => {
            const w = terminal.displayWidth(t.content);
            return .{ .w = @intCast(@min(w, limits.max_w)), .h = 1 };
        },
        .wrap => {
            var m = WrapMeasure{};
            terminal.wrapForEach(t.content, limits.max_w, &m, WrapMeasure.add) catch unreachable;
            return .{
                .w = @intCast(@min(m.widest, limits.max_w)),
                .h = @intCast(@min(m.lines, limits.max_h)),
            };
        },
    }
}

const WrapMeasure = struct {
    lines: usize = 0,
    widest: usize = 0,

    fn add(self: *WrapMeasure, line: []const u8) anyerror!void {
        self.lines += 1;
        self.widest = @max(self.widest, terminal.displayWidth(line));
    }
};

/// A box wants its chrome plus its content: fixed and fit children summed on
/// the main axis (fill children contribute nothing at measure time — they
/// only absorb surplus at render), the largest child on the cross axis.
fn measureBox(ctx: *const RenderCtx, b: *const Box, limits: Limits) Size {
    const chrome_w: u32 = @as(u32, b.padding.left) + b.padding.right + borderCols(b) * 2;
    const chrome_h: u32 = @as(u32, b.padding.top) + b.padding.bottom + borderCols(b) * 2;
    const inner = limits.shrink(chrome_w, chrome_h);

    // A stack's layers overlap, so it wants the LARGEST child on both axes
    // (a `row`/`column` sums its main axis; a stack maxes both).
    if (b.dir == .stack) {
        var w: u32 = 0;
        var h: u32 = 0;
        for (b.children) |*child| {
            const s = measure(ctx, child, inner);
            w = @max(w, s.w);
            h = @max(h, s.h);
        }
        return .{
            .w = @intCast(@min(chrome_w + w, limits.max_w)),
            .h = @intCast(@min(chrome_h + h, limits.max_h)),
        };
    }

    var main_used: u32 = 0;
    var cross_max: u32 = 0;
    var first = true;
    for (b.children) |*child| {
        const gap: u32 = if (first) 0 else b.gap;
        first = false;
        const remaining: u16 = @intCast(innerMain(b.dir, inner) -| (main_used + gap));
        const child_size = switch (mainDim(b.dir, child)) {
            .fill => Size{ .w = 0, .h = 0 },
            // .len is folded into the child's limits by clampLimits; .auto on
            // the main axis is fit (spacers resolved to .fill by mainDim).
            .len, .auto, .fit => measure(ctx, child, limitsFor(b.dir, remaining, innerCross(b.dir, inner))),
        };
        main_used += gap + mainOf(b.dir, child_size);
        cross_max = @max(cross_max, crossOf(b.dir, child_size));
    }

    const w: u32 = chrome_w + (if (b.dir == .row) main_used else cross_max);
    const h: u32 = chrome_h + (if (b.dir == .row) cross_max else main_used);
    return .{
        .w = @intCast(@min(w, limits.max_w)),
        .h = @intCast(@min(h, limits.max_h)),
    };
}

// ============================================================================
// Render
// ============================================================================

/// Paint `node` into `region` — exactly the rect the parent granted; the
/// region's clipping is what enforces "children stick to constraints".
pub fn render(ctx: *const RenderCtx, node: *const Node, region: Region) anyerror!void {
    if (region.width() == 0 or region.height() == 0) return;
    switch (node.kind) {
        .box => |*b| try renderBox(ctx, b, region),
        .text => |*t| try renderText(ctx, t, region),
        .spacer => {},
        .custom => |c| try c.renderFn(c.context, ctx, region),
    }
}

fn renderText(ctx: *const RenderCtx, t: *const Text, region: Region) !void {
    switch (t.wrap) {
        .clip => _ = try region.writeText(0, 0, t.content, t.style),
        .truncate => try writeTruncated(ctx, region, t.content, t.style),
        .wrap => {
            var w = WrapWriter{ .region = region, .style = t.style };
            try terminal.wrapForEach(t.content, region.width(), &w, WrapWriter.add);
        },
    }
}

const WrapWriter = struct {
    region: Region,
    style: Style,
    line: u16 = 0,

    fn add(self: *WrapWriter, line_text: []const u8) anyerror!void {
        if (self.line >= self.region.height()) return;
        _ = try self.region.writeText(0, self.line, line_text, self.style);
        self.line += 1;
    }
};

fn writeTruncated(ctx: *const RenderCtx, region: Region, content: []const u8, style: Style) !void {
    const w = region.width();
    if (terminal.displayWidth(content) <= w) {
        _ = try region.writeText(0, 0, content, style);
        return;
    }
    const ellipsis: []const u8 = if (ctx.unicode) "…" else "...";
    const ellipsis_w: u16 = if (ctx.unicode) 1 else 3;
    if (w <= ellipsis_w) {
        // No room for content at all; the (possibly clipped) ellipsis is the message.
        _ = try region.writeText(0, 0, ellipsis, style);
        return;
    }
    const keep = prefixForWidth(content, w - ellipsis_w);
    const cols = try region.writeText(0, 0, content[0..keep], style);
    _ = try region.writeText(cols, 0, ellipsis, style);
}

/// Byte length of the longest prefix of `text` that fits `width` columns.
fn prefixForWidth(text: []const u8, width: u16) usize {
    var cols: usize = 0;
    var end: usize = 0;
    var it = Graphemes.iterator(text);
    while (it.next()) |g| {
        const gw = g.displayWidth(text);
        const w: usize = if (gw > 0) @intCast(gw) else 0;
        if (cols + w > width) break;
        cols += w;
        end = g.offset + g.len;
    }
    return end;
}

fn renderBox(ctx: *const RenderCtx, b: *const Box, region: Region) !void {
    // A box paints its background only when it has a style; a style-less box is
    // transparent, so in a `.stack` the layer beneath shows through its gaps
    // (ADR-0016). In flow layout the surface is pre-cleared every frame, so
    // skipping the blank-fill is invisible there — it only matters when an
    // earlier stack layer already painted underneath.
    if (!surface_mod.styleEql(b.style, .{})) region.fill(b.style);
    try drawBorder(ctx, b, region);

    const bc = borderCols(b);
    const inner = region.sub(.{
        .x = @intCast(@min(@as(u32, b.padding.left) + bc, region.width())),
        .y = @intCast(@min(@as(u32, b.padding.top) + bc, region.height())),
        .w = @intCast(region.width() -| (@as(u32, b.padding.left) + b.padding.right + bc * 2)),
        .h = @intCast(region.height() -| (@as(u32, b.padding.top) + b.padding.bottom + bc * 2)),
    });
    if (b.children.len == 0 or inner.width() == 0 or inner.height() == 0) return;

    // Z-layers (ADR-0016): every child is granted the FULL inner region and
    // painted in declaration order, so a later layer composites over an earlier
    // one. A bare layer fills the stack; size and position a layer (a modal,
    // a toast) with `ui.center` or spacer scaffolding — the scaffold boxes are
    // style-less, hence transparent, so the base shows around the placed layer.
    if (b.dir == .stack) {
        for (b.children) |*child| try render(ctx, child, inner);
        return;
    }

    // --- Distribute the main axis: len, then fit in declaration order, then
    // fill by weight with largest-remainder rounding (ADR-0013 §5).
    const main_total: u32 = if (b.dir == .row) inner.width() else inner.height();
    const gaps: u32 = @as(u32, b.gap) * @as(u32, @intCast(b.children.len - 1));
    var budget: u32 = main_total -| gaps;

    const assigned = try ctx.allocator.alloc(u16, b.children.len);
    var fill_total: u32 = 0;
    for (b.children, assigned) |*child, *slot| {
        switch (mainDim(b.dir, child)) {
            .len => |n| {
                slot.* = @intCast(@min(n, budget));
                budget -= slot.*;
            },
            .fill => |weight| {
                slot.* = 0; // resolved below
                fill_total += weight;
            },
            .auto, .fit => {
                const s = measure(ctx, child, limitsFor(b.dir, @intCast(budget), innerCross(b.dir, .{ .max_w = inner.width(), .max_h = inner.height() })));
                slot.* = mainOf(b.dir, s);
                budget -= slot.*;
            },
        }
    }
    if (fill_total > 0) try distributeFill(ctx, b, assigned, budget, fill_total);

    // --- Position and recurse.
    const cross_total: u16 = if (b.dir == .row) inner.height() else inner.width();
    var offset: u32 = 0;
    for (b.children, assigned) |*child, main_size| {
        defer offset += main_size + b.gap;
        if (main_size == 0) continue;

        var cross_size: u16 = cross_total;
        switch (crossDim(b.dir, child)) {
            .auto, .fill => {}, // stretch
            .len => |n| cross_size = @min(n, cross_total),
            .fit => {
                const s = measure(ctx, child, limitsFor(b.dir, main_size, cross_total));
                cross_size = @min(crossOf(b.dir, s), cross_total);
            },
        }
        const cross_offset: u16 = switch (child.align_self) {
            .start => 0,
            .center => (cross_total - cross_size) / 2,
            .end => cross_total - cross_size,
        };

        const child_region = inner.sub(if (b.dir == .row) .{
            .x = @intCast(@min(offset, inner.width())),
            .y = cross_offset,
            .w = main_size,
            .h = cross_size,
        } else .{
            .x = cross_offset,
            .y = @intCast(@min(offset, inner.height())),
            .w = cross_size,
            .h = main_size,
        });
        try render(ctx, child, child_region);
    }
}

/// Split `budget` among fill children proportionally to weight, exact-sum:
/// each gets floor(budget·weight/total), and leftover cells go to the largest
/// fractional remainders (declaration order breaks ties).
fn distributeFill(ctx: *const RenderCtx, b: *const Box, assigned: []u16, budget: u32, fill_total: u32) !void {
    const fracs = try ctx.allocator.alloc(u32, assigned.len);
    var leftover = budget;
    for (b.children, assigned, fracs) |*child, *slot, *frac| {
        frac.* = 0;
        switch (mainDim(b.dir, child)) {
            .fill => |weight| {
                const exact: u64 = @as(u64, budget) * weight;
                slot.* = @intCast(exact / fill_total);
                frac.* = @intCast(exact % fill_total);
                leftover -= slot.*;
            },
            else => {},
        }
    }
    while (leftover > 0) : (leftover -= 1) {
        var best: usize = 0;
        var best_frac: u32 = 0;
        for (fracs, 0..) |f, i| {
            if (f > best_frac) {
                best_frac = f;
                best = i;
            }
        }
        if (best_frac == 0) break; // exact division everywhere; nothing to round up
        fracs[best] = 0;
        assigned[best] += 1;
    }
}

// ============================================================================
// Axis helpers
// ============================================================================

/// The child's dim on the box's main axis. A spacer's `.auto` means
/// `fill(1)` — that one special case is what makes `ui.spacer()` sugar.
fn mainDim(dir: Direction, node: *const Node) Dim {
    const dim = if (dir == .row) node.width else node.height;
    if (dim == .auto and node.kind == .spacer) return .{ .fill = 1 };
    return dim;
}

fn crossDim(dir: Direction, node: *const Node) Dim {
    return if (dir == .row) node.height else node.width;
}

fn mainOf(dir: Direction, s: Size) u16 {
    return if (dir == .row) s.w else s.h;
}

fn crossOf(dir: Direction, s: Size) u16 {
    return if (dir == .row) s.h else s.w;
}

fn innerMain(dir: Direction, l: Limits) u32 {
    return if (dir == .row) l.max_w else l.max_h;
}

fn innerCross(dir: Direction, l: Limits) u16 {
    return if (dir == .row) l.max_h else l.max_w;
}

fn limitsFor(dir: Direction, main: u16, cross: u16) Limits {
    return if (dir == .row)
        .{ .max_w = main, .max_h = cross }
    else
        .{ .max_w = cross, .max_h = main };
}

// ============================================================================
// Borders
// ============================================================================

fn borderCols(b: *const Box) u32 {
    return if (b.border == .none) 0 else 1;
}

const BorderChars = struct {
    tl: []const u8,
    tr: []const u8,
    bl: []const u8,
    br: []const u8,
    h: []const u8,
    v: []const u8,
};

const ascii_border = BorderChars{ .tl = "+", .tr = "+", .bl = "+", .br = "+", .h = "-", .v = "|" };

fn borderChars(style: BorderStyle, unicode: bool) BorderChars {
    if (!unicode) return ascii_border;
    return switch (style) {
        .none => unreachable,
        .ascii => ascii_border,
        .single => .{ .tl = "┌", .tr = "┐", .bl = "└", .br = "┘", .h = "─", .v = "│" },
        .rounded => .{ .tl = "╭", .tr = "╮", .bl = "╰", .br = "╯", .h = "─", .v = "│" },
        .double => .{ .tl = "╔", .tr = "╗", .bl = "╚", .br = "╝", .h = "═", .v = "║" },
    };
}

fn drawBorder(ctx: *const RenderCtx, b: *const Box, region: Region) !void {
    if (b.border == .none) return;
    const w = region.width();
    const h = region.height();
    if (w < 2 or h < 2) return; // no room for chrome; content wins

    const c = borderChars(b.border, ctx.unicode);
    const s = b.border_style;

    _ = try region.writeText(0, 0, c.tl, s);
    _ = try region.writeText(w - 1, 0, c.tr, s);
    _ = try region.writeText(0, h - 1, c.bl, s);
    _ = try region.writeText(w - 1, h - 1, c.br, s);
    var x: u16 = 1;
    while (x < w - 1) : (x += 1) {
        _ = try region.writeText(x, 0, c.h, s);
        _ = try region.writeText(x, h - 1, c.h, s);
    }
    var y: u16 = 1;
    while (y < h - 1) : (y += 1) {
        _ = try region.writeText(0, y, c.v, s);
        _ = try region.writeText(w - 1, y, c.v, s);
    }
}
