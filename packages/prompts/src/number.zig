//! Numeric input prompt with optional range validation.
//!
//! The TTY path renders on the ui engine: the prompt line is a frame with the
//! real cursor at the insertion point, and a range-validation message appears
//! as a second row inside the frame (replacing the old scroll-away error
//! lines). The accepted value persists as a static line.

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const lr = @import("list_render.zig");
const ui = lr.ui;

pub const NumberConfig = struct {
    message: []const u8,
    default: ?i64 = null,
    min: ?i64 = null,
    max: ?i64 = null,
    prefix: []const u8 = "? ",
    /// Keys the prompt should not handle itself: pressing one aborts the prompt
    /// with `error.Interrupted`. Empty = handle/ignore all keys.
    interrupt_keys: []const terminal.Key = &.{},
};

/// Prompt for numeric input. Returns the entered number, `error.Interrupted`
/// if the user presses one of `config.interrupt_keys`, `error.UserAborted` if
/// the user presses Ctrl-C, or `error.EndOfStream` if stdin closes with no line
/// to submit.
pub fn number(p: Prompts, config: NumberConfig) !i64 {
    const writer = p.writer;
    const reader = p.reader;
    const is_tty = terminal.isInteractiveTty();

    if (is_tty) return numberTty(p, config);

    while (true) {
        // Render prompt
        try writer.print("{s}{s}", .{ config.prefix, config.message });
        if (config.default) |def| {
            try writer.print(" ({d})", .{def});
        }
        try writer.writeAll(" ");

        // Flush so the prompt is visible before we block reading the reply —
        // buffered writers otherwise strand it until after input arrives.
        Prompts.flushWriter(writer);
        const value = try readNumberNonTty(reader, config);

        // Validate range
        if (config.min) |min| {
            if (value < min) {
                try writer.print("\n  Minimum value is {d}\n", .{min});
                continue;
            }
        }
        if (config.max) |max| {
            if (value > max) {
                try writer.print("\n  Maximum value is {d}\n", .{max});
                continue;
            }
        }

        try writer.writeAll("\n");
        return value;
    }
}

fn numberTty(p: Prompts, config: NumberConfig) !i64 {
    const writer = p.writer;
    const reader = p.reader;

    Prompts.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch {
        return config.default orelse error.InvalidNumber;
    };
    defer {
        raw.disable();
        Prompts.flushWriter(writer);
    }
    var app = try ui.App.init(p.allocator, writer, .{
        .capability = p.theme.capability(),
        .hybrid_raw = raw,
    });
    defer app.deinit();

    var buf: [32]u8 = undefined;
    var len: usize = 0;
    var error_msg: ?[]const u8 = null;
    var error_buf: [48]u8 = undefined;

    try renderFrame(&app, config, buf[0..len], error_msg);

    while (true) {
        const k = if (config.interrupt_keys.len > 0)
            try terminal.readKeyOpt(reader, std.Io.File.stdin().handle)
        else
            try terminal.readKey(reader);
        if (Prompts.isInterrupt(k, config.interrupt_keys)) {
            try persistLine(&app, config, buf[0..len]);
            return error.Interrupted;
        }
        switch (k) {
            .enter => {
                const value = if (len == 0)
                    config.default orelse continue
                else
                    std.fmt.parseInt(i64, buf[0..len], 10) catch continue;

                if (config.min) |min| {
                    if (value < min) {
                        error_msg = std.fmt.bufPrint(&error_buf, "minimum value is {d}", .{min}) catch "out of range";
                        try renderFrame(&app, config, buf[0..len], error_msg);
                        continue;
                    }
                }
                if (config.max) |max| {
                    if (value > max) {
                        error_msg = std.fmt.bufPrint(&error_buf, "maximum value is {d}", .{max}) catch "out of range";
                        try renderFrame(&app, config, buf[0..len], error_msg);
                        continue;
                    }
                }
                try persistLine(&app, config, buf[0..len]);
                return value;
            },
            .backspace => {
                if (len > 0) {
                    len -= 1;
                    error_msg = null;
                    try renderFrame(&app, config, buf[0..len], error_msg);
                }
            },
            .ctrl => |c| {
                if (c == 'c') {
                    try persistLine(&app, config, buf[0..len]);
                    return error.UserAborted;
                }
            },
            .char => |c| {
                // Accept digits and leading minus (all ASCII, so the u8 casts hold)
                if ((c >= '0' and c <= '9' and len < buf.len) or (c == '-' and len == 0)) {
                    buf[len] = @intCast(c);
                    len += 1;
                    error_msg = null;
                    try renderFrame(&app, config, buf[0..len], error_msg);
                }
                // Silently ignore other characters
            },
            else => {},
        }
    }
}

