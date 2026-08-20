//! Shared implementation for single- and multi-selection prompts.
//!
//! `select.zig` and `multi_select.zig` intentionally keep their distinct
//! public return types. This module owns everything those prompts otherwise
//! have in common: filtering, navigation, selection state, terminal input,
//! non-TTY parsing, and rendering.

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const lr = @import("list_render.zig");
const ui = lr.ui;

pub const Cardinality = enum { one, many };

pub const Config = struct {
    message: []const u8,
    choices: []const []const u8,
    defaults: ?[]const bool = null,
    prefix: []const u8 = "? ",
    unicode: bool = true,
    search: bool = false,
    interrupt_keys: []const terminal.Key = &.{},
};

fn Result(comptime cardinality: Cardinality) type {
    return switch (cardinality) {
        .one => usize,
        .many => []usize,
    };
}

pub const State = struct {
    allocator: std.mem.Allocator,
    choices: []const []const u8,
    searchable: bool,
    query: std.ArrayList(u8),
    filtered: []usize,
    cursor: usize = 0,
    selected: ?[]bool,
    query_dirty: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        choices: []const []const u8,
        searchable: bool,
        defaults: ?[]const bool,
        cardinality: Cardinality,
    ) !State {
        const filtered = try buildFiltered(allocator, choices, "");
        errdefer allocator.free(filtered);

        var selected: ?[]bool = null;
        if (cardinality == .many) {
            const values = try allocator.alloc(bool, choices.len);
            if (defaults) |d| {
                for (values, 0..) |*value, i| value.* = i < d.len and d[i];
            } else {
                @memset(values, false);
            }
            selected = values;
        }

        return .{
            .allocator = allocator,
            .choices = choices,
            .searchable = searchable,
            .query = .empty,
            .filtered = filtered,
            .selected = selected,
        };
    }

    pub fn deinit(self: *State) void {
        self.query.deinit(self.allocator);
        self.allocator.free(self.filtered);
        if (self.selected) |values| self.allocator.free(values);
    }

    /// Add searchable input. Space is deliberately not query text: it always
    /// activates the highlighted choice, matching established multi-select
    /// prompt behavior and enabling the fast type/space/type/space workflow.
    pub fn typeCodepoint(self: *State, c: u21) !void {
        if (!self.searchable or c == ' ' or !isPrintable(c)) return;
        _ = try Prompts.appendCodepoint(self.allocator, &self.query, c);
        self.query_dirty = true;
    }

    pub fn backspace(self: *State) void {
        if (!self.searchable or self.query.items.len == 0) return;
        Prompts.popTrailingGrapheme(&self.query);
        self.query_dirty = true;
    }

    /// Rebuild visibility after query edits. Build-before-free keeps the state
    /// valid if allocation fails.
    pub fn settle(self: *State) !void {
        if (!self.query_dirty) return;
        const next = try buildFiltered(self.allocator, self.choices, self.query.items);
        self.allocator.free(self.filtered);
        self.filtered = next;
        self.cursor = 0;
        self.query_dirty = false;
    }

    pub fn moveUp(self: *State) void {
        if (self.cursor > 0) self.cursor -= 1;
    }

    pub fn moveDown(self: *State) void {
        if (self.cursor < self.filtered.len -| 1) self.cursor += 1;
    }

    pub fn highlighted(self: *const State) ?usize {
        if (self.filtered.len == 0) return null;
        return self.filtered[self.cursor];
    }

    pub fn toggleHighlighted(self: *State) void {
        const original = self.highlighted() orelse return;
        const values = self.selected orelse return;
        values[original] = !values[original];
    }

    pub fn collectSelected(self: *const State) ![]usize {
        var result = std.ArrayList(usize).empty;
        errdefer result.deinit(self.allocator);
        if (self.selected) |values| {
            for (values, 0..) |on, i| {
                if (on) try result.append(self.allocator, i);
            }
        }
        return try result.toOwnedSlice(self.allocator);
    }
};

