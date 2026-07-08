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

const surface = @import("surface.zig");
pub const Surface = surface.Surface;
pub const Region = surface.Region;
pub const Rect = surface.Rect;
pub const Cell = surface.Cell;
pub const Style = surface.Style;
pub const styleEql = surface.styleEql;

pub const Renderer = @import("diff.zig").Renderer;
pub const App = @import("app.zig").App;
pub const widgets = @import("widgets.zig");

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

test {
    _ = @import("node.zig");
}
