//! Masked password input prompt.
//!
//! The TTY path renders on the ui engine: one mask glyph per typed grapheme,
//! repainted as a frame per keystroke with the real cursor at the insertion
//! point. On Enter the masked line persists as static output.

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const lr = @import("list_render.zig");
const ui = lr.ui;

pub const PasswordConfig = struct {
    message: []const u8,
    mask: u8 = '*',
    prefix: []const u8 = "? ",
};

/// Prompt for password input with masking. Returns owned string,
/// `error.UserAborted` if the user presses Ctrl-C, or `error.EndOfStream` if
/// stdin closes with no line to submit.
pub fn password(p: Prompts, config: PasswordConfig) ![]u8 {
    const writer = p.writer;
    const reader = p.reader;
    const allocator = p.allocator;
    const is_tty = terminal.isInteractiveTty();

    if (!is_tty) {
        // Non-TTY: read line (no masking possible)
        try writer.print("{s}{s} ", .{ config.prefix, config.message });
        // Flush so the prompt is visible before we block reading the reply —
        // buffered writers otherwise strand it until after input arrives.
        Prompts.flushWriter(writer);
        const line = try readLine(reader, allocator);
        try writer.writeAll("\n");
        return line;
    }

    // TTY: raw mode with mask character
    Prompts.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch {
        try writer.print("{s}{s} \n", .{ config.prefix, config.message });
        return try allocator.dupe(u8, "");
    };
    var watcher = terminal.ResizeWatcher.init();
    defer {
        watcher.deinit();
        raw.disable();
        Prompts.flushWriter(writer);
    }
    var app = try ui.App.init(p.allocator, writer, .{
        .capability = p.theme.capability(),
        .hybrid_raw = raw,
    });
    defer app.deinit();

    const stdin = std.Io.File.stdin().handle;

    var buf = std.ArrayList(u8).empty;
    defer {
        // Defense-in-depth: wipe the cleartext password from the whole
        // backing allocation (not just `.items`, since capacity can exceed
        // length after a backspace) before it's freed.
        std.crypto.secureZero(u8, buf.allocatedSlice());
        buf.deinit(allocator);
    }

    try renderFrame(&app, config, buf.items);

    while (true) {
        // A SIGWINCH arrives out-of-band via the watcher, not as a key: repaint
        // so the wrapped mask/cursor reflow to the new width without waiting for
        // the next keystroke.
        const k = switch (try terminal.readEvent(reader, stdin, &watcher)) {
            .resize => {
                try renderFrame(&app, config, buf.items);
                continue;
            },
            .key => |key| key,
            else => continue,
        };
        switch (k) {
            .enter => {
                try persistLine(&app, config, buf.items);
                return try allocator.dupe(u8, buf.items);
            },
            .backspace => {
                if (buf.items.len > 0) {
                    Prompts.popTrailingGrapheme(&buf);
                    try renderFrame(&app, config, buf.items);
                }
            },
            .ctrl => |c| {
                if (c == 'c') {
                    try persistLine(&app, config, buf.items);
                    return error.UserAborted;
                }
            },
            .char => |c| {
                // One mask glyph per typed character, not per UTF-8 byte.
                try secureAppendCodepoint(allocator, &buf, c);
                try renderFrame(&app, config, buf.items);
            },
            else => {},
        }
    }
}

/// Append `c` to `buf` as UTF-8, wiping the cleartext from any backing block we
/// outgrow. `std.ArrayList`'s own realloc frees the old block without zeroing
/// it, stranding copies of the password in freed heap; on a grow we instead
/// allocate the new block, copy, `secureZero` the old, and free it ourselves,
/// so no cleartext survives past a keystroke (the caller's `defer` wipes the
/// final block).
fn secureAppendCodepoint(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), c: u21) !void {
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &utf8) catch unreachable; // readKey only yields valid scalars
    if (buf.items.len + n > buf.capacity) {
        const len = buf.items.len;
        const new_cap = @max(@max(buf.capacity *| 2, len + n), 16);
        const new_mem = try allocator.alloc(u8, new_cap);
        @memcpy(new_mem[0..len], buf.items);
        if (buf.capacity > 0) {
            const old = buf.allocatedSlice();
            std.crypto.secureZero(u8, old);
            allocator.free(old);
        }
        buf.items = new_mem[0..len];
        buf.capacity = new_cap;
    }
    buf.appendSliceAssumeCapacity(utf8[0..n]);
}

