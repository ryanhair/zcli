//! Tabs widget (ADR-0018): a tab-bar row.

const std = @import("std");
const theme_mod = @import("theme");
const terminal = @import("terminal");
const node_mod = @import("node.zig");
const surface_mod = @import("surface.zig");

const Node = node_mod.Node;
const Style = surface_mod.Style;
const Key = terminal.Key;
const Theme = theme_mod.Theme;

/// A tab-bar row: a horizontal strip of labels with the active one highlighted.
/// It is *only* the chrome — it does not own the content panes. The widget owns
/// the `active` index (ownership parity with `Select`/`Table`, which own their
/// cursor); the caller switches what it renders below the bar on `tabs.active`
/// (immediate mode) and `handle` advances the index in place.
///
/// ←/→ move the active tab, wrapping over the count; number keys `1`-`9` jump
/// directly to that tab if it exists. Those keys are consumed. `Tab` is *never*
/// consumed — it stays reserved for the focus ring, so the ring can still move
/// focus off the bar. Everything else bubbles.
///
/// Rendering is a plain builder composition (no `custom` leaf, like `Checkbox`):
/// a `row{}` of `text` nodes, the active label in `th.prompts.selected` and the
/// inactive ones in `th.prompts.hint`, separated by a single-space gap.
pub const Tabs = struct {
    /// The active tab index — persistent, maintained by `handle`.
    active: usize = 0,

    pub const ViewOpts = struct {
        focused: bool = false,
        labels: []const []const u8,
        theme: *const Theme = theme_mod.appTheme(),
    };

    /// Handle a key; returns whether it was consumed. `count` is the tab count,
    /// so the widget can wrap/clamp `active` in step with what `view` renders.
    /// ←/→ wrap over `count`; `1`-`9` jump if that tab exists; `Tab` is left for
    /// the focus ring; everything else bubbles.
    pub fn handle(self: *Tabs, key: Key, count: usize) bool {
        if (count == 0) return false;
        switch (key) {
            .left => self.active = (self.active + count - 1) % count,
            .right => self.active = (self.active + 1) % count,
            .char => |c| {
                if (c < '1' or c > '9') return false;
                const idx = c - '1';
                if (idx >= count) return false;
                self.active = idx;
            },
            else => return false,
        }
        return true;
    }

    pub fn view(self: *const Tabs, a: std.mem.Allocator, opts: ViewOpts) !Node {
        const th = opts.theme;
        const active_style = th.prompts.selected.resolve(th.palette);
        const inactive_style = th.prompts.hint.resolve(th.palette);
        const cells = try a.alloc(Node, opts.labels.len);
        for (opts.labels, cells, 0..) |label, *cell, i| {
            const is_active = i == self.active;
            cell.* = .{ .kind = .{ .text = .{
                .content = label,
                .style = if (is_active) active_style else inactive_style,
                .wrap = .clip,
            } } };
        }
        return .{ .kind = .{ .box = .{ .dir = .row, .gap = 1, .children = cells } } };
    }
};
