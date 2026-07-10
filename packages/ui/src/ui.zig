//! ui — the terminal-native layout engine (ADR-0013).
//!
//! An immediate-mode UI core for the CLI/TUI hybrid: output splits into a
//! static stream (flows into scrollback) and a live region at the bottom
//! edge, rebuilt as a node tree every frame into an arena, laid out
//! constraints-down/sizes-up, painted onto a cell surface, and diffed.
//!
//! A component is any function returning a `Node`. The builders below take
//! the frame arena and COPY child slices into it — the API keystone that
//! makes component functions composable: a `&.{...}` child literal is a
//! stack temporary, and without the copy a helper returning a `Node` would
//! hand its parent dangling children.

const std = @import("std");
const terminal = @import("terminal");

const surface = @import("surface.zig");
pub const Surface = surface.Surface;
pub const Region = surface.Region;
pub const Rect = surface.Rect;
pub const Point = surface.Point;
pub const Cell = surface.Cell;
pub const Style = surface.Style;
pub const styleEql = surface.styleEql;

pub const Renderer = @import("diff.zig").Renderer;
pub const App = @import("app.zig").App;
/// Full-screen input event (`App.nextEvent`) — a key, resize, mouse, or focus.
pub const Event = @import("app.zig").Event;
/// A key press (`Event.key`), re-exported from `terminal` for widget `handle`
/// signatures (`ui.widgets.TextInput.handle(key)`).
pub const Key = terminal.Key;
/// Mouse report / focus change carried by `Event` (full-screen, when enabled).
pub const Mouse = terminal.Mouse;
pub const Focus = terminal.Focus;
/// `update`'s verdict for the `App.run` loop — keep looping, or quit.
pub const Flow = App.Flow;
pub const widgets = @import("widgets.zig");

/// Root-module panic handler that restores the terminal before the default
/// handler prints (ADR-0015). Install in your `main.zig`:
/// `pub const panic = zcli.ui.panic;`. Required for `App.initFullScreen` /
/// `context.uiFullScreen` (enforced at compile time); optional for hybrid.
pub const panic = App.panic;

/// Whether the terminal supports unicode glyphs (re-exported from `terminal`
/// for App/RenderCtx configuration — `App.Options.unicode`).
pub const unicodeSupported = terminal.unicodeSupported;

const node_mod = @import("node.zig");
pub const Node = node_mod.Node;
pub const Kind = node_mod.Kind;
pub const Box = node_mod.Box;
pub const TextNode = node_mod.Text;
pub const Custom = node_mod.Custom;
pub const Size = node_mod.Size;
pub const Limits = node_mod.Limits;
pub const Dim = node_mod.Dim;
pub const Align = node_mod.Align;
pub const Direction = node_mod.Direction;
pub const WrapMode = node_mod.WrapMode;
pub const BorderStyle = node_mod.BorderStyle;
pub const Padding = node_mod.Padding;
pub const RenderCtx = node_mod.RenderCtx;
pub const measure = node_mod.measure;
pub const render = node_mod.render;

/// Box options shared by `row` and `column` (direction is the builder).
pub const BoxOpts = struct {
    gap: u16 = 0,
    padding: Padding = .{},
    border: BorderStyle = .none,
    border_style: Style = .{},
    style: Style = .{},
    width: Dim = .auto,
    height: Dim = .auto,
    align_self: Align = .start,
    min_width: ?u16 = null,
    max_width: ?u16 = null,
    min_height: ?u16 = null,
    max_height: ?u16 = null,
};

pub fn row(a: std.mem.Allocator, opts: BoxOpts, children: []const Node) !Node {
    return box(a, .row, opts, children);
}

pub fn column(a: std.mem.Allocator, opts: BoxOpts, children: []const Node) !Node {
    return box(a, .column, opts, children);
}