fn isPrintable(c: u21) bool {
    return c >= 0x20 and c != 0x7f and !(c >= 0x80 and c <= 0x9f);
}

pub fn run(comptime cardinality: Cardinality, p: Prompts, config: Config) !Result(cardinality) {
    if (config.choices.len == 0) return error.NoChoices;
    if (!terminal.isInteractiveTty()) return nonTty(cardinality, p, config);

    Prompts.flushWriter(p.writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch |err| {
        // Preserve multiSelect's historical fallback while single selection
        // continues to surface raw-mode failures rather than inventing a pick.
        if (cardinality == .many) return collectDefaults(p.allocator, config);
        return err;
    };
    var watcher = terminal.ResizeWatcher.init();
    defer {
        watcher.deinit();
        raw.disable();
        Prompts.flushWriter(p.writer);
    }
    var app = try ui.App.init(p.allocator, p.writer, .{
        .capability = p.theme.capability(),
        .unicode = config.unicode,
        .hybrid_raw = raw,
    });
    defer app.deinit();

    var state = try State.init(p.allocator, config.choices, config.search, config.defaults, cardinality);
    defer state.deinit();

    const stdin = std.Io.File.stdin().handle;
    try renderFrame(&app, p.theme, config, cardinality, &state);
    while (true) {
        switch (try terminal.readEvent(p.reader, stdin, &watcher)) {
            .resize => {},
            .key => |key| {
                switch (try dispatchKey(cardinality, &state, key, config.interrupt_keys)) {
                    .continue_prompt => {},
                    .select_one => |chosen| {
                        if (cardinality == .one) return try finishOne(&app, p, config, chosen);
                        unreachable;
                    },
                    .confirm_many => {
                        if (cardinality == .many) {
                            try app.clear();
                            try emitMany(&app, p, config, &state);
                            return try state.collectSelected();
                        }
                        unreachable;
                    },
                    .user_aborted => {
                        try app.clear();
                        return error.UserAborted;
                    },
                    .interrupted => {
                        try app.clear();
                        return error.Interrupted;
                    },
                }
            },
            else => {}, // mouse/focus never arrive — prompts don't enable them
        }

        // Coalesce buffered text (notably paste) into one filter rebuild. Keys
        // that act on the visible list settle above before using its cursor.
        if (terminal.key.bufferedLen(p.reader) == 0) {
            try state.settle();
            try renderFrame(&app, p.theme, config, cardinality, &state);
        }
    }
}

const Dispatch = union(enum) {
    continue_prompt,
    select_one: usize,
    confirm_many,
    user_aborted,
    interrupted,
};

/// Apply one raw key event. Query text remains dirty until the reader's input
/// buffer drains; keys that act on the visible list settle it immediately.
fn dispatchKey(
    comptime cardinality: Cardinality,
    state: *State,
    key: terminal.Key,
    interrupt_keys: []const terminal.Key,
) !Dispatch {
    if (Prompts.isInterrupt(key, interrupt_keys)) return .interrupted;

    switch (key) {
        .up => {
            try state.settle();
            state.moveUp();
        },
        .down => {
            try state.settle();
            state.moveDown();
        },
        .backspace => state.backspace(),
        .char => |c| {
            if (c != ' ') {
                try state.typeCodepoint(c);
            } else {
                try state.settle();
                if (cardinality == .one) {
                    if (state.highlighted()) |chosen| return .{ .select_one = chosen };
                } else {
                    state.toggleHighlighted();
                }
            }
        },
        .enter => {
            try state.settle();
            if (cardinality == .one) {
                if (state.highlighted()) |chosen| return .{ .select_one = chosen };
            } else {
                return .confirm_many;
            }
        },
        .ctrl => |c| if (c == 'c') return .user_aborted,
        else => {},
    }
    return .continue_prompt;
}

fn finishOne(app: *ui.App, p: Prompts, config: Config, chosen: usize) !usize {
    try app.clear();
    var obuf: [64]u8 = undefined;
    const open = Prompts.openSeq(&obuf, p.theme, p.theme.promptTokens().selected);
    try app.emit("  {s}{s}{s}", .{ open, config.choices[chosen], Prompts.closeSeq(open) });
    return chosen;
}

fn emitMany(app: *ui.App, p: Prompts, config: Config, state: *const State) !void {
    var summary = std.ArrayList(u8).empty;
    defer summary.deinit(p.allocator);
    const values = state.selected.?;
    for (config.choices, 0..) |choice, i| {
        if (values[i]) {
            if (summary.items.len > 0) try summary.appendSlice(p.allocator, ", ");
            try summary.appendSlice(p.allocator, choice);
        }
    }
    var obuf: [64]u8 = undefined;
    const open = Prompts.openSeq(&obuf, p.theme, p.theme.promptTokens().selected);
    try app.emit("  {s}{s}{s}", .{ open, summary.items, Prompts.closeSeq(open) });
}

fn nonTty(comptime cardinality: Cardinality, p: Prompts, config: Config) !Result(cardinality) {
    if (cardinality == .one) {
        try p.writer.print("{s}{s}\r\n", .{ config.prefix, config.message });
        for (config.choices, 1..) |choice, i| try p.writer.print("  {d}) {s}\n", .{ i, choice });
        try p.writer.writeAll("> ");
        Prompts.flushWriter(p.writer);
        const line = try readLine(p.reader, p.allocator);
        defer p.allocator.free(line);
        const num = std.fmt.parseInt(usize, line, 10) catch return error.InvalidSelection;
        if (num >= 1 and num <= config.choices.len) return num - 1;
        return error.InvalidSelection;
    }

    try p.writer.print("{s}{s} (space to toggle, enter to confirm)\r\n", .{ config.prefix, config.message });
    for (config.choices, 1..) |choice, i| {
        const on = if (config.defaults) |d| i - 1 < d.len and d[i - 1] else false;
        try p.writer.print("  {d}) {s} {s}\n", .{ i, if (on) "[x]" else "[ ]", choice });
    }
    try p.writer.writeAll("> ");
    Prompts.flushWriter(p.writer);
    const line = try readLine(p.reader, p.allocator);
    defer p.allocator.free(line);
    if (line.len == 0) return collectDefaults(p.allocator, config);

    var result = std.ArrayList(usize).empty;
    errdefer result.deinit(p.allocator);
    var iter = std.mem.splitScalar(u8, line, ',');
    while (iter.next()) |part| {
        const num = std.fmt.parseInt(usize, std.mem.trim(u8, part, " "), 10) catch continue;
        if (num >= 1 and num <= config.choices.len) try result.append(p.allocator, num - 1);
    }
    return try result.toOwnedSlice(p.allocator);
}

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

fn collectDefaults(allocator: std.mem.Allocator, config: Config) ![]usize {
    var result = std.ArrayList(usize).empty;
    errdefer result.deinit(allocator);
    if (config.defaults) |defaults| {
        for (0..@min(defaults.len, config.choices.len)) |i| {
            if (defaults[i]) try result.append(allocator, i);
        }
    }
    return try result.toOwnedSlice(allocator);
}

pub fn buildFiltered(allocator: std.mem.Allocator, choices: []const []const u8, query: []const u8) ![]usize {
    var result = std.ArrayList(usize).empty;
    errdefer result.deinit(allocator);
    for (choices, 0..) |choice, i| {
        if (query.len == 0 or containsIgnoreCase(choice, query)) try result.append(allocator, i);
    }
    return try result.toOwnedSlice(allocator);
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matches = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn renderFrame(app: *ui.App, ctx: Prompts.ThemeContext, config: Config, cardinality: Cardinality, state: *const State) !void {
    try app.frame(try frameNode(app.arena(), ctx, config, cardinality, state.query.items, state.filtered, state.selected, state.cursor, lr.windowSize()));
}

pub fn frameNode(
    a: std.mem.Allocator,
    ctx: Prompts.ThemeContext,
    config: Config,
    cardinality: Cardinality,
    query: []const u8,
    filtered: []const usize,
    selected: ?[]const bool,
    cursor: usize,
    ws: terminal.Winsize,
) !ui.Node {
    const width = @max(@as(usize, ws.col), 1);
    const usable: u16 = @intCast(@min(@max(width -| 1, 1), std.math.maxInt(u16)));
    const height = @max(@as(usize, ws.row), 2);
    const glyphs = ctx.glyphTokens();
    const cursor_sym = glyphs.select_cursor.pick(config.unicode);
    const sel_sym = glyphs.selected.pick(config.unicode);
    const unsel_sym = glyphs.unselected.pick(config.unicode);
    const prefix_w: u16 = if (cardinality == .many)
        @intCast(5 + terminal.displayWidth(sel_sym))
    else
        4;
    const avail: u16 = @intCast(@max(@as(usize, usable) -| prefix_w, 1));

    var rows = std.ArrayList(ui.Node).empty;
    const tokens = ctx.promptTokens();
    const hint_style = ctx.resolveRef(tokens.hint);
    const hprefix_w: u16 = @intCast(terminal.displayWidth(config.prefix));
    const havail: u16 = @intCast(@max(@as(usize, usable) -| hprefix_w, 1));
    const header = if (cardinality == .many)
        try std.fmt.allocPrint(a, "{s} (space to toggle, enter to confirm)", .{config.message})
    else if (config.search)
        try std.fmt.allocPrint(a, "{s} (space/enter to select)", .{config.message})
    else
        config.message;
    try rows.append(a, try lr.itemRow(a, lr.prefixCell(.{}, config.prefix), hprefix_w, header, havail, .{}));
    var used: usize = terminal.wrapCount(header, havail);

    if (config.search) {
        const search_prefix = "  Search: ";
        const search_prefix_w: u16 = @intCast(terminal.displayWidth(search_prefix));
        const search_avail: u16 = @intCast(@max(@as(usize, usable) -| search_prefix_w, 1));
        if (query.len > 0) {
            try rows.append(a, try lr.itemRow(a, lr.prefixCell(.{}, search_prefix), search_prefix_w, query, search_avail, .{}));
            used += terminal.wrapCount(query, search_avail);
        } else {
            try rows.append(a, try lr.itemRow(a, lr.prefixCell(.{}, search_prefix), search_prefix_w, "type to filter", search_avail, hint_style));
            used += 1;
        }
    }

    if (filtered.len == 0) {
        try rows.append(a, try lr.itemRow(a, lr.prefixCell(.{}, "  "), 2, "no matches", avail, hint_style));
        return ui.column(a, .{ .width = .{ .len = usable } }, rows.items);
    }

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
    const cursor_style = ctx.resolveRef(tokens.cursor);
    const marker_style = ctx.resolveRef(tokens.marker);

    for (win.start..win.end) |visible| {
        const original = filtered[visible];
        const on = visible == cursor;
        if (cardinality == .many) {
            const marker = if (selected.?[original]) sel_sym else unsel_sym;
            const prefix = if (on)
                try ui.row(a, .{}, &.{
                    lr.prefixCell(.{}, "  "),
                    lr.prefixCell(cursor_style, cursor_sym),
                    lr.prefixCell(.{}, " "),
                    lr.prefixCell(marker_style, marker),
                })
            else
                try ui.row(a, .{}, &.{
                    lr.prefixCell(.{}, "    "),
                    lr.prefixCell(.{}, marker),
                });
            try rows.append(a, try lr.itemRow(a, prefix, prefix_w, config.choices[original], avail, .{}));
        } else {
            const prefix = if (on)
                lr.prefixCell(selected_style, try std.fmt.allocPrint(a, "  {s} ", .{cursor_sym}))
            else
                lr.prefixCell(.{}, "");
            try rows.append(a, try lr.itemRow(a, prefix, prefix_w, config.choices[original], avail, if (on) selected_style else .{}));
        }
    }
    return ui.column(a, .{ .width = .{ .len = usable } }, rows.items);
}

test "state filters to original indices and resets the visible cursor" {
    var state = try State.init(std.testing.allocator, &.{ "alpha", "Beta", "alphabet" }, true, null, .one);
    defer state.deinit();
    state.cursor = 2;
    try state.typeCodepoint('b');
    try state.typeCodepoint('e');
    try state.settle();
    try std.testing.expectEqualStrings("be", state.query.items);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, state.filtered);
    try std.testing.expectEqual(@as(usize, 0), state.cursor);
}

test "raw dispatch: searchable multi type-space-type-space-enter flow" {
    var state = try State.init(std.testing.allocator, &.{ "alpha", "amber", "beta" }, true, null, .many);
    defer state.deinit();

    try std.testing.expect(try dispatchKey(.many, &state, .{ .char = 'a' }, &.{}) == .continue_prompt);
    // Text remains dirty for run's buffered-input coalescing boundary.
    try std.testing.expect(state.query_dirty);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, state.filtered);
    try std.testing.expect(try dispatchKey(.many, &state, .{ .char = ' ' }, &.{}) == .continue_prompt);
    try std.testing.expect(try dispatchKey(.many, &state, .{ .char = 'm' }, &.{}) == .continue_prompt);
    try std.testing.expect(try dispatchKey(.many, &state, .{ .char = ' ' }, &.{}) == .continue_prompt);
    try std.testing.expect(try dispatchKey(.many, &state, .enter, &.{}) == .confirm_many);

    try std.testing.expectEqualStrings("am", state.query.items);
    try std.testing.expectEqualSlices(usize, &.{1}, state.filtered);
    const chosen = try state.collectSelected();
    defer std.testing.allocator.free(chosen);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, chosen);
}

