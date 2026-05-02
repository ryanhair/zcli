//! Text input prompt.

const std = @import("std");
const terminal = @import("terminal");
const zinput = @import("zinput.zig");

pub const TextConfig = struct {
    message: []const u8,
    default: ?[]const u8 = null,
    prefix: []const u8 = "? ",
};

/// Prompt for text input. Returns owned string (caller must free with allocator).
pub fn text(writer: anytype, reader: anytype, allocator: std.mem.Allocator, config: TextConfig) ![]u8 {
    const is_tty = terminal.isStdinTty();

    // Render prompt
    try writer.print("{s}{s}", .{ config.prefix, config.message });
    if (config.default) |def| {
        try writer.print(" ({s})", .{def});
    }
    try writer.writeAll(" ");

    if (!is_tty) {
        // Non-TTY: read a line byte by byte
        const line = readLine(reader, allocator) catch {
            return if (config.default) |def|
                try allocator.dupe(u8, def)
            else
                try allocator.dupe(u8, "");
        };
        defer allocator.free(line);
        if (line.len == 0) {
            if (config.default) |def| return try allocator.dupe(u8, def);
        }
        try writer.writeAll("\n");
        return try allocator.dupe(u8, line);
    }

    // TTY: raw mode character-by-character input
    zinput.flushWriter(writer);
    const raw = terminal.enableRawMode(std.fs.File.stdin().handle) catch {
        // Fallback if raw mode fails
        try writer.writeAll("\n");
        return try allocator.dupe(u8, config.default orelse "");
    };
    defer {
        raw.disable();
        zinput.flushWriter(writer);
    }

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    while (true) {
        const k = try terminal.readKey(reader);
        switch (k) {
            .enter => {
                try writer.writeAll("\r\n");
                if (buf.items.len == 0) {
                    if (config.default) |def| return try allocator.dupe(u8, def);
                }
                return try allocator.dupe(u8, buf.items);
            },
            .backspace => {
                if (buf.items.len > 0) {
                    _ = buf.pop();
                    try writer.writeAll("\x08 \x08"); // move back, erase, move back
                }
            },
            .ctrl => |c| {
                if (c == 'c') {
                    try writer.writeAll("\r\n");
                    return error.UserAborted;
                }
            },
            .char => |c| {
                try buf.append(allocator, c);
                try writer.print("{c}", .{c});
            },
            else => {},
        }
    }
}

/// Read a line from a reader byte by byte until newline.
fn readLine(reader: anytype, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    while (true) {
        const byte = terminal.key.readByteFn(reader) catch return try buf.toOwnedSlice(allocator);
        if (byte == '\n') break;
        if (byte != '\r') try buf.append(allocator, byte);
    }
    return try buf.toOwnedSlice(allocator);
}

test "TextConfig defaults" {
    const cfg = TextConfig{ .message = "Name:" };
    try std.testing.expectEqualStrings("Name:", cfg.message);
    try std.testing.expect(cfg.default == null);
}

test "text: non-TTY reads user input" {
    const allocator = std.testing.allocator;
    var input = "hello world\n".*;
    var reader_stream = std.io.fixedBufferStream(&input);
    var output: [256]u8 = undefined;
    var writer_stream = std.io.fixedBufferStream(&output);

    const result = try text(writer_stream.writer(), reader_stream.reader(), allocator, .{
        .message = "Name:",
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello world", result);
}

test "text: non-TTY uses default on empty input" {
    const allocator = std.testing.allocator;
    var input = "\n".*;
    var reader_stream = std.io.fixedBufferStream(&input);
    var output: [256]u8 = undefined;
    var writer_stream = std.io.fixedBufferStream(&output);

    const result = try text(writer_stream.writer(), reader_stream.reader(), allocator, .{
        .message = "Name:",
        .default = "world",
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("world", result);
}

test "text: non-TTY uses default on EOF" {
    const allocator = std.testing.allocator;
    var input = "".*;
    var reader_stream = std.io.fixedBufferStream(&input);
    var output: [256]u8 = undefined;
    var writer_stream = std.io.fixedBufferStream(&output);

    const result = try text(writer_stream.writer(), reader_stream.reader(), allocator, .{
        .message = "Name:",
        .default = "fallback",
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("fallback", result);
}

test "text: prompt message appears in output" {
    const allocator = std.testing.allocator;
    var input = "test\n".*;
    var reader_stream = std.io.fixedBufferStream(&input);
    var output: [256]u8 = undefined;
    var writer_stream = std.io.fixedBufferStream(&output);

    const result = try text(writer_stream.writer(), reader_stream.reader(), allocator, .{
        .message = "Enter name:",
        .default = "foo",
    });
    defer allocator.free(result);

    const written = writer_stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "Enter name:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "(foo)") != null);
}
