//! Cross-platform rendering end-to-end tests for the list prompts.
//!
//! These drive the prompts' frame components through a `ui.App` with a fixed
//! terminal size and replay the real escape stream through the in-repo
//! `vterm` emulator, then assert on the resulting screen grid. Because vterm
//! is pure logic, these run identically on Linux, macOS, and Windows
//! (they're part of `zig build test-prompts`, which Windows CI runs) —
//! unlike the PTY harness, which is POSIX-only.
//!
//! The central invariant survives the engine port: navigating a list whose
//! options wrap must leave **no debris**. Under the old hand-rolled
//! erase/redraw this guarded the row bookkeeping; now it checks the engine's
//! frame diff end-to-end — a screen reached by diffing from a previous frame
//! must be identical to a fresh full paint of the target frame.

const std = @import("std");
const Prompts = @import("prompts");
const vterm = @import("vterm");
const ui = @import("ui");

const Winsize = Prompts.terminal.Winsize;
const testing = std.testing;

/// An App painting into a capture buffer, replayed through vterm on demand.
const Harness = struct {
    aw: std.Io.Writer.Allocating,
    vt: vterm.VTerm,
    app: ui.App,
    fed: usize = 0,

    fn init(ws: Winsize) !*Harness {
        const self = try testing.allocator.create(Harness);
        errdefer testing.allocator.destroy(self);
        self.* = .{
            .aw = std.Io.Writer.Allocating.init(testing.allocator),
            .vt = try vterm.VTerm.init(testing.allocator, ws.col, ws.row),
            .app = undefined,
        };
        self.app = try ui.App.init(testing.allocator, &self.aw.writer, .{
            .term_size = .{ .w = ws.col, .h = ws.row },
        });
        return self;
    }

    fn deinit(self: *Harness) void {
        self.app.deinit();
        self.vt.deinit();
        self.aw.deinit();
        testing.allocator.destroy(self);
    }

    fn replay(self: *Harness) void {
        self.vt.write(self.aw.written()[self.fed..]);
        self.fed = self.aw.written().len;
    }

    fn screen(self: *Harness, alloc: std.mem.Allocator) ![]u8 {
        self.replay();
        return self.vt.getAllText(alloc);
    }
};

// ---------------------------------------------------------------------------
// multi_select
// ---------------------------------------------------------------------------

fn multiFrame(h: *Harness, config: Prompts.MultiSelectConfig, selected: []const bool, cursor: usize, ws: Winsize) !void {
    try h.app.frame(try Prompts.multi_select_prompt.frameNode(
        h.app.arena(),
        Prompts.default_style,
        config,
        selected,
        cursor,
        ws,
    ));
}

test "emulator: multi_select navigation leaves no debris when options wrap" {
    const alloc = testing.allocator;
    const ws = Winsize{ .row = 24, .col = 30 };
    const config = Prompts.MultiSelectConfig{ .message = "Pick", .choices = &.{
        "short",
        "a genuinely long option label that certainly wraps across several rows",
        "third choice here",
    } };
    const selected = [_]bool{ false, false, false };

    // Fresh paint of the target frame (cursor on the long, wrapping option).
    var fresh = try Harness.init(ws);
    defer fresh.deinit();
    try multiFrame(fresh, config, &selected, 1, ws);
    const clean = try fresh.screen(alloc);
    defer alloc.free(clean);

    // Same frame reached by painting frame 0, then diffing to frame 1.
    var nav = try Harness.init(ws);
    defer nav.deinit();
    try multiFrame(nav, config, &selected, 0, ws);
    try multiFrame(nav, config, &selected, 1, ws);
    const stepped = try nav.screen(alloc);
    defer alloc.free(stepped);

    try testing.expectEqualStrings(clean, stepped);
}

test "emulator: multi_select wraps wide CJK options without debris" {
    const alloc = testing.allocator;
    const ws = Winsize{ .row = 24, .col = 22 };
    const config = Prompts.MultiSelectConfig{ .message = "Pick", .choices = &.{
        "ascii option",
        "你好世界这是一个需要换行显示的很长选项",
        "另一个选项",
    } };
    const selected = [_]bool{ false, true, false };

    var fresh = try Harness.init(ws);
    defer fresh.deinit();
    try multiFrame(fresh, config, &selected, 2, ws);
    const clean = try fresh.screen(alloc);
    defer alloc.free(clean);

    var nav = try Harness.init(ws);
    defer nav.deinit();
    try multiFrame(nav, config, &selected, 1, ws);
    try multiFrame(nav, config, &selected, 2, ws);
    const stepped = try nav.screen(alloc);
    defer alloc.free(stepped);

    try testing.expectEqualStrings(clean, stepped);
}

// ---------------------------------------------------------------------------
// select
// ---------------------------------------------------------------------------

fn selectFrame(h: *Harness, config: Prompts.SelectConfig, cursor: usize, ws: Winsize) !void {
    try h.app.frame(try Prompts.select_prompt.frameNode(
        h.app.arena(),
        Prompts.default_style,
        config,
        cursor,
        ws,
    ));
}