test "raw dispatch: searchable single Space selects and ignores no matches" {
    var matching = try State.init(std.testing.allocator, &.{ "alpha", "beta" }, true, null, .one);
    defer matching.deinit();
    try std.testing.expect(try dispatchKey(.one, &matching, .{ .char = 'b' }, &.{}) == .continue_prompt);
    const selected = try dispatchKey(.one, &matching, .{ .char = ' ' }, &.{});
    try std.testing.expectEqual(@as(usize, 1), selected.select_one);
    try std.testing.expectEqualStrings("b", matching.query.items);

    var no_match = try State.init(std.testing.allocator, &.{ "alpha", "beta" }, true, null, .one);
    defer no_match.deinit();
    try std.testing.expect(try dispatchKey(.one, &no_match, .{ .char = 'z' }, &.{}) == .continue_prompt);
    try std.testing.expect(try dispatchKey(.one, &no_match, .{ .char = ' ' }, &.{}) == .continue_prompt);
    try std.testing.expectEqual(@as(usize, 0), no_match.filtered.len);
}

test "raw dispatch: plain single select also selects on Space" {
    var state = try State.init(std.testing.allocator, &.{ "alpha", "beta" }, false, null, .one);
    defer state.deinit();
    state.cursor = 1;
    const selected = try dispatchKey(.one, &state, .{ .char = ' ' }, &.{});
    try std.testing.expectEqual(@as(usize, 1), selected.select_one);
}