/// The masked prompt line: "? message ****".
fn composeLine(a: std.mem.Allocator, config: PasswordConfig, input: []const u8) ![]const u8 {
    const masks = try a.alloc(u8, terminal.graphemeCount(input));
    @memset(masks, config.mask);
    return std.fmt.allocPrint(a, "{s}{s} {s}", .{ config.prefix, config.message, masks });
}

fn renderFrame(app: *ui.App, config: PasswordConfig, input: []const u8) !void {
    const a = app.arena();
    const ws = lr.windowSize();
    const usable: u16 = @intCast(@min(@max(@as(usize, ws.col) -| 1, 1), std.math.maxInt(u16)));
    try app.frame(try ui.column(a, .{ .width = .{ .len = usable } }, &.{
        ui.text(.{}, try composeLine(a, config, input)),
    }));
    const pos = Prompts.endPosition(try composeLine(app.arena(), config, input), usable);
    try app.showCursorAt(pos.x, pos.y);
}

fn persistLine(app: *ui.App, config: PasswordConfig, input: []const u8) !void {
    try app.clear();
    const line = try composeLine(app.arena(), config, input);
    try app.emit("{s}", .{line});
}

/// Read a line byte by byte until newline. Returns `error.EndOfStream` if the
/// stream closes before any byte is read; a partial line terminated by EOF is
/// returned as the submitted line.
fn readLine(reader: anytype, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    while (true) {
        const byte = terminal.key.readByteFn(reader) catch {
            if (buf.items.len == 0) return error.EndOfStream;
            return try buf.toOwnedSlice(allocator);
        };
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

    const result = try password(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Password:",
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("secret123", result);
}

test "non-TTY: EOF errors instead of returning empty" {
    const allocator = std.testing.allocator;
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    // A closed stdin must not masquerade as an empty password.
    try std.testing.expectError(error.EndOfStream, password(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Password:",
    }));
}

test "prompt shows message" {
    const allocator = std.testing.allocator;
    var input = "pw\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try password(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Enter secret:",
    });
    defer allocator.free(result);

    const written = output_writer.buffer[0..output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "Enter secret:") != null);
}

test "secureAppendCodepoint appends correctly across the reallocs it manages" {
    // The secure grow does its own alloc/copy/free (so it can wipe the old
    // block) instead of leaning on ArrayList's realloc — this exercises that
    // hand-rolled pointer surgery across many grows and multibyte codepoints.
    // (The wipe itself only manifests in release builds: safe builds already
    // poison freed memory in `Allocator.free`, so it can't be observed here.)
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(allocator);

    // ASCII plus a 3-byte codepoint, repeated enough to force several grows.
    for (0..40) |_| {
        try secureAppendCodepoint(allocator, &buf, 'a');
        try expected.appendSlice(allocator, "a");
        try secureAppendCodepoint(allocator, &buf, '你'); // 3 bytes
        try expected.appendSlice(allocator, "你");
    }

    try std.testing.expectEqualStrings(expected.items, buf.items);
    try std.testing.expect(buf.capacity >= buf.items.len);
}

test "composeLine: one mask glyph per grapheme, not per byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // "你" is 3 bytes, one grapheme → exactly one mask char.
    const line = try composeLine(arena.allocator(), .{ .message = "PW:" }, "a你");
    try std.testing.expectEqualStrings("? PW: **", line);
}
