//! Button widget (ADR-0018): a stateless action control.

const std = @import("std");
const theme_mod = @import("theme");
const terminal = @import("terminal");
const node_mod = @import("node.zig");
const surface_mod = @import("surface.zig");

const Node = node_mod.Node;
const Style = surface_mod.Style;
const Key = terminal.Key;
const Theme = theme_mod.Theme;

/// A stateless action control: `[ Label ]`, activated by Enter or Space. It
/// holds no state (a terminal has no key-up, so there is no "pressed" phase),
/// so `handle` returns whether the key *activated* it — the same routing role
/// as the editors' `consumed` (`true` = "this key is mine, not navigation"), but
/// for an action widget "mine" means "fired." The caller runs the action on a
/// `true` return in its focus arm; unconsumed keys (Tab/arrows) bubble on.
pub const Button = struct {
    pub const ViewOpts = struct {
        focused: bool = false,
        label: []const u8 = "",
        theme: *const Theme = theme_mod.appTheme(),
    };

    pub fn handle(self: *Button, key: Key) bool {
        _ = self;
        return switch (key) {
            .enter => true,
            .char => |c| c == ' ',
            else => false,
        };
    }

    pub fn view(self: *const Button, a: std.mem.Allocator, opts: ViewOpts) !Node {
        _ = self;
        const th = opts.theme;
        const label = try std.fmt.allocPrint(a, "[ {s} ]", .{opts.label});
        const style: Style = if (opts.focused) th.prompts.selected.resolve(th.palette) else .{};
        return .{ .kind = .{ .text = .{ .content = label, .style = style, .wrap = .clip } } };
    }
};
