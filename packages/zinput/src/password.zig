//! Masked password input prompt.

const std = @import("std");
const terminal = @import("terminal");
const zinput = @import("zinput.zig");

pub const PasswordConfig = struct {
    message: []const u8,
    mask: u8 = '*',
    prefix: []const u8 = "? ",
};

/// Prompt for password input with masking. Returns owned string.
pub fn password(writer: anytype, reader: anytype, allocator: std.mem.Allocator, config: PasswordConfig) ![]u8 {
    const is_tty = terminal.isStdinTty();

    try writer.print("{s}{s} ", .{ config.prefix, config.message });

    if (!is_tty) {
        // Non-TTY: read line (no masking possible)
        const line = readLine(reader, allocator) catch return try allocator.dupe(u8, "");
        try writer.writeAll("\n");
        return line;
    }

    // TTY: raw mode with mask character
    zinput.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch {
        try writer.writeAll("\n");
        return try allocator.dupe(u8, "");
    };
    defer {
        raw.disable();
        zinput.flushWriter(writer);
    }

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    while (true) {
        const k = try terminal.readKey(reader);
        switch (k) {
            .enter => {
                try writer.writeAll("\r\n");
                return try allocator.dupe(u8, buf.items);
            },
            .backspace => {
                if (buf.items.len > 0) {
                    _ = buf.pop();
                    try renderMask(writer, config, buf.items.len);
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
                try renderMask(writer, config, buf.items.len);
            },
            else => {},
        }
    }
}

fn renderMask(writer: anytype, config: PasswordConfig, len: usize) !void {
    // Clear line and redraw prompt + mask, then flush to ensure atomic render
    try writer.writeAll("\r\x1b[K");
    try writer.print("{s}{s} ", .{ config.prefix, config.message });
    for (0..len) |_| {
        try writer.print("{c}", .{config.mask});
    }
    zinput.flushWriter(writer);
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

test "PasswordConfig defaults" {
    const cfg = PasswordConfig{ .message = "Password:" };
    try std.testing.expect(cfg.mask == '*');
}

test "non-TTY: reads password line" {
    const allocator = std.testing.allocator;
    var input = "secret123\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try password(&output_writer, &input_reader, allocator, .{
        .message = "Password:",
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("secret123", result);
}

test "non-TTY: EOF returns empty" {
    const allocator = std.testing.allocator;
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try password(&output_writer, &input_reader, allocator, .{
        .message = "Password:",
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "prompt shows message" {
    const allocator = std.testing.allocator;
    var input = "pw\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try password(&output_writer, &input_reader, allocator, .{
        .message = "Enter secret:",
    });
    defer allocator.free(result);

    const written = output_writer.buffer[0..output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "Enter secret:") != null);
}