test "only printable non-space codepoints become query text" {
    var state = try State.init(std.testing.allocator, &.{"alpha"}, true, null, .one);
    defer state.deinit();
    try state.typeCodepoint(0);
    try state.typeCodepoint(0x7f);
    try state.typeCodepoint(0x85);
    try state.typeCodepoint(' ');
    try state.typeCodepoint('é');
    try std.testing.expectEqualStrings("é", state.query.items);
}

test "multi selection survives filtering and uses original indices" {
    var state = try State.init(std.testing.allocator, &.{ "alpha", "beta", "gamma" }, true, null, .many);
    defer state.deinit();
    state.cursor = 1;
    state.toggleHighlighted(); // beta (original index 1)
    try state.typeCodepoint('g');
    try state.settle();
    try std.testing.expectEqualSlices(usize, &.{2}, state.filtered);
    state.toggleHighlighted(); // gamma (original index 2)
    const chosen = try state.collectSelected();
    defer std.testing.allocator.free(chosen);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, chosen);
}

test "no matches has no highlighted choice and preserves hidden selections" {
    var state = try State.init(std.testing.allocator, &.{ "alpha", "beta" }, true, &.{ false, true }, .many);
    defer state.deinit();
    try state.typeCodepoint('z');
    try state.settle();

    state.moveUp();
    state.moveDown();
    state.toggleHighlighted();
    try std.testing.expect(state.highlighted() == null);

    const chosen = try state.collectSelected();
    defer std.testing.allocator.free(chosen);
    try std.testing.expectEqualSlices(usize, &.{1}, chosen);
}

