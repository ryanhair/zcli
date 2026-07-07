//! Text input prompt.

const std = @import("std");
const terminal = @import("terminal");
const prompts = @import("prompts.zig");

/// Optional live preview rendered on the line *above* the prompt, repainted on
/// every keystroke. `render` receives the current input and writes one line of
/// content (no trailing newline); it owns its own styling. Only active on a TTY.
pub const Preview = struct {
    context: *anyopaque,
    render: *const fn (context: *anyopaque, input: []const u8, writer: *std.Io.Writer) anyerror!void,
};

pub const TextConfig = struct {
    message: []const u8,
    default: ?[]const u8 = null,
    prefix: []const u8 = "? ",
    preview: ?Preview = null,
    /// Keys the prompt should not handle itself: pressing one aborts the prompt
    /// with `error.Interrupted`. Empty = handle/ignore all keys.
    interrupt_keys: []const terminal.Key = &.{},
};

/// Prompt for text input. Returns an owned string (caller frees), or
/// `error.Interrupted` if the user presses one of `config.interrupt_keys`.
pub fn text(writer: anytype, reader: anytype, allocator: std.mem.Allocator, config: TextConfig) ![]u8 {
    const is_tty = terminal.isStdinTty();
    const use_preview = is_tty and config.preview != null;

    // With a live preview, the preview line sits directly above the prompt.
    if (use_preview) try renderPreviewLine(writer, config.preview.?, "");

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
    prompts.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch {
        // Fallback if raw mode fails
        try writer.writeAll("\n");
        return try allocator.dupe(u8, config.default orelse "");
    };
    defer {
        raw.disable();
        prompts.flushWriter(writer);
    }

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    while (true) {
        prompts.flushWriter(writer);
        const k = if (config.interrupt_keys.len > 0)
            try terminal.readKeyOpt(reader, std.Io.File.stdin().handle)
        else
            try terminal.readKey(reader);
        if (prompts.isInterrupt(k, config.interrupt_keys)) {
            try writer.writeAll("\r\n");
            return error.Interrupted;
        }
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
                    try prompts.eraseTrailingGrapheme(writer, &buf);
                    if (use_preview) try repaintPreview(writer, config.preview.?, buf.items);
                }
            },
            .ctrl => |c| {
                if (c == 'c') {
                    try writer.writeAll("\r\n");
                    return error.UserAborted;
                }
            },
            .char => |c| {
                try writer.writeAll(try prompts.appendCodepoint(allocator, &buf, c));
                if (use_preview) try repaintPreview(writer, config.preview.?, buf.items);
            },
            else => {},
        }
    }
}

/// Render the preview content followed by a newline (used for the initial line).
fn renderPreviewLine(writer: *std.Io.Writer, preview: Preview, input: []const u8) !void {
    try preview.render(preview.context, input, writer);
    try writer.writeAll("\r\n");
}

/// Repaint the preview line above the cursor without disturbing the input line:
/// save cursor, move up one line, clear it, re-render, restore cursor.
fn repaintPreview(writer: *std.Io.Writer, preview: Preview, input: []const u8) !void {
    try writer.writeAll("\x1b7"); // DEC save cursor
    try writer.writeAll("\x1b[1A\r\x1b[2K"); // up one line, carriage return, clear line
    try preview.render(preview.context, input, writer);
    try writer.writeAll("\x1b8"); // DEC restore cursor
}

/// Read a line from a reader byte by byte until newline.
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

test "TextConfig defaults" {
    const cfg = TextConfig{ .message = "Name:" };
    try std.testing.expectEqualStrings("Name:", cfg.message);
    try std.testing.expect(cfg.default == null);
}

test "text: non-TTY reads user input" {
    const allocator = std.testing.allocator;
    var input = "hello world\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try text(&output_writer, &input_reader, allocator, .{
        .message = "Name:",
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello world", result);
}

test "text: non-TTY uses default on empty input" {
    const allocator = std.testing.allocator;
    var input = "\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try text(&output_writer, &input_reader, allocator, .{
        .message = "Name:",
        .default = "world",
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("world", result);
}

test "text: non-TTY uses default on EOF" {
    const allocator = std.testing.allocator;
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try text(&output_writer, &input_reader, allocator, .{
        .message = "Name:",
        .default = "fallback",
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("fallback", result);
}

test "text: prompt message appears in output" {
    const allocator = std.testing.allocator;
    var input = "test\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try text(&output_writer, &input_reader, allocator, .{
        .message = "Enter name:",
        .default = "foo",
    });
    defer allocator.free(result);

    const written = output_writer.buffer[0..output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "Enter name:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "(foo)") != null);
}
