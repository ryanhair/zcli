//! Search/filter prompt — type to filter a list, arrow keys to navigate, Enter to select.

const std = @import("std");
const terminal = @import("terminal");
const zinput = @import("zinput.zig");
const lr = @import("list_render.zig");

pub const SearchConfig = struct {
    message: []const u8,
    choices: []const []const u8,
    prefix: []const u8 = "? ",
    unicode: bool = true,
};

/// Prompt with search filtering. Returns the index of the selected item in the original choices array.
pub fn search(writer: anytype, reader: anytype, allocator: std.mem.Allocator, config: SearchConfig) !usize {
    if (config.choices.len == 0) return error.NoChoices;
    const is_tty = terminal.isStdinTty();

    if (!is_tty) {
        // Non-TTY: same as select — numbered list
        try writer.print("{s}{s}\n", .{ config.prefix, config.message });
        for (config.choices, 1..) |choice, i| {
            try writer.print("  {d}) {s}\n", .{ i, choice });
        }
        try writer.writeAll("> ");
        const line = readLine(reader, allocator) catch return 0;
        defer allocator.free(line);
        const num = std.fmt.parseInt(usize, line, 10) catch return 0;
        if (num >= 1 and num <= config.choices.len) return num - 1;
        return 0;
    }

    // TTY: interactive search
    zinput.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch return 0;
    try writer.writeAll(terminal.ansi.hide_cursor);
    var watcher = terminal.ResizeWatcher.init();
    defer {
        writer.writeAll(terminal.ansi.show_cursor) catch {};
        watcher.deinit();
        raw.disable();
        zinput.flushWriter(writer);
    }

    var query = std.ArrayList(u8).empty;
    defer query.deinit(allocator);

    var filtered = try buildFiltered(allocator, config.choices, "");
    defer allocator.free(filtered);
    const stdin = std.Io.File.stdin().handle;
    var cursor: usize = 0;
    var rows = try renderSearch(writer, config, query.items, filtered, cursor, lr.windowSize());

    while (true) {
        zinput.flushWriter(writer);
        switch (try terminal.readEvent(reader, stdin, &watcher)) {
            .resize => {
                try lr.eraseRegion(writer, rows);
                rows = try renderSearch(writer, config, query.items, filtered, cursor, lr.windowSize());
            },
            .key => |k| switch (k) {
                .up => {
                    if (cursor > 0) cursor -= 1;
                    try lr.eraseRegion(writer, rows);
                    rows = try renderSearch(writer, config, query.items, filtered, cursor, lr.windowSize());
                },
                .down => {
                    if (cursor < filtered.len -| 1) cursor += 1;
                    try lr.eraseRegion(writer, rows);
                    rows = try renderSearch(writer, config, query.items, filtered, cursor, lr.windowSize());
                },
                .enter => {
                    if (filtered.len > 0) {
                        const selected_idx = filtered[cursor];
                        try lr.eraseRegion(writer, rows);
                        try writer.print("  \x1b[36m{s}\x1b[0m\r\n", .{config.choices[selected_idx]});
                        return selected_idx;
                    }
                },
                .backspace => {
                    if (query.items.len > 0) {
                        _ = query.pop();
                        allocator.free(filtered);
                        filtered = try buildFiltered(allocator, config.choices, query.items);
                        cursor = 0;
                        try lr.eraseRegion(writer, rows);
                        rows = try renderSearch(writer, config, query.items, filtered, cursor, lr.windowSize());
                    }
                },
                .ctrl => |c| {
                    if (c == 'c') {
                        try lr.eraseRegion(writer, rows);
                        return error.UserAborted;
                    }
                },
                .char => |c| {
                    try query.append(allocator, c);
                    allocator.free(filtered);
                    filtered = try buildFiltered(allocator, config.choices, query.items);
                    cursor = 0;
                    try lr.eraseRegion(writer, rows);
                    rows = try renderSearch(writer, config, query.items, filtered, cursor, lr.windowSize());
                },
                else => {},
            },
        }
    }
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

/// Render the header, search-input line, and viewport-limited results, returning
/// the number of physical rows emitted. Width is an explicit parameter so this
/// is deterministic/testable.
fn renderSearch(
    writer: anytype,
    config: SearchConfig,
    query: []const u8,
    filtered: []const usize,
    cursor: usize,
    ws: terminal.Winsize,
) !usize {
    const width = @max(@as(usize, ws.col), 1);
    const usable = @max(width -| 1, 1);
    const height = @max(@as(usize, ws.row), 2);

    const cursor_sym = terminal.symbols.select_cursor(config.unicode);
    const prefix_w: usize = 4; // "  <cur> " / "    "
    const avail = @max(usable -| prefix_w, 1);

    var rows: usize = 0;
    var first_line = true;

    // Header line.
    const hprefix_w = terminal.displayWidth(config.prefix);
    rows += try lr.renderItem(writer, &first_line, .{ .first_prefix = config.prefix, .prefix_w = hprefix_w }, config.message, @max(usable -| hprefix_w, 1));

    // Search-input line: "  Search: <query>".
    const search_prefix = "  Search: ";
    const search_prefix_w = terminal.displayWidth(search_prefix);
    const query_label = if (query.len > 0) query else "\x1b[2mtype to filter\x1b[0m";
    rows += try lr.renderItem(writer, &first_line, .{ .first_prefix = search_prefix, .prefix_w = search_prefix_w }, query_label, @max(usable -| search_prefix_w, 1));

    if (filtered.len == 0) {
        rows += try lr.renderItem(writer, &first_line, .{ .first_prefix = "  ", .prefix_w = 2 }, "\x1b[2mno matches\x1b[0m", avail);
        return rows;
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
    const list_budget = @max((height -| 1) -| rows, 1);
    const win = lr.viewport(filtered.len, cursor, list_budget, &counter, Counter.at);

    for (win.start..win.end) |i| {
        const choice = config.choices[filtered[i]];
        var pbuf: [32]u8 = undefined;
        const style: lr.ItemStyle = if (i == cursor)
            .{
                .line_open = "\x1b[36m",
                .first_prefix = std.fmt.bufPrint(&pbuf, "  {s} ", .{cursor_sym}) catch "  ",
                .prefix_w = prefix_w,
                .line_close = "\x1b[0m",
            }
        else
            .{ .first_prefix = "    ", .prefix_w = prefix_w };
        rows += try lr.renderItem(writer, &first_line, style, choice, avail);
    }

    return rows;
}

fn readLine(reader: anytype, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    while (true) {
        const byte = terminal.key.readByteFn(reader) catch return try buf.toOwnedSlice(allocator);
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

fn renderToBuf(buf: []u8, config: SearchConfig, query: []const u8, filtered: []const usize, cursor: usize, ws: terminal.Winsize) !struct { rows: usize, text: []const u8 } {
    var w: std.Io.Writer = .fixed(buf);
    const rows = try renderSearch(&w, config, query, filtered, cursor, ws);
    return .{ .rows = rows, .text = w.buffered() };
}

test "renderSearch: header + search line + results, row count matches lines" {
    var buf: [4096]u8 = undefined;
    const filtered = [_]usize{ 0, 1, 2 };
    const r = try renderToBuf(&buf, .{ .message = "Pick", .choices = &.{ "alpha", "beta", "gamma" } }, "a", &filtered, 0, .{ .row = 24, .col = 80 });
    // header(1) + search(1) + 3 results = 5
    try std.testing.expectEqual(@as(usize, 5), r.rows);
    const lines = std.mem.count(u8, r.text, "\r\n") + 1;
    try std.testing.expectEqual(lines, r.rows);
}

test "renderSearch: no matches renders a message row" {
    var buf: [1024]u8 = undefined;
    const empty = [_]usize{};
    const r = try renderToBuf(&buf, .{ .message = "Pick", .choices = &.{ "a", "b" } }, "zzz", &empty, 0, .{ .row = 24, .col = 80 });
    try std.testing.expectEqual(@as(usize, 3), r.rows); // header + search + "no matches"
    try std.testing.expect(std.mem.indexOf(u8, r.text, "no matches") != null);
}