test "non-search state ignores query editing and keeps arrow navigation" {
    var state = try State.init(std.testing.allocator, &.{ "alpha", "beta", "gamma" }, false, null, .one);
    defer state.deinit();

    try state.typeCodepoint('b');
    state.backspace();
    try state.settle();
    state.moveDown();
    state.moveDown();
    state.moveUp();

    try std.testing.expectEqual(@as(usize, 0), state.query.items.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, state.filtered);
    try std.testing.expectEqual(@as(?usize, 1), state.highlighted());
}

test "filtered multi render reads selection state by original index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const node = try frameNode(
        a,
        Prompts.default_style,
        .{ .message = "Pick", .choices = &.{ "alpha", "beta", "gamma" }, .unicode = false, .search = true },
        .many,
        "g",
        &.{2},
        &.{ false, false, true },
        0,
        .{ .row = 24, .col = 80 },
    );

    var surface = try ui.Surface.init(std.testing.allocator, 79, 3);
    defer surface.deinit();
    const rc = ui.RenderCtx{ .allocator = a };
    try ui.render(&rc, &node, surface.root());

    // Header and query occupy rows 0 and 1. The only visible result is gamma,
    // whose selected bit lives at original index 2 rather than visible index 0.
    try std.testing.expectEqualStrings("x", surface.cellText(surface.cell(5, 2)));
    try std.testing.expectEqualStrings("g", surface.cellText(surface.cell(8, 2)));
}