/// Overlapping layers, back to front (ADR-0016). Children share one region and
/// paint in declaration order, so each composites over the ones before it — the
/// z-layer / overlay primitive. A style-less layer is transparent (lower layers
/// show through its gaps); a layer with a background is opaque. Each layer is
/// granted the whole stack, so a bare layer fills it — place a smaller layer (a
/// modal, a toast) with `center` or spacer scaffolding. Reuses `BoxOpts`, so a
/// stack can carry its own border/padding/background like any box.
pub fn stack(a: std.mem.Allocator, opts: BoxOpts, children: []const Node) !Node {
    return box(a, .stack, opts, children);
}

pub fn box(a: std.mem.Allocator, dir: Direction, opts: BoxOpts, children: []const Node) !Node {
    return .{
        .width = opts.width,
        .height = opts.height,
        .align_self = opts.align_self,
        .min_width = opts.min_width,
        .max_width = opts.max_width,
        .min_height = opts.min_height,
        .max_height = opts.max_height,
        .kind = .{ .box = .{
            .dir = dir,
            .children = try a.dupe(Node, children),
            .gap = opts.gap,
            .padding = opts.padding,
            .border = opts.border,
            .border_style = opts.border_style,
            .style = opts.style,
        } },
    };
}

/// A wrapping styled text node. `content` is borrowed, not copied — it must
/// outlive the frame (string literals and user state always do; a string
/// formatted for this frame belongs in the frame arena).
pub fn text(style: Style, content: []const u8) Node {
    return .{ .kind = .{ .text = .{ .content = content, .style = style } } };
}

/// `text` with explicit text options (wrap mode, sizing).
pub const TextOpts = struct {
    style: Style = .{},
    wrap: WrapMode = .wrap,
    width: Dim = .auto,
    height: Dim = .auto,
    align_self: Align = .start,
};

pub fn textOpts(opts: TextOpts, content: []const u8) Node {
    return .{
        .width = opts.width,
        .height = opts.height,
        .align_self = opts.align_self,
        .kind = .{ .text = .{ .content = content, .style = opts.style, .wrap = opts.wrap } },
    };
}

/// Empty space that absorbs leftover main-axis room (`fill(1)`). Right-align
/// by preceding with a spacer; center by surrounding with two.
pub fn spacer() Node {
    return .{ .kind = .spacer };
}

/// Report where `child` lands on screen (ADR-0019). A layout-transparent
/// wrapper: it lays out and paints `child` exactly as if it weren't here, and as
/// a side effect writes the child's absolute rendered rect into `out`. Because
/// `view` runs inside `frame` before the next event, `out` reflects the current
/// frame — a click can be hit-tested against the very layout it's reacting to.
///
/// The rect is in surface coordinates, which in full-screen ARE screen
/// coordinates (the surface fills the viewport from the origin). This is the
/// position feedback the immediate-mode tree otherwise discards — the basis for
/// mouse hit-testing, a hardware cursor, and anchored popups.
///
/// `out` is only written when `child` actually paints; a child clipped to zero
/// size leaves it untouched (so zero-init or reset it if that matters).
pub fn probe(a: std.mem.Allocator, out: *Rect, child: Node) !Node {
    const ctx = try a.create(Probe);
    ctx.* = .{ .child = child, .out = out };
    // Copy the child's sizing so the parent measures/places the wrapper exactly
    // as it would the child — the wrapper adds a rect report, never a layout.
    return .{
        .width = child.width,
        .height = child.height,
        .align_self = child.align_self,
        .min_width = child.min_width,
        .max_width = child.max_width,
        .min_height = child.min_height,
        .max_height = child.max_height,
        .kind = .{ .custom = .{
            .context = ctx,
            .measureFn = Probe.measureFn,
            .renderFn = Probe.renderFn,
        } },
    };
}

const Probe = struct {
    child: Node,
    out: *Rect,

    fn measureFn(context: *anyopaque, rctx: *const RenderCtx, limits: Limits) Size {
        const self: *const Probe = @ptrCast(@alignCast(context));
        return measure(rctx, &self.child, limits);
    }

    fn renderFn(context: *anyopaque, rctx: *const RenderCtx, region: Region) anyerror!void {
        const self: *const Probe = @ptrCast(@alignCast(context));
        self.out.* = region.rect;
        try render(rctx, &self.child, region);
    }
};

