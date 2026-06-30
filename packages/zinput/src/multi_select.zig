//! Multi-selection prompt with toggle via space key.

const std = @import("std");
const terminal = @import("terminal");
const zinput = @import("zinput.zig");

pub const MultiSelectConfig = struct {
    message: []const u8,
    choices: []const []const u8,
    defaults: ?[]const bool = null,
    prefix: []const u8 = "? ",
    unicode: bool = true,
};

/// Prompt to select multiple items. Returns owned slice of selected indices.
pub fn multiSelect(writer: anytype, reader: anytype, allocator: std.mem.Allocator, config: MultiSelectConfig) ![]usize {
    if (config.choices.len == 0) return error.NoChoices;
    const is_tty = terminal.isStdinTty();

    try writer.print("{s}{s} (space to toggle, enter to confirm)\r\n", .{ config.prefix, config.message });

    if (!is_tty) {
        // Non-TTY: numbered list, accept comma-separated numbers
        for (config.choices, 1..) |choice, i| {
            const is_default = if (config.defaults) |d| (i - 1 < d.len and d[i - 1]) else false;
            const marker: []const u8 = if (is_default) "[x]" else "[ ]";
            try writer.print("  {d}) {s} {s}\n", .{ i, marker, choice });
        }
        try writer.writeAll("> ");

        const line = readLine(reader, allocator) catch return collectDefaults(allocator, config);
        defer allocator.free(line);
        if (line.len == 0) return collectDefaults(allocator, config);

        // Parse comma-separated numbers
        var result = std.ArrayList(usize).empty;
        var iter = std.mem.splitScalar(u8, line, ',');
        while (iter.next()) |part| {
            const num_str = std.mem.trim(u8, part, " ");
            const num = std.fmt.parseInt(usize, num_str, 10) catch continue;
            if (num >= 1 and num <= config.choices.len) {
                try result.append(allocator, num - 1);
            }
        }
        return try result.toOwnedSlice(allocator);
    }

    // TTY: interactive multi-select
    zinput.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch {
        return collectDefaults(allocator, config);
    };
    try writer.writeAll(terminal.ansi.hide_cursor);
    defer {
        writer.writeAll(terminal.ansi.show_cursor) catch {};
        raw.disable();
        zinput.flushWriter(writer);
    }

    var selected = try allocator.alloc(bool, config.choices.len);
    defer allocator.free(selected);
    if (config.defaults) |d| {
        for (0..config.choices.len) |i| {
            selected[i] = if (i < d.len) d[i] else false;
        }
    } else {
        @memset(selected, false);
    }

    var cursor: usize = 0;

    try renderMultiSelectList(writer, config.choices, selected, cursor, config.unicode);

    while (true) {
        zinput.flushWriter(writer);
        const k = try terminal.readKey(reader);
        switch (k) {
            .up => {
                if (cursor > 0) cursor -= 1;
                try eraseList(writer, config.choices.len);
                try renderMultiSelectList(writer, config.choices, selected, cursor, config.unicode);
            },
            .down => {
                if (cursor < config.choices.len - 1) cursor += 1;
                try eraseList(writer, config.choices.len);
                try renderMultiSelectList(writer, config.choices, selected, cursor, config.unicode);
            },
            .char => |c| {
                if (c == ' ') {
                    selected[cursor] = !selected[cursor];
                    try eraseList(writer, config.choices.len);
                    try renderMultiSelectList(writer, config.choices, selected, cursor, config.unicode);
                }
            },
            .enter => {
                try eraseList(writer, config.choices.len);
                // Show summary
                var first = true;
                try writer.writeAll("  \x1b[36m");
                for (config.choices, 0..) |choice, i| {
                    if (selected[i]) {
                        if (!first) try writer.writeAll(", ");
                        try writer.writeAll(choice);
                        first = false;
                    }
                }
                try writer.writeAll("\x1b[0m\r\n");

                // Collect selected indices
                var result = std.ArrayList(usize).empty;
                for (0..config.choices.len) |i| {
                    if (selected[i]) try result.append(allocator, i);
                }
                return try result.toOwnedSlice(allocator);
            },
            .ctrl => |c| {
                if (c == 'c') {
                    try eraseList(writer, config.choices.len);
                    return error.UserAborted;
                }
            },
            else => {},
        }
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

fn renderMultiSelectList(writer: anytype, choices: []const []const u8, selected: []const bool, cursor: usize, unicode: bool) !void {
    const sel_sym = terminal.symbols.selected(unicode);
    const unsel_sym = terminal.symbols.unselected(unicode);
    const cursor_sym = terminal.symbols.select_cursor(unicode);
    for (choices, 0..) |choice, i| {
        const marker: []const u8 = if (selected[i]) sel_sym else unsel_sym;
        if (i == cursor) {
            try writer.print("  \x1b[36m{s}\x1b[0m \x1b[32m{s}\x1b[0m {s}\r\n", .{ cursor_sym, marker, choice });
        } else {
            try writer.print("    {s} {s}\r\n", .{ marker, choice });
        }
    }
}

fn eraseList(writer: anytype, count: usize) !void {
    for (0..count) |_| {
        try writer.writeAll("\x1b[A\r\x1b[K");
    }
}

fn collectDefaults(allocator: std.mem.Allocator, config: MultiSelectConfig) ![]usize {
    var result = std.ArrayList(usize).empty;
    if (config.defaults) |d| {
        for (0..@min(d.len, config.choices.len)) |i| {
            if (d[i]) try result.append(allocator, i);
        }
    }
    return try result.toOwnedSlice(allocator);
}

test "MultiSelectConfig defaults" {
    const cfg = MultiSelectConfig{ .message = "Pick:", .choices = &.{ "a", "b" } };
    try std.testing.expect(cfg.defaults == null);
}

test "non-TTY: selects by comma-separated numbers" {
    const allocator = std.testing.allocator;
    var input = "1,3\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try multiSelect(&output_writer, &input_reader, allocator, .{
        .message = "Pick:",
        .choices = &.{ "a", "b", "c" },
    });
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(usize, 0), result[0]); // 1 => index 0
    try std.testing.expectEqual(@as(usize, 2), result[1]); // 3 => index 2
}

test "non-TTY: empty input returns defaults" {
    const allocator = std.testing.allocator;
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try multiSelect(&output_writer, &input_reader, allocator, .{
        .message = "Pick:",
        .choices = &.{ "a", "b", "c" },
        .defaults = &.{ true, false, true },
    });
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(usize, 0), result[0]);
    try std.testing.expectEqual(@as(usize, 2), result[1]);
}

test "non-TTY: no defaults returns empty" {
    const allocator = std.testing.allocator;
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try multiSelect(&output_writer, &input_reader, allocator, .{
        .message = "Pick:",
        .choices = &.{ "a", "b" },
    });
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}
