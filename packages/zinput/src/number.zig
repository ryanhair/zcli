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
    const line = readLine(reader) catch {
        return config.default orelse error.InvalidNumber;
    };
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

fn readLine(reader: anytype) ![]const u8 {
    var buf: [32]u8 = undefined;
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
