//! Search/filter prompt — type to filter a list, arrow keys to navigate, Enter to select.
//!
//! Rendering runs on the ui engine (see select.zig); input handling and the
//! filter state stay here.

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const lr = @import("list_render.zig");
const ui = lr.ui;

pub const SearchConfig = struct {
    message: []const u8,
    choices: []const []const u8,
    prefix: []const u8 = "? ",
    unicode: bool = true,
};

/// Prompt with search filtering. Returns the index of the selected item in the
/// original choices array, `error.UserAborted` if the user presses Ctrl-C, or
/// `error.EndOfStream` if stdin closes with no line to submit.
pub fn search(p: Prompts, config: SearchConfig) !usize {
    const writer = p.writer;
    const reader = p.reader;
    const allocator = p.allocator;
    if (config.choices.len == 0) return error.NoChoices;
    const is_tty = terminal.isInteractiveTty();

    if (!is_tty) {
        // Non-TTY: same as select — numbered list
        try writer.print("{s}{s}\n", .{ config.prefix, config.message });
        for (config.choices, 1..) |choice, i| {
            try writer.print("  {d}) {s}\n", .{ i, choice });
        }
        try writer.writeAll("> ");
        // Flush so the prompt is visible before we block reading the reply —
        // buffered writers otherwise strand it until after input arrives.
        Prompts.flushWriter(writer);
        const line = try readLine(reader, allocator);
        defer allocator.free(line);
        const num = std.fmt.parseInt(usize, line, 10) catch return 0;
        if (num >= 1 and num <= config.choices.len) return num - 1;
        return 0;
    }

    // TTY: interactive search. A raw-mode failure must not fabricate a choice
    // (returning 0 would "select" the first item the user never saw) — surface
    // it instead.
    Prompts.flushWriter(writer);
    const raw = try terminal.enableRawMode(std.Io.File.stdin().handle);
    var watcher = terminal.ResizeWatcher.init();
    defer {
        watcher.deinit();
        raw.disable();
        Prompts.flushWriter(writer);
    }
    var app = try ui.App.init(p.allocator, writer, .{
        .capability = p.theme.capability(),
        .unicode = config.unicode,
        .hybrid_raw = raw,
    });
    defer app.deinit();

    var query = std.ArrayList(u8).empty;
    defer query.deinit(allocator);

    var filtered = try buildFiltered(allocator, config.choices, "");
    defer allocator.free(filtered);
    const stdin = std.Io.File.stdin().handle;
    var cursor: usize = 0;
    try renderFrame(&app, p.theme, config, query.items, filtered, cursor);

    while (true) {
        switch (try terminal.readEvent(reader, stdin, &watcher)) {
            .resize => try renderFrame(&app, p.theme, config, query.items, filtered, cursor),
            .key => |k| switch (k) {
                .up => {
                    if (cursor > 0) cursor -= 1;
                    try renderFrame(&app, p.theme, config, query.items, filtered, cursor);
                },
                .down => {
                    if (cursor < filtered.len -| 1) cursor += 1;
                    try renderFrame(&app, p.theme, config, query.items, filtered, cursor);
                },
                .enter => {
                    if (filtered.len > 0) {
                        const selected_idx = filtered[cursor];
                        try app.clear();
                        var obuf: [64]u8 = undefined;
                        const open = Prompts.openSeq(&obuf, p.theme, p.theme.promptTokens().selected);
                        try app.emit("  {s}{s}{s}", .{ open, config.choices[selected_idx], Prompts.closeSeq(open) });
                        return selected_idx;
                    }
                },
                .backspace => {
                    if (query.items.len > 0) {
                        Prompts.popTrailingGrapheme(&query);
                        // Build the replacement first: if it OOMs, `filtered`
                        // still points at the live slice, so the deferred free
                        // (and the next rebuild) stay valid — freeing first would
                        // leave a dangling pointer to double-free.
                        const next = try buildFiltered(allocator, config.choices, query.items);
                        allocator.free(filtered);
                        filtered = next;
                        cursor = 0;
                        try renderFrame(&app, p.theme, config, query.items, filtered, cursor);
                    }
                },
                .ctrl => |c| {
                    if (c == 'c') {
                        try app.clear();
                        return error.UserAborted;
                    }
                },
                .char => |c| {
                    _ = try Prompts.appendCodepoint(allocator, &query, c);
                    // See the backspace branch: build then swap, never free-then-build.
                    const next = try buildFiltered(allocator, config.choices, query.items);
                    allocator.free(filtered);
                    filtered = next;
                    cursor = 0;
                    try renderFrame(&app, p.theme, config, query.items, filtered, cursor);
                },
                else => {},
            },
            else => {}, // mouse/focus never arrive — prompts don't enable them
        }
    }
}