/// The prompt line as one string: "? message (default) input".
fn composeLine(a: std.mem.Allocator, config: NumberConfig, input: []const u8) ![]const u8 {
    return if (config.default) |def|
        std.fmt.allocPrint(a, "{s}{s} ({d}) {s}", .{ config.prefix, config.message, def, input })
    else
        std.fmt.allocPrint(a, "{s}{s} {s}", .{ config.prefix, config.message, input });
}

fn renderFrame(app: *ui.App, config: NumberConfig, input: []const u8, error_msg: ?[]const u8) !void {
    const a = app.arena();
    const ws = lr.windowSize();
    const usable: u16 = @intCast(@min(@max(@as(usize, ws.col) -| 1, 1), std.math.maxInt(u16)));

    var rows = std.ArrayList(ui.Node).empty;
    try rows.append(a, ui.text(.{}, try composeLine(a, config, input)));
    if (error_msg) |msg| {
        try rows.append(a, ui.text(.{}, try std.fmt.allocPrint(a, "  {s}", .{msg})));
    }
    try app.frame(try ui.column(a, .{ .width = .{ .len = usable } }, rows.items));

    const pos = Prompts.endPosition(try composeLine(app.arena(), config, input), usable);
    try app.showCursorAt(pos.x, pos.y);
}

fn persistLine(app: *ui.App, config: NumberConfig, input: []const u8) !void {
    try app.clear();
    const line = try composeLine(app.arena(), config, input);
    try app.emit("{s}", .{line});
}

fn readNumberNonTty(reader: anytype, config: NumberConfig) !i64 {
    var buf: [32]u8 = undefined;
    const line = try readLine(reader, &buf);
    if (line.len == 0) {
        return config.default orelse return error.InvalidNumber;
    }
    return std.fmt.parseInt(i64, line, 10) catch return error.InvalidNumber;
}

/// Read a line (sans trailing newline) into the caller-owned `buf`, returning
/// the filled slice. The slice borrows `buf`, so it stays valid as long as the
/// caller's buffer does — never return a slice into a local buffer from here.
/// Stops at '\n' or when `buf` is full. Returns `error.EndOfStream` if the
/// stream closes before any byte is read; a partial line terminated by EOF is
/// returned as-is.
fn readLine(reader: anytype, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        const byte = terminal.key.readByteFn(reader) catch {
            if (len == 0) return error.EndOfStream;
            break;
        };
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
    var reader_stream: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var writer_stream: std.Io.Writer = .fixed(&output);

    const result = try number(.{ .writer = &writer_stream, .reader = &reader_stream, .allocator = std.testing.allocator }, .{
        .message = "Count:",
    });
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "non-TTY: multi-digit value survives the readLine buffer boundary" {
    // Regression: readLine used to return a slice into its own stack frame, so
    // the digits could be clobbered before parseInt ran. A longer value makes
    // that corruption observable if it ever returns.
    var input = "1234567\n".*;
    var reader_stream: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var writer_stream: std.Io.Writer = .fixed(&output);

    const result = try number(.{ .writer = &writer_stream, .reader = &reader_stream, .allocator = std.testing.allocator }, .{
        .message = "Value:",
    });
    try std.testing.expectEqual(@as(i64, 1234567), result);
}

test "non-TTY: empty input falls back to the default" {
    var input = "\n".*;
    var reader_stream: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var writer_stream: std.Io.Writer = .fixed(&output);

    const result = try number(.{ .writer = &writer_stream, .reader = &reader_stream, .allocator = std.testing.allocator }, .{
        .message = "Port:",
        .default = 3000,
    });
    try std.testing.expectEqual(@as(i64, 3000), result);
}

test "non-TTY: empty input with no default errors" {
    var input = "\n".*;
    var reader_stream: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var writer_stream: std.Io.Writer = .fixed(&output);

    try std.testing.expectError(error.InvalidNumber, number(.{ .writer = &writer_stream, .reader = &reader_stream, .allocator = std.testing.allocator }, .{
        .message = "Port:",
    }));
}

test "non-TTY: EOF errors instead of falling back to the default" {
    var input = "".*;
    var reader_stream: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var writer_stream: std.Io.Writer = .fixed(&output);

    // A closed stdin surfaces even when a default exists — a retry loop would
    // otherwise spin forever re-prompting a dead stream.
    try std.testing.expectError(error.EndOfStream, number(.{ .writer = &writer_stream, .reader = &reader_stream, .allocator = std.testing.allocator }, .{
        .message = "Port:",
        .default = 3000,
    }));
}

test "non-TTY: non-numeric input errors" {
    var input = "abc\n".*;
    var reader_stream: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var writer_stream: std.Io.Writer = .fixed(&output);

    try std.testing.expectError(error.InvalidNumber, number(.{ .writer = &writer_stream, .reader = &reader_stream, .allocator = std.testing.allocator }, .{
        .message = "Count:",
    }));
}
