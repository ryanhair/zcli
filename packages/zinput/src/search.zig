//! Search/filter prompt — type to filter a list, arrow keys to navigate, Enter to select.

const std = @import("std");
const terminal = @import("terminal");
const zinput = @import("zinput.zig");

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
    try writer.print("{s}{s}\r\n", .{ config.prefix, config.message });
    zinput.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch return 0;
    try writer.writeAll(terminal.ansi.hide_cursor);
    defer {
        writer.writeAll(terminal.ansi.show_cursor) catch {};
        raw.disable();
        zinput.flushWriter(writer);
    }

    var query = std.ArrayList(u8).empty;
    defer query.deinit(allocator);

    // Build initial index mapping (all items)
    var filtered = try buildFiltered(allocator, config.choices, "");
    defer allocator.free(filtered);
    var cursor: usize = 0;
    var rendered_lines: usize = 0;

    // Initial render
    rendered_lines = try renderSearch(writer, config, query.items, filtered, cursor);

    while (true) {
        zinput.flushWriter(writer);
        const k = try terminal.readKey(reader);
        switch (k) {
            .up => {
                if (cursor > 0) cursor -= 1;
                try eraseRendered(writer, rendered_lines);
                rendered_lines = try renderSearch(writer, config, query.items, filtered, cursor);
            },
            .down => {
                if (cursor < filtered.len -| 1) cursor += 1;
                try eraseRendered(writer, rendered_lines);
                rendered_lines = try renderSearch(writer, config, query.items, filtered, cursor);
            },
            .enter => {
                if (filtered.len > 0) {
                    const selected_idx = filtered[cursor];
                    try eraseRendered(writer, rendered_lines);
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
                    try eraseRendered(writer, rendered_lines);
                    rendered_lines = try renderSearch(writer, config, query.items, filtered, cursor);
                }
            },
            .ctrl => |c| {
                if (c == 'c') {
                    try eraseRendered(writer, rendered_lines);
                    return error.UserAborted;
                }
            },
            .char => |c| {
                try query.append(allocator, c);
                allocator.free(filtered);
                filtered = try buildFiltered(allocator, config.choices, query.items);
                cursor = 0;
                try eraseRendered(writer, rendered_lines);
                rendered_lines = try renderSearch(writer, config, query.items, filtered, cursor);
            },
            else => {},
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

fn renderSearch(writer: anytype, config: SearchConfig, query: []const u8, filtered: []const usize, cursor: usize) !usize {
    // Line 1: search input
    try writer.writeAll("  Search: ");
    if (query.len > 0) {
        try writer.writeAll(query);
    } else {
        try writer.writeAll("\x1b[2mtype to filter\x1b[0m");
    }
    try writer.writeAll("\r\n");

    var lines: usize = 1;

    // Filtered results (max 7 visible)
    const max_visible: usize = 7;
    const visible_count = @min(filtered.len, max_visible);

    const marker = terminal.symbols.select_cursor(config.unicode);

    if (filtered.len == 0) {
        try writer.writeAll("  \x1b[2mno matches\x1b[0m\r\n");
        lines += 1;
    } else {
        // Calculate scroll window
        const start = if (cursor >= max_visible) cursor - max_visible + 1 else 0;
        for (0..visible_count) |i| {
            const idx = start + i;
            if (idx >= filtered.len) break;
            const choice_idx = filtered[idx];
            if (idx == cursor) {
                try writer.print("  \x1b[36m{s} {s}\x1b[0m\r\n", .{ marker, config.choices[choice_idx] });
            } else {
                try writer.print("    {s}\r\n", .{config.choices[choice_idx]});
            }
            lines += 1;
        }
    }

    return lines;
}

fn eraseRendered(writer: anytype, lines: usize) !void {
    for (0..lines) |_| {
        try writer.writeAll("\x1b[A\r\x1b[K");
    }
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
