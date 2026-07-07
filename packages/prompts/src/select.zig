//! Single selection prompt with arrow key navigation.

const std = @import("std");
const terminal = @import("terminal");
const prompts = @import("prompts.zig");
const lr = @import("list_render.zig");

pub const SelectConfig = struct {
    message: []const u8,
    choices: []const []const u8,
    prefix: []const u8 = "? ",
    unicode: bool = true,
    /// Keys the prompt should not handle itself: pressing one aborts the prompt
    /// with `error.Interrupted`. Empty = handle/ignore all keys.
    interrupt_keys: []const terminal.Key = &.{},
};

/// Prompt to select one item from a list. Returns the chosen index, or
/// `error.Interrupted` if the user presses one of `config.interrupt_keys`.
pub fn select(writer: anytype, reader: anytype, config: SelectConfig) !usize {
    if (config.choices.len == 0) return error.NoChoices;
    const is_tty = terminal.isStdinTty();

    if (!is_tty) {
        // Non-TTY: numbered list
        try writer.print("{s}{s}\r\n", .{ config.prefix, config.message });
        for (config.choices, 1..) |choice, i| {
            try writer.print("  {d}) {s}\n", .{ i, choice });
        }
        try writer.writeAll("> ");
        const line = readLine(reader, std.heap.page_allocator) catch return 0;
        defer std.heap.page_allocator.free(line);
        const num = std.fmt.parseInt(usize, line, 10) catch return 0;
        if (num >= 1 and num <= config.choices.len) return num - 1;
        return 0;
    }

    // TTY: interactive selection
    prompts.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch return 0;
    try writer.writeAll(terminal.ansi.hide_cursor);
    var watcher = terminal.ResizeWatcher.init();
    defer {
        writer.writeAll(terminal.ansi.show_cursor) catch {};
        watcher.deinit();
        raw.disable();
        prompts.flushWriter(writer);
    }

    const stdin = std.Io.File.stdin().handle;
    var cursor: usize = 0;
    var rows = try renderList(writer, config, cursor, lr.windowSize());

    while (true) {
        prompts.flushWriter(writer);
        switch (try terminal.readEvent(reader, stdin, &watcher)) {
            .resize => {
                try lr.eraseRegion(writer, rows);
                rows = try renderList(writer, config, cursor, lr.windowSize());
            },
            .key => |k| {
                if (prompts.isInterrupt(k, config.interrupt_keys)) {
                    try lr.eraseRegion(writer, rows);
                    return error.Interrupted;
                }
                switch (k) {
                    .up => {
                        if (cursor > 0) cursor -= 1;
                        try lr.eraseRegion(writer, rows);
                        rows = try renderList(writer, config, cursor, lr.windowSize());
                    },
                    .down => {
                        if (cursor < config.choices.len - 1) cursor += 1;
                        try lr.eraseRegion(writer, rows);
                        rows = try renderList(writer, config, cursor, lr.windowSize());
                    },
                    .enter => {
                        try lr.eraseRegion(writer, rows);
                        try writer.print("  \x1b[36m{s}\x1b[0m\r\n", .{config.choices[cursor]});
                        return cursor;
                    },
                    .ctrl => |c| {
                        if (c == 'c') {
                            try lr.eraseRegion(writer, rows);
                            return error.UserAborted;
                        }
                    },
                    else => {},
                }
            },
        }
    }
}

/// Render the header + viewport-limited choice list, returning physical rows
/// emitted. Width is an explicit parameter so this is deterministic/testable
/// (used by the cross-platform emulator render tests).
pub fn renderList(writer: anytype, config: SelectConfig, cursor: usize, ws: terminal.Winsize) !usize {
    const width = @max(@as(usize, ws.col), 1);
    const usable = @max(width -| 1, 1);
    const height = @max(@as(usize, ws.row), 2);

    const cursor_sym = terminal.symbols.select_cursor(config.unicode);
    // "  <cur> " and "    " are both 4 columns (single-column cursor glyph).
    const prefix_w: usize = 4;
    const avail = @max(usable -| prefix_w, 1);

    var rows: usize = 0;
    var first_line = true;

    const hprefix_w = terminal.displayWidth(config.prefix);
    rows += try lr.renderItem(writer, &first_line, .{ .first_prefix = config.prefix, .prefix_w = hprefix_w }, config.message, @max(usable -| hprefix_w, 1));

    const Counter = struct {
        choices: []const []const u8,
        avail: usize,
        fn at(self: *const @This(), i: usize) usize {
            return terminal.wrapCount(self.choices[i], self.avail);
        }
    };
    const counter = Counter{ .choices = config.choices, .avail = avail };
    const list_budget = @max((height -| 1) -| rows, 1);
    const win = lr.viewport(config.choices.len, cursor, list_budget, &counter, Counter.at);

    for (win.start..win.end) |i| {
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
        rows += try lr.renderItem(writer, &first_line, style, config.choices[i], avail);
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

pub const SelectError = error{NoChoices};

test "SelectConfig" {
    const cfg = SelectConfig{ .message = "Pick:", .choices = &.{ "a", "b" } };
    try std.testing.expectEqualStrings("Pick:", cfg.message);
    try std.testing.expect(cfg.choices.len == 2);
}

test "non-TTY: selects by number" {
    var input = "2\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try select(&output_writer, &input_reader, .{
        .message = "Pick:",
        .choices = &.{ "alpha", "beta", "gamma" },
    });

    try std.testing.expectEqual(@as(usize, 1), result); // 2 => index 1
}

test "non-TTY: invalid number returns 0" {
    var input = "999\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try select(&output_writer, &input_reader, .{
        .message = "Pick:",
        .choices = &.{ "a", "b" },
    });

    try std.testing.expectEqual(@as(usize, 0), result);
}

test "non-TTY: shows numbered choices" {
    var input = "1\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [1024]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    _ = try select(&output_writer, &input_reader, .{
        .message = "Pick:",
        .choices = &.{ "first", "second" },
    });

    const written = output_writer.buffer[0..output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "second") != null);
}

fn renderToBuf(buf: []u8, config: SelectConfig, cursor: usize, ws: terminal.Winsize) !struct { rows: usize, text: []const u8 } {
    var w: std.Io.Writer = .fixed(buf);
    const rows = try renderList(&w, config, cursor, ws);
    return .{ .rows = rows, .text = w.buffered() };
}

test "renderList: short options are one row each" {
    var buf: [1024]u8 = undefined;
    const r = try renderToBuf(&buf, .{ .message = "Pick", .choices = &.{ "a", "b", "c" } }, 0, .{ .row = 24, .col = 80 });
    try std.testing.expectEqual(@as(usize, 4), r.rows); // header + 3
}

test "renderList: wrapped option reports true physical row count" {
    var buf: [4096]u8 = undefined;
    const long = "this is a long option label that will certainly wrap at a narrow width";
    const r = try renderToBuf(&buf, .{ .message = "Pick", .choices = &.{ "short", long } }, 0, .{ .row = 24, .col = 24 });
    try std.testing.expect(r.rows > 3);
    const lines = std.mem.count(u8, r.text, "\r\n") + 1;
    try std.testing.expectEqual(lines, r.rows);
}