fn renderFrame(app: *ui.App, ctx: Prompts.ThemeContext, config: SearchConfig, query: []const u8, filtered: []const usize, cursor: usize) !void {
    try app.frame(try frameNode(app.arena(), ctx, config, query, filtered, cursor, lr.windowSize()));
}

/// Build array of indices into choices that match the query (case-insensitive substring).
fn buildFiltered(allocator: std.mem.Allocator, choices: []const []const u8, query: []const u8) ![]usize {
    var result = std.ArrayList(usize).empty;
    errdefer result.deinit(allocator);

    for (choices, 0..) |choice, i| {
        if (query.len == 0 or containsIgnoreCase(choice, query)) {
            try result.append(allocator, i);
        }
    }
    return try result.toOwnedSlice(allocator);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Build the header, search-input line, and viewport-limited results as one
/// frame. Pure and size-explicit so it is deterministic and unit-testable.
pub fn frameNode(
    a: std.mem.Allocator,
    ctx: Prompts.ThemeContext,
    config: SearchConfig,
    query: []const u8,
    filtered: []const usize,
    cursor: usize,
    ws: terminal.Winsize,
) !ui.Node {
    const width = @max(@as(usize, ws.col), 1);
    const usable: u16 = @intCast(@min(@max(width -| 1, 1), std.math.maxInt(u16)));
    const height = @max(@as(usize, ws.row), 2);

    const cursor_sym = terminal.symbols.select_cursor(config.unicode);
    const prefix_w: u16 = 4; // "  <cur> " / "    "
    const avail: u16 = @intCast(@max(@as(usize, usable) -| prefix_w, 1));

    var rows = std.ArrayList(ui.Node).empty;
    const tokens = ctx.promptTokens();
    const hint_style = ctx.resolveRef(tokens.hint);

    // Header line.
    const hprefix_w: u16 = @intCast(terminal.displayWidth(config.prefix));
    const havail: u16 = @intCast(@max(@as(usize, usable) -| hprefix_w, 1));
    try rows.append(a, try lr.itemRow(a, lr.prefixCell(.{}, config.prefix), hprefix_w, config.message, havail, .{}));
    var used: usize = terminal.wrapCount(config.message, havail);

    // Search-input line: "  Search: <query>" (hint-styled placeholder when empty).
    const search_prefix = "  Search: ";
    const search_prefix_w: u16 = @intCast(terminal.displayWidth(search_prefix));
    const savail: u16 = @intCast(@max(@as(usize, usable) -| search_prefix_w, 1));
    if (query.len > 0) {
        try rows.append(a, try lr.itemRow(a, lr.prefixCell(.{}, search_prefix), search_prefix_w, query, savail, .{}));
        used += terminal.wrapCount(query, savail);
    } else {
        try rows.append(a, try lr.itemRow(a, lr.prefixCell(.{}, search_prefix), search_prefix_w, "type to filter", savail, hint_style));
        used += 1;
    }

    if (filtered.len == 0) {
        try rows.append(a, try lr.itemRow(a, lr.prefixCell(.{}, "  "), 2, "no matches", avail, hint_style));
        return ui.column(a, .{ .width = .{ .len = usable } }, rows.items);
    }

    // Results viewport (row counts computed on demand).
    const Counter = struct {
        choices: []const []const u8,
        filtered: []const usize,
        avail: usize,
        fn at(self: *const @This(), i: usize) usize {
            return terminal.wrapCount(self.choices[self.filtered[i]], self.avail);
        }
    };
    const counter = Counter{ .choices = config.choices, .filtered = filtered, .avail = avail };
    const list_budget = @max((height -| 1) -| used, 1);
    const win = lr.viewport(filtered.len, cursor, list_budget, &counter, Counter.at);

    const selected_style = ctx.resolveRef(tokens.selected);
    for (win.start..win.end) |i| {
        const choice = config.choices[filtered[i]];
        const on = i == cursor;
        const prefix = if (on)
            lr.prefixCell(selected_style, try std.fmt.allocPrint(a, "  {s} ", .{cursor_sym}))
        else
            lr.prefixCell(.{}, "");
        try rows.append(a, try lr.itemRow(a, prefix, prefix_w, choice, avail, if (on) selected_style else .{}));
    }

    return ui.column(a, .{ .width = .{ .len = usable } }, rows.items);
}

/// Read a line byte by byte until newline. Returns `error.EndOfStream` if the
/// stream closes before any byte is read; a partial line terminated by EOF is
/// returned as the submitted line.
fn readLine(reader: anytype, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    while (true) {
        const byte = terminal.key.readByteFn(reader) catch {
            if (buf.items.len == 0) return error.EndOfStream;
            return try buf.toOwnedSlice(allocator);
        };
        if (byte == '\n') break;
        if (byte != '\r') try buf.append(allocator, byte);
    }
    return try buf.toOwnedSlice(allocator);
}

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("Fastify", "fast"));
    try std.testing.expect(containsIgnoreCase("fastify", "FAST"));
    try std.testing.expect(containsIgnoreCase("express", "press"));
    try std.testing.expect(!containsIgnoreCase("koa", "express"));
    try std.testing.expect(containsIgnoreCase("anything", ""));
}