test "backspace edits one trailing grapheme and restores matches" {
    var state = try State.init(std.testing.allocator, &.{ "cafe", "café", "tea" }, true, null, .one);
    defer state.deinit();
    try state.typeCodepoint('é');
    try state.settle();
    try std.testing.expectEqualSlices(usize, &.{1}, state.filtered);
    state.backspace();
    try state.settle();
    try std.testing.expectEqual(@as(usize, 3), state.filtered.len);
}

test "containsIgnoreCase matches ASCII substrings" {
    try std.testing.expect(containsIgnoreCase("Fastify", "fast"));
    try std.testing.expect(containsIgnoreCase("fastify", "FAST"));
    try std.testing.expect(containsIgnoreCase("express", "press"));
    try std.testing.expect(!containsIgnoreCase("koa", "express"));
    try std.testing.expect(containsIgnoreCase("anything", ""));
}

test "buildFiltered preserves original indices" {
    const result = try buildFiltered(std.testing.allocator, &.{ "express", "fastify", "koa" }, "fa");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(usize, &.{1}, result);
}

test "buildFiltered failure leaves an existing slice owned by its caller" {
    const allocator = std.testing.allocator;
    const choices = &[_][]const u8{ "alpha", "beta", "gamma" };
    const filtered = try buildFiltered(allocator, choices, "");
    defer allocator.free(filtered);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, buildFiltered(failing.allocator(), choices, "a"));
    try std.testing.expectEqual(@as(usize, 3), filtered.len);
}
