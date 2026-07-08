//! Yes/no confirmation prompt.
//!
//! The TTY path renders on the ui engine; the answered line persists as
//! static output ("? Continue? (Y/n) yes").

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const lr = @import("list_render.zig");
const ui = lr.ui;

pub const ConfirmConfig = struct {
    message: []const u8,
    default: bool = true,
    prefix: []const u8 = "? ",
    /// Keys the prompt should not handle itself: pressing one aborts the prompt
    /// with `error.Interrupted`. Empty = handle/ignore all keys.
    interrupt_keys: []const terminal.Key = &.{},
};

/// Prompt for yes/no confirmation. Returns the answer, or `error.Interrupted`
/// if the user presses one of `config.interrupt_keys`.
pub fn confirm(p: Prompts, config: ConfirmConfig) !bool {
    const writer = p.writer;
    const reader = p.reader;
    const is_tty = terminal.isStdinTty();

    const hint = if (config.default) "(Y/n)" else "(y/N)";

    if (!is_tty) {
        try writer.print("{s}{s} {s} ", .{ config.prefix, config.message, hint });
        const first = terminal.key.readByteFn(reader) catch return config.default;
        // Read rest of line
        while (true) {
            const b = terminal.key.readByteFn(reader) catch break;
            if (b == '\n') break;
        }
        try writer.writeAll("\n");
        return switch (first) {
            'y', 'Y' => true,
            'n', 'N' => false,
            else => config.default,
        };
    }

    // TTY: single keypress
    Prompts.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch return config.default;
    defer {
        raw.disable();
        Prompts.flushWriter(writer);
    }
    var app = try ui.App.init(p.allocator, writer, .{
        .capability = p.theme.capability(),
    });
    defer app.deinit();

    try renderFrame(&app, config, hint);

    while (true) {
        const k = if (config.interrupt_keys.len > 0)
            try terminal.readKeyOpt(reader, std.Io.File.stdin().handle)
        else
            try terminal.readKey(reader);
        if (Prompts.isInterrupt(k, config.interrupt_keys)) {
            try persist(&app, config, hint, null);
            return error.Interrupted;
        }
        switch (k) {
            .enter => {
                try persist(&app, config, hint, if (config.default) "yes" else "no");
                return config.default;
            },
            .char => |c| {
                switch (c) {
                    'y', 'Y' => {
                        try persist(&app, config, hint, "yes");
                        return true;
                    },
                    'n', 'N' => {
                        try persist(&app, config, hint, "no");
                        return false;
                    },
                    else => {},
                }
            },
            .ctrl => |c| {
                if (c == 'c') {
                    try persist(&app, config, hint, null);
                    return error.UserAborted;
                }
            },
            else => {},
        }
    }
}

fn renderFrame(app: *ui.App, config: ConfirmConfig, hint: []const u8) !void {
    const a = app.arena();
    const ws = lr.windowSize();
    const usable: u16 = @intCast(@min(@max(@as(usize, ws.col) -| 1, 1), std.math.maxInt(u16)));
    const line = try std.fmt.allocPrint(a, "{s}{s} {s} ", .{ config.prefix, config.message, hint });
    try app.frame(try ui.column(a, .{ .width = .{ .len = usable } }, &.{
        ui.text(.{}, line),
    }));
    const pos = Prompts.endPosition(line, usable);
    try app.showCursorAt(pos.x, pos.y);
}

/// Erase the live prompt and persist "? message (Y/n) answer" statically.
fn persist(app: *ui.App, config: ConfirmConfig, hint: []const u8, answer: ?[]const u8) !void {
    try app.clear();
    try app.emit("{s}{s} {s} {s}", .{ config.prefix, config.message, hint, answer orelse "" });
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

    const result = try confirm(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Continue?",
        .default = false,
    });
    try std.testing.expect(result == true);
}

test "non-TTY: n input returns false" {
    var input = "n\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try confirm(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Continue?",
        .default = true,
    });
    try std.testing.expect(result == false);
}

test "non-TTY: empty input uses default true" {
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try confirm(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Continue?",
        .default = true,
    });
    try std.testing.expect(result == true);
}

test "non-TTY: empty input uses default false" {
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try confirm(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Continue?",
        .default = false,
    });
    try std.testing.expect(result == false);
}

test "non-TTY: EOF uses default" {
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try confirm(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Continue?",
        .default = true,
    });
    try std.testing.expect(result == true);
}

test "prompt shows Y/n when default is true" {
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    _ = try confirm(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
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

    _ = try confirm(.{ .writer = &output_writer, .reader = &input_reader, .allocator = std.testing.allocator }, .{
        .message = "Ok?",
        .default = false,
    });

    const written = output_writer.buffer[0..output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "(y/N)") != null);
}