test "buildFiltered matches all on empty query" {
    const allocator = std.testing.allocator;
    const choices = &[_][]const u8{ "alpha", "beta", "gamma" };
    const result = try buildFiltered(allocator, choices, "");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "buildFiltered failure leaves the caller's slice intact (rebuild is OOM-safe)" {
    // Regression for the rebuild double-free: the interactive loop now builds the
    // new filtered slice *before* freeing the old one, so an OOM mid-rebuild
    // can't dangle `filtered`. That relies on buildFiltered neither freeing nor
    // mutating anything the caller still owns when it fails — assert exactly that.
    const allocator = std.testing.allocator;
    const choices = &[_][]const u8{ "alpha", "beta", "gamma" };

    const filtered = try buildFiltered(allocator, choices, "");
    defer allocator.free(filtered); // must stay valid and be freed exactly once

    // Force the rebuild allocation to fail.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, buildFiltered(failing.allocator(), choices, "a"));

    // The original slice is untouched: still the full match set, still freeable.
    try std.testing.expectEqual(@as(usize, 3), filtered.len);
}

test "buildFiltered filters by substring" {
    const allocator = std.testing.allocator;
    const choices = &[_][]const u8{ "express", "fastify", "koa" };
    const result = try buildFiltered(allocator, choices, "fa");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(usize, 1), result[0]); // "fastify" at index 1
}

test "SearchConfig defaults" {
    const cfg = SearchConfig{ .message = "Pick:", .choices = &.{ "a", "b" } };
    try std.testing.expectEqualStrings("? ", cfg.prefix);
}

test "non-TTY: EOF errors instead of defaulting to index 0" {
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    try std.testing.expectError(error.EndOfStream, search(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Pick:",
        .choices = &.{ "a", "b" },
    }));
}

const FrameHarness = struct {
    arena: std.heap.ArenaAllocator,

    fn init() FrameHarness {
        return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }
    fn deinit(self: *FrameHarness) void {
        self.arena.deinit();
    }
    fn a(self: *FrameHarness) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn rctx(self: *FrameHarness) ui.RenderCtx {
        return .{ .allocator = self.a() };
    }
};

test "frameNode: header + search line + results measure one row each" {
    var h = FrameHarness.init();
    defer h.deinit();
    const filtered = [_]usize{ 0, 1, 2 };
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "alpha", "beta", "gamma" } }, "a", &filtered, 0, .{ .row = 24, .col = 80 });
    const rc = h.rctx();
    const size = ui.measure(&rc, &node, .{ .max_w = 100, .max_h = 50 });
    // header(1) + search(1) + 3 results = 5
    try std.testing.expectEqual(@as(u16, 5), size.h);
}

test "frameNode: empty query shows the hint-styled placeholder" {
    var h = FrameHarness.init();
    defer h.deinit();
    const filtered = [_]usize{ 0, 1 };
    const custom = Prompts.Theme{
        .prompts = .{ .hint = .{ .style = .{ .foreground = .{ .rgb = .{ .r = 7, .g = 7, .b = 7 } } } } },
    };
    const ctx = Prompts.ThemeContext{
        .theme = &custom,
        .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },
    };
    const node = try frameNode(h.a(), ctx, .{ .message = "Pick", .choices = &.{ "a", "b" } }, "", &filtered, 0, .{ .row = 24, .col = 80 });

    var s = try ui.Surface.init(std.testing.allocator, 79, 4);
    defer s.deinit();
    const rc = h.rctx();
    try ui.render(&rc, &node, s.root());

    // Row 1: "  Search: type to filter" — placeholder wears the hint token.
    try std.testing.expectEqualStrings("t", s.cellText(s.cell(10, 1)));
    try std.testing.expect(ui.styleEql(ctx.resolveRef(ctx.promptTokens().hint), s.cell(10, 1).style));
}

test "frameNode: no matches renders the hint row and stops" {
    var h = FrameHarness.init();
    defer h.deinit();
    const filtered = [_]usize{};
    const node = try frameNode(h.a(), Prompts.default_style, .{ .message = "Pick", .choices = &.{ "a", "b" } }, "zz", &filtered, 0, .{ .row = 24, .col = 80 });
    const rc = h.rctx();
    const size = ui.measure(&rc, &node, .{ .max_w = 100, .max_h = 50 });
    // header + query line + "no matches"
    try std.testing.expectEqual(@as(u16, 3), size.h);
}
