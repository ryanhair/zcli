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

/// An action control: `[ Label ]`, activated by Enter or Space. A terminal has
/// no key-up, so there is no "pressed" phase — the only state is `activated`,
/// which reports whether the *last* key handled fired the button. `handle`
/// returns *consumed*, the uniform widget contract (`true` = "this key is mine,
/// not navigation"): a Button consumes exactly the keys that activate it, so the
/// caller reads `activated` (not the return) to run the action, then acts on it
/// in its focus arm; unconsumed keys (Tab/arrows) bubble on and clear `activated`.
pub const Button = struct {
    /// Whether the most recent `handle` call fired the button (Enter/Space).
    /// Momentary: each `handle` refreshes it, so a navigation key clears it.
    activated: bool = false,

    pub const ViewOpts = struct {
        focused: bool = false,
        label: []const u8 = "",
        theme: *const Theme = theme_mod.appTheme(),
    };

    pub fn handle(self: *Button, key: Key) bool {
        self.activated = switch (key) {
            .enter => true,
            .char => |c| c == ' ',
            else => false,
        };
        return self.activated;
    }

    pub fn view(self: *const Button, a: std.mem.Allocator, opts: ViewOpts) !Node {
        _ = self;
        const th = opts.theme;
        const label = try std.fmt.allocPrint(a, "[ {s} ]", .{opts.label});
        const style: Style = if (opts.focused) th.prompts.selected.resolve(th.palette) else .{};
        return .{ .kind = .{ .text = .{ .content = label, .style = style, .wrap = .clip } } };
    }
};