/// Center `child` within the region its parent grants — spacer scaffolding for
/// placing an overlay layer in the middle of a `stack` (a modal, a dialog).
/// `child` sizes to its content; the surrounding scaffold is style-less, hence
/// transparent, so in a stack the layer beneath shows around it.
pub fn center(a: std.mem.Allocator, child: Node) !Node {
    return column(a, .{}, &.{
        spacer(),
        try row(a, .{}, &.{ spacer(), child, spacer() }),
        spacer(),
    });
}

/// Place `child`'s top-left at absolute `(x, y)` within the region its parent
/// grants — the placement half of an anchored popup (ADR-0019): a `stack` layer
/// `positioned` at a widget's probed rect floats a dropdown/menu over the base.
/// Uses fixed-size `len` gaps, which are style-less and therefore transparent,
/// so the base shows through everywhere but the (opaque) `child`. An `(x, y)`
/// past the region clips gracefully rather than erroring. It's the `center`
/// pattern with fixed offsets instead of spacers.
pub fn positioned(a: std.mem.Allocator, x: u16, y: u16, child: Node) !Node {
    return column(a, .{}, &.{
        try row(a, .{ .height = .{ .len = y } }, &.{}), // top gap: y rows tall
        try row(a, .{}, &.{
            try column(a, .{ .width = .{ .len = x } }, &.{}), // left gap: x cols wide
            child,
        }),
    });
}

/// Smart-placement options for `anchored`.
pub const AnchorOpts = struct {
    /// Which side of the anchor to open on when there's room. `anchored` flips
    /// to the other side only when the preferred side doesn't fit and the other
    /// does; otherwise it keeps the preferred side (and clips off-screen).
    prefer: enum { below, above } = .below,
    /// Which edges to align horizontally: `.left` pins the popup's left edge to
    /// the anchor's left, `.right` pins their right edges. Either way the popup
    /// is then clamped so its right edge stays on screen (never shifted past x=0).
    halign: enum { left, right } = .left,
};

/// Pin `popup` to `anchor`, keeping it on screen — the smart counterpart to
/// `positioned` (ADR-0019). It opens below the anchor, but **flips above** when
/// it would run off the bottom (and above fits), and **clamps** left when it
/// would run off the right edge. Returns a `stack` layer, so an anchored popup
/// is `stack{ base, anchored(probed_rect, .{}, popup) }`.
///
/// The geometry runs at RENDER time, where a `stack` layer is granted the whole
/// viewport as its region (ADR-0016) — so the popup can be `measure`d and placed
/// against the real viewport, the two facts `view` lacks. `anchor` is a probed
/// rect (ADR-0019), reflecting the previous frame; exact for a stable anchor.
pub fn anchored(a: std.mem.Allocator, anchor: Rect, opts: AnchorOpts, popup: Node) !Node {
    const ctx = try a.create(Anchor);
    ctx.* = .{ .popup = popup, .anchor = anchor, .opts = opts };
    return .{
        .kind = .{ .custom = .{
            .context = ctx,
            .measureFn = Anchor.measureFn,
            .renderFn = Anchor.renderFn,
        } },
    };
}

