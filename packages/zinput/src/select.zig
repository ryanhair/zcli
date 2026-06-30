//! Single selection prompt with arrow key navigation.

const std = @import("std");
const terminal = @import("terminal");
const zinput = @import("zinput.zig");

pub const SelectConfig = struct {
    message: []const u8,
    choices: []const []const u8,
    prefix: []const u8 = "? ",
    unicode: bool = true,
    /// Keys the prompt should not handle itself: pressing one aborts the prompt
    /// and returns it to the caller as `.{ .key = ... }`. Empty = handle/ignore all.
    interrupt_keys: []const terminal.Key = &.{},
};

/// Prompt to select one item from a list. Returns the chosen index, or an interrupt key.
pub fn select(writer: anytype, reader: anytype, config: SelectConfig) !zinput.Outcome(usize) {
    if (config.choices.len == 0) return error.NoChoices;
    const is_tty = terminal.isStdinTty();

    try writer.print("{s}{s}\r\n", .{ config.prefix, config.message });

    if (!is_tty) {
        // Non-TTY: numbered list
        for (config.choices, 1..) |choice, i| {
            try writer.print("  {d}) {s}\n", .{ i, choice });
        }
        try writer.writeAll("> ");
        const line = readLine(reader, std.heap.page_allocator) catch return .{ .value = 0 };
        defer std.heap.page_allocator.free(line);
        const num = std.fmt.parseInt(usize, line, 10) catch return .{ .value = 0 };
        if (num >= 1 and num <= config.choices.len) return .{ .value = num - 1 };
        return .{ .value = 0 };
    }

    // TTY: interactive selection
    zinput.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch return .{ .value = 0 };
    try writer.writeAll(terminal.ansi.hide_cursor);
    defer {
        writer.writeAll(terminal.ansi.show_cursor) catch {};
        raw.disable();
        zinput.flushWriter(writer);
    }

    var cursor: usize = 0;

    // Initial render
    try renderSelectList(writer, config.choices, cursor, config.unicode);

    while (true) {
        zinput.flushWriter(writer);
        const k = if (config.interrupt_keys.len > 0)
            try terminal.readKeyOpt(reader, std.Io.File.stdin().handle)
        else
            try terminal.readKey(reader);
        if (zinput.isInterrupt(k, config.interrupt_keys)) {
            try eraseList(writer, config.choices.len);
            try writer.writeAll("\x1b[A\r\x1b[K"); // also clear the prompt line
            return .{ .key = k };
        }
        switch (k) {
            .up => {
                if (cursor > 0) cursor -= 1;
                try eraseList(writer, config.choices.len);
                try renderSelectList(writer, config.choices, cursor, config.unicode);
            },
            .down => {
                if (cursor < config.choices.len - 1) cursor += 1;
                try eraseList(writer, config.choices.len);
                try renderSelectList(writer, config.choices, cursor, config.unicode);
            },
            .enter => {
                try eraseList(writer, config.choices.len);
                try writer.print("  \x1b[36m{s}\x1b[0m\r\n", .{config.choices[cursor]});
                return .{ .value = cursor };
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

fn renderSelectList(writer: anytype, choices: []const []const u8, cursor: usize, unicode: bool) !void {
    const marker = terminal.symbols.select_cursor(unicode);
    for (choices, 0..) |choice, i| {
        if (i == cursor) {
            try writer.print("  \x1b[36m{s} {s}\x1b[0m\r\n", .{ marker, choice });
        } else {
            try writer.print("    {s}\r\n", .{choice});
        }
    }
}

fn eraseList(writer: anytype, count: usize) !void {
    // Move cursor up `count` lines and clear each
    for (0..count) |_| {
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

    try std.testing.expectEqual(@as(usize, 1), result.value); // 2 => index 1
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

    try std.testing.expectEqual(@as(usize, 0), result.value);
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
