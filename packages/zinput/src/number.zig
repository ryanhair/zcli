//! Numeric input prompt with optional range validation.

const std = @import("std");
const terminal = @import("terminal");
const zinput = @import("zinput.zig");

pub const NumberConfig = struct {
    message: []const u8,
    default: ?i64 = null,
    min: ?i64 = null,
    max: ?i64 = null,
    prefix: []const u8 = "? ",
};

/// Prompt for numeric input. Returns i64.
pub fn number(writer: anytype, reader: anytype, config: NumberConfig) !i64 {
    const is_tty = terminal.isStdinTty();

    while (true) {
        // Render prompt
        try writer.print("{s}{s}", .{ config.prefix, config.message });
        if (config.default) |def| {
            try writer.print(" ({d})", .{def});
        }
        try writer.writeAll(" ");

        const value = if (!is_tty)
            try readNumberNonTty(reader, config)
        else
            try readNumberTty(writer, reader, config);

        // Validate range
        if (config.min) |min| {
            if (value < min) {
                try writer.print("\r\n  Minimum value is {d}\r\n", .{min});
                continue;
            }
        }
        if (config.max) |max| {
            if (value > max) {
                try writer.print("\r\n  Maximum value is {d}\r\n", .{max});
                continue;
            }
        }

        try writer.writeAll("\r\n");
        return value;
    }
}

fn readNumberNonTty(reader: anytype, config: NumberConfig) !i64 {
    var buf: [32]u8 = undefined;
    const line = readLine(reader, &buf);
    if (line.len == 0) {
        return config.default orelse error.InvalidNumber;
    }
    return std.fmt.parseInt(i64, line, 10) catch error.InvalidNumber;
}

fn readNumberTty(writer: anytype, reader: anytype, config: NumberConfig) !i64 {
    zinput.flushWriter(writer);
    const raw = terminal.enableRawMode(std.fs.File.stdin().handle) catch {
        return config.default orelse error.InvalidNumber;
    };
    defer {
        raw.disable();
        zinput.flushWriter(writer);
    }

    var buf: [32]u8 = undefined;
    var len: usize = 0;

    while (true) {
        const k = try terminal.readKey(reader);
        switch (k) {
            .enter => {
                if (len == 0) {
                    if (config.default) |def| return def;
                    // No input and no default — beep and continue
                    continue;
                }
                return std.fmt.parseInt(i64, buf[0..len], 10) catch {
                    // Shouldn't happen since we only accept digits
                    continue;
                };
            },
            .backspace => {
                if (len > 0) {
                    len -= 1;
                    try writer.writeAll("\x08 \x08");
                }
            },
            .ctrl => |c| {
                if (c == 'c') {
                    try writer.writeAll("\r\n");
                    return error.UserAborted;
                }
            },
            .char => |c| {
                // Accept digits and leading minus
                if (c >= '0' and c <= '9') {
                    if (len < buf.len) {
                        buf[len] = c;
                        len += 1;
                        try writer.print("{c}", .{c});
                    }
                } else if (c == '-' and len == 0) {
                    buf[len] = c;
                    len += 1;
                    try writer.print("{c}", .{c});
                }
                // Silently ignore other characters
            },
            else => {},
        }
    }
}

/// Read a line (sans trailing newline) into the caller-owned `buf`, returning
/// the filled slice. The slice borrows `buf`, so it stays valid as long as the
/// caller's buffer does — never return a slice into a local buffer from here.
/// Stops at '\n', on read error/EOF, or when `buf` is full.
fn readLine(reader: anytype, buf: []u8) []const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        const byte = terminal.key.readByteFn(reader) catch break;
        if (byte == '\n') break;
        if (byte != '\r') {
            buf[len] = byte;
            len += 1;
        }
    }
    return buf[0..len];
}

pub const NumberError = error{InvalidNumber};

test "NumberConfig defaults" {
    const cfg = NumberConfig{ .message = "Port:" };
    try std.testing.expect(cfg.default == null);
    try std.testing.expect(cfg.min == null);
    try std.testing.expect(cfg.max == null);
}

test "non-TTY: parses a typed number" {
    var input = "42\n".*;
    var reader_stream = std.io.fixedBufferStream(&input);
    var output: [256]u8 = undefined;
    var writer_stream = std.io.fixedBufferStream(&output);

    const result = try number(writer_stream.writer(), reader_stream.reader(), .{
        .message = "Count:",
    });
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "non-TTY: multi-digit value survives the readLine buffer boundary" {
    // Regression: readLine used to return a slice into its own stack frame, so
    // the digits could be clobbered before parseInt ran. A longer value makes
    // that corruption observable if it ever returns.
    var input = "1234567\n".*;
    var reader_stream = std.io.fixedBufferStream(&input);
    var output: [256]u8 = undefined;
    var writer_stream = std.io.fixedBufferStream(&output);

    const result = try number(writer_stream.writer(), reader_stream.reader(), .{
        .message = "Value:",
    });
    try std.testing.expectEqual(@as(i64, 1234567), result);
}

test "non-TTY: empty input falls back to the default" {
    var input = "\n".*;
    var reader_stream = std.io.fixedBufferStream(&input);
    var output: [256]u8 = undefined;
    var writer_stream = std.io.fixedBufferStream(&output);

    const result = try number(writer_stream.writer(), reader_stream.reader(), .{
        .message = "Port:",
        .default = 3000,
    });
    try std.testing.expectEqual(@as(i64, 3000), result);
}

test "non-TTY: empty input with no default errors" {
    var input = "\n".*;
    var reader_stream = std.io.fixedBufferStream(&input);
    var output: [256]u8 = undefined;
    var writer_stream = std.io.fixedBufferStream(&output);

    try std.testing.expectError(error.InvalidNumber, number(writer_stream.writer(), reader_stream.reader(), .{
        .message = "Port:",
    }));
}

test "non-TTY: non-numeric input errors" {
    var input = "abc\n".*;
    var reader_stream = std.io.fixedBufferStream(&input);
    var output: [256]u8 = undefined;
    var writer_stream = std.io.fixedBufferStream(&output);

    try std.testing.expectError(error.InvalidNumber, number(writer_stream.writer(), reader_stream.reader(), .{
        .message = "Count:",
    }));
}