const Anchor = struct {
    popup: Node,
    anchor: Rect,
    opts: AnchorOpts,

    /// Take the whole offer so the `stack` grants this leaf the full viewport.
    fn measureFn(_: *anyopaque, _: *const RenderCtx, limits: Limits) Size {
        return .{ .w = limits.max_w, .h = limits.max_h };
    }

    fn renderFn(context: *anyopaque, rctx: *const RenderCtx, region: Region) anyerror!void {
        const self: *const Anchor = @ptrCast(@alignCast(context));
        const vw = region.width();
        const vh = region.height();
        const size = measure(rctx, &self.popup, .{ .max_w = vw, .max_h = vh });
        if (size.w == 0 or size.h == 0) return;

        // Vertical: keep the preferred side, flipping to the other only when the
        // preferred one overflows and the other fits; else keep it and clip.
        const below_y = self.anchor.y +| self.anchor.h;
        const above_y = self.anchor.y -| size.h;
        const fits_below = @as(u32, below_y) + size.h <= vh;
        const fits_above = self.anchor.y >= size.h;
        const y = switch (self.opts.prefer) {
            .below => if (!fits_below and fits_above) above_y else below_y,
            .above => if (!fits_above and fits_below) below_y else above_y,
        };

        // Horizontal: align an edge to the anchor, then clamp on screen. `want_x`
        // and `max_x` go through i32 because a right-align or a popup wider than
        // the viewport can push the ideal x negative.
        const want_x: i32 = switch (self.opts.halign) {
            .left => @as(i32, self.anchor.x),
            .right => @as(i32, self.anchor.x) + self.anchor.w - size.w,
        };
        const max_x: i32 = @max(0, @as(i32, vw) - size.w);
        const x: u16 = @intCast(@max(0, @min(want_x, max_x)));

        // `sub` clips against the region, so a kept-but-overflowing popup (the
        // "doesn't fit either side" case) trims gracefully instead of erroring.
        try render(rctx, &self.popup, region.sub(.{ .x = x, .y = y, .w = size.w, .h = size.h }));
    }
};

pub const ViewportOpts = struct {
    /// Caller-owned vertical scroll offset, in rows (immediate mode — the app
    /// holds it in state and adjusts it on ↑/↓/PageUp/PageDown). Clamped to the
    /// content, so overshooting (PageDown past the end) rests on the last page.
    scroll_y: u16 = 0,
    /// A viewport is a fixed window; it fills what it's granted by default and
    /// its content scrolls behind it. `.fit` height is meaningless (there would
    /// be nothing to scroll) — use `.fill` or `.len`.
    width: Dim = .{ .fill = 1 },
    height: Dim = .{ .fill = 1 },
};

/// A scrolling window onto content taller than the space it's granted (ADR-0017):
/// a log pane, a long list, a tall form. `child` is measured at the viewport
/// width and its natural (unbounded) height, rendered in full into a scratch
/// surface, and the slice at `scroll_y` is copied into the viewport. Vertical
/// scroll only. Scroll state stays caller-owned (immediate mode); the viewport
/// only clamps it. Content is fully realized each frame — fine for the ordinary
/// screenful-or-few; very tall content pays for its full height in scratch.
pub fn viewport(a: std.mem.Allocator, opts: ViewportOpts, child: Node) !Node {
    const ctx = try a.create(ViewportCtx);
    ctx.* = .{ .child = child, .scroll_y = opts.scroll_y };
    return .{
        .width = opts.width,
        .height = opts.height,
        .kind = .{ .custom = .{
            .context = ctx,
            .measureFn = ViewportCtx.measureFn,
            .renderFn = ViewportCtx.renderFn,
        } },
    };
}

const ViewportCtx = struct {
    child: Node,
    scroll_y: u16,

    /// A viewport takes the whole offer — it's a fixed window (the node's own
    /// `.len`/`.fill` dims, applied by `measure` after this, refine it).
    fn measureFn(_: *anyopaque, _: *const RenderCtx, limits: Limits) Size {
        return .{ .w = limits.max_w, .h = limits.max_h };
    }

    fn renderFn(context: *anyopaque, rctx: *const RenderCtx, region: Region) anyerror!void {
        const self: *const ViewportCtx = @ptrCast(@alignCast(context));
        const w = region.width();
        const h = region.height();
        if (w == 0 or h == 0) return;

        // Measure the child at the viewport width, unbounded height, then paint
        // it in full into a scratch surface (arena-backed — freed with the frame).
        const content = measure(rctx, &self.child, .{ .max_w = w, .max_h = std.math.maxInt(u16) });
        const content_h = @max(content.h, 1);
        var scratch = try Surface.init(rctx.allocator, w, content_h);
        try render(rctx, &self.child, scratch.root());

        // Clamp the scroll offset to the content and copy the visible window.
        const sy = @min(self.scroll_y, content_h -| h);
        try region.copyRows(&scratch, sy);
    }
};

test {
    _ = @import("node.zig");
}
