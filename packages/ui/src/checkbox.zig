//! Checkbox widget (ADR-0018): a boolean toggle.

const std = @import("std");
const theme_mod = @import("theme");
const terminal = @import("terminal");
const node_mod = @import("node.zig");
const surface_mod = @import("surface.zig");

const Node = node_mod.Node;
const Style = surface_mod.Style;
const Key = terminal.Key;
const Theme = theme_mod.Theme;

/// A boolean toggle rendered as `[x] label` / `[ ] label`. Space toggles it;
/// Enter is left for the form (submit), so a checkbox never swallows it.
pub const Checkbox = struct {
    checked: bool = false,

    pub const ViewOpts = struct {
        focused: bool = false,
        label: []const u8 = "",
        theme: *const Theme = theme_mod.appTheme(),
    };

    pub fn handle(self: *Checkbox, key: Key) bool {
        switch (key) {
            .char => |c| if (c == ' ') {
                self.checked = !self.checked;
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn view(self: *const Checkbox, a: std.mem.Allocator, opts: ViewOpts) !Node {
        const th = opts.theme;
        const box: []const u8 = if (self.checked) "[x]" else "[ ]";
        const label = try std.fmt.allocPrint(a, " {s}", .{opts.label});
        const label_style: Style = if (opts.focused) th.prompts.selected.resolve(th.palette) else .{};
        // Built as node literals directly (not via `ui.zig`, which imports this).
        const children = try a.dupe(Node, &.{
            .{ .kind = .{ .text = .{ .content = box, .style = th.prompts.marker.resolve(th.palette), .wrap = .clip } } },
            .{ .kind = .{ .text = .{ .content = label, .style = label_style, .wrap = .clip } } },
        });
        return .{ .kind = .{ .box = .{ .dir = .row, .children = children } } };
    }
};
