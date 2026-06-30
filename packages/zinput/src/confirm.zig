//! Yes/no confirmation prompt.

const std = @import("std");
const terminal = @import("terminal");
const zinput = @import("zinput.zig");

pub const ConfirmConfig = struct {
    message: []const u8,
    default: bool = true,
    prefix: []const u8 = "? ",
    /// Keys the prompt should not handle itself: pressing one aborts the prompt
    /// and returns it to the caller as `.{ .key = ... }`. Empty = handle/ignore all.
    interrupt_keys: []const terminal.Key = &.{},
};

/// Prompt for yes/no confirmation. Returns the answer, or an interrupt key.
pub fn confirm(writer: anytype, reader: anytype, config: ConfirmConfig) !zinput.Outcome(bool) {
    const is_tty = terminal.isStdinTty();

    const hint = if (config.default) "(Y/n)" else "(y/N)";
    try writer.print("{s}{s} {s} ", .{ config.prefix, config.message, hint });

    if (!is_tty) {
        const first = terminal.key.readByteFn(reader) catch return .{ .value = config.default };
        // Read rest of line
        while (true) {
            const b = terminal.key.readByteFn(reader) catch break;
            if (b == '\n') break;
        }
        try writer.writeAll("\n");
        return .{ .value = switch (first) {
            'y', 'Y' => true,
            'n', 'N' => false,
            else => config.default,
        } };
    }

    // TTY: single keypress
    zinput.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch return .{ .value = config.default };
    defer {
        raw.disable();
        zinput.flushWriter(writer);
    }

    while (true) {
        zinput.flushWriter(writer);
        const k = if (config.interrupt_keys.len > 0)
            try terminal.readKeyOpt(reader, std.Io.File.stdin().handle)
        else
            try terminal.readKey(reader);
        if (zinput.isInterrupt(k, config.interrupt_keys)) {
            try writer.writeAll("\r\n");
            return .{ .key = k };
        }
        switch (k) {
            .enter => {
                try writer.print("{s}\r\n", .{if (config.default) "yes" else "no"});
                return .{ .value = config.default };
            },
            .char => |c| {
                switch (c) {
                    'y', 'Y' => {
                        try writer.writeAll("yes\r\n");
                        return .{ .value = true };
                    },
                    'n', 'N' => {
                        try writer.writeAll("no\r\n");
                        return .{ .value = false };
                    },
                    else => {},
                }
            },
            .ctrl => |c| {
                if (c == 'c') {
                    try writer.writeAll("\r\n");
                    return error.UserAborted;
                }
            },
            else => {},
        }
    }
}

fn parseYesNo(input: []const u8, default: bool) bool {
    if (input.len == 0) return default;
    return switch (input[0]) {
        'y', 'Y' => true,
        'n', 'N' => false,
        else => default,
    };
}

test "non-TTY: y input returns true" {
    var input = "y\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try confirm(&output_writer, &input_reader, .{
        .message = "Continue?",
        .default = false,
    });
    try std.testing.expect(result.value == true);
}

test "non-TTY: n input returns false" {
    var input = "n\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try confirm(&output_writer, &input_reader, .{
        .message = "Continue?",
        .default = true,
    });
    try std.testing.expect(result.value == false);
}

test "non-TTY: empty input uses default true" {
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try confirm(&output_writer, &input_reader, .{
        .message = "Continue?",
        .default = true,
    });
    try std.testing.expect(result.value == true);
}

test "non-TTY: empty input uses default false" {
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try confirm(&output_writer, &input_reader, .{
        .message = "Continue?",
        .default = false,
    });
    try std.testing.expect(result.value == false);
}

test "non-TTY: EOF uses default" {
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try confirm(&output_writer, &input_reader, .{
        .message = "Continue?",
        .default = true,
    });
    try std.testing.expect(result.value == true);
}

test "prompt shows Y/n when default is true" {
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    _ = try confirm(&output_writer, &input_reader, .{
        .message = "Ok?",
        .default = true,
    });

    const written = output_writer.buffer[0..output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "(Y/n)") != null);
}

test "prompt shows y/N when default is false" {
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    _ = try confirm(&output_writer, &input_reader, .{
        .message = "Ok?",
        .default = false,
    });

    const written = output_writer.buffer[0..output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "(y/N)") != null);
}