test "emulator: select navigation leaves no debris when options wrap" {
    const alloc = testing.allocator;
    const ws = Winsize{ .row = 24, .col = 24 };
    const config = Prompts.SelectConfig{ .message = "Choose", .choices = &.{
        "one",
        "a long choice that will wrap onto multiple lines at this width",
        "two",
    } };

    var fresh = try Harness.init(ws);
    defer fresh.deinit();
    try selectFrame(fresh, config, 1, ws);
    const clean = try fresh.screen(alloc);
    defer alloc.free(clean);

    var nav = try Harness.init(ws);
    defer nav.deinit();
    try selectFrame(nav, config, 0, ws);
    try selectFrame(nav, config, 1, ws);
    const stepped = try nav.screen(alloc);
    defer alloc.free(stepped);

    try testing.expectEqualStrings(clean, stepped);
}

test "emulator: select hang-indents wrapped continuation lines on screen" {
    const alloc = testing.allocator;
    // Short message keeps the header on one row so option rows are predictable.
    const ws = Winsize{ .row = 24, .col = 20 };
    const config = Prompts.SelectConfig{ .message = "Pick", .choices = &.{
        "alpha bravo charlie delta echo",
    } };

    var h = try Harness.init(ws);
    defer h.deinit();
    try selectFrame(h, config, 0, ws);
    h.replay();

    // Row 0: "? Pick" header. Row 1: first option line (prefix "  > "/"  ❯ ").
    // Row 2: a wrapped continuation, hang-indented to the 4-column prefix width.
    const row1 = try h.vt.getLine(alloc, 1);
    defer alloc.free(row1);
    const row2 = try h.vt.getLine(alloc, 2);
    defer alloc.free(row2);

    try testing.expect(std.mem.indexOf(u8, row1, "alpha") != null);
    // Continuation aligns under the label (4 leading spaces), not the bullet.
    try testing.expect(std.mem.startsWith(u8, row2, "    "));
    try testing.expect(std.mem.trim(u8, row2, " ").len > 0);
}

test "emulator: select answer persists as one static line, region gone" {
    const alloc = testing.allocator;
    const ws = Winsize{ .row = 24, .col = 40 };
    const config = Prompts.SelectConfig{ .message = "Choose", .choices = &.{ "alpha", "beta" } };

    var h = try Harness.init(ws);
    defer h.deinit();
    try selectFrame(h, config, 1, ws);
    // What select() does on Enter: clear the region, emit the styled answer.
    try h.app.clear();
    try h.app.emit("  {s}", .{config.choices[1]});
    h.replay();

    const line0 = try h.vt.getLine(alloc, 0);
    defer alloc.free(line0);
    try testing.expect(std.mem.indexOf(u8, line0, "beta") != null);
    try testing.expect(!h.vt.containsText("Choose"));
    try testing.expect(!h.vt.containsText("alpha"));
}

// ---------------------------------------------------------------------------
// search
// ---------------------------------------------------------------------------

fn searchFrame(h: *Harness, config: Prompts.SearchConfig, query: []const u8, filtered: []const usize, cursor: usize, ws: Winsize) !void {
    try h.app.frame(try Prompts.search_prompt.frameNode(
        h.app.arena(),
        Prompts.default_style,
        config,
        query,
        filtered,
        cursor,
        ws,
    ));
}

test "emulator: search navigation leaves no debris when results wrap" {
    const alloc = testing.allocator;
    const ws = Winsize{ .row = 24, .col = 28 };
    const config = Prompts.SearchConfig{ .message = "Find", .choices = &.{
        "apple",
        "a very long result entry that will wrap across more than one row",
        "cherry",
    } };
    const filtered = [_]usize{ 0, 1, 2 };
    const query = "";

    var fresh = try Harness.init(ws);
    defer fresh.deinit();
    try searchFrame(fresh, config, query, &filtered, 1, ws);
    const clean = try fresh.screen(alloc);
    defer alloc.free(clean);

    var nav = try Harness.init(ws);
    defer nav.deinit();
    try searchFrame(nav, config, query, &filtered, 0, ws);
    try searchFrame(nav, config, query, &filtered, 1, ws);
    const stepped = try nav.screen(alloc);
    defer alloc.free(stepped);

    try testing.expectEqualStrings(clean, stepped);
}

test "emulator: search filtering shrinks the list without debris" {
    const alloc = testing.allocator;
    const ws = Winsize{ .row = 24, .col = 28 };
    const config = Prompts.SearchConfig{ .message = "Find", .choices = &.{
        "apple",
        "a very long result entry that will wrap across more than one row",
        "cherry",
    } };

    var fresh = try Harness.init(ws);
    defer fresh.deinit();
    try searchFrame(fresh, config, "ap", &.{0}, 0, ws);
    const clean = try fresh.screen(alloc);
    defer alloc.free(clean);

    // The same screen reached by filtering down from the full (taller) list.
    var nav = try Harness.init(ws);
    defer nav.deinit();
    try searchFrame(nav, config, "", &.{ 0, 1, 2 }, 0, ws);
    try searchFrame(nav, config, "ap", &.{0}, 0, ws);
    const stepped = try nav.screen(alloc);
    defer alloc.free(stepped);

    try testing.expectEqualStrings(clean, stepped);
}
