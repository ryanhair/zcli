//! Text input prompt.
//!
//! The TTY path renders on the ui engine: each keystroke paints one frame of
//! the prompt line (wrapping across rows as the input grows — the engine
//! reserves and diffs the region), and `showCursorAt` keeps the real terminal
//! cursor at the insertion point. On Enter the line persists as static
//! output. Input handling stays here.

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const lr = @import("list_render.zig");
const ui = lr.ui;

/// Optional live preview rendered on the line *above* the prompt, repainted
/// on every keystroke. `render` receives the current input and returns one
/// line of plain text allocated from `a` (a frame arena — do not free), or
/// null for no preview. The prompt styles it with the theme's hint token.
/// Only active on a TTY.
pub const Preview = struct {
    context: *anyopaque,
    render: *const fn (context: *anyopaque, a: std.mem.Allocator, input: []const u8) anyerror!?[]const u8,
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

/// Prompt for text input. Returns an owned string (caller frees),
/// `error.Interrupted` if the user presses one of `config.interrupt_keys`, or
/// `error.EndOfStream` if stdin closes with no line to submit.
pub fn text(p: Prompts, config: TextConfig) ![]u8 {
    const writer = p.writer;
    const reader = p.reader;
    const allocator = p.allocator;
    const is_tty = terminal.isInteractiveTty();

    if (!is_tty) {
        // Non-TTY: prompt inline, read a line byte by byte
        try writer.print("{s}{s}", .{ config.prefix, config.message });
        if (config.default) |def| {
            try writer.print(" ({s})", .{def});
        }
        try writer.writeAll(" ");
        const line = try readLine(reader, allocator);
        defer allocator.free(line);
        if (line.len == 0) {
            if (config.default) |def| return try allocator.dupe(u8, def);
        }
        try writer.writeAll("\n");
        return try allocator.dupe(u8, line);
    }

    // TTY: raw mode character-by-character input
    Prompts.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch {
        try writer.print("{s}{s} \n", .{ config.prefix, config.message });
        return try allocator.dupe(u8, config.default orelse "");
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

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try renderFrame(&app, p.theme, config, buf.items);

    while (true) {
        const k = if (config.interrupt_keys.len > 0)
            try terminal.readKeyOpt(reader, std.Io.File.stdin().handle)
        else
            try terminal.readKey(reader);
        if (Prompts.isInterrupt(k, config.interrupt_keys)) {
            try persistLine(&app, config, buf.items);
            return error.Interrupted;
        }
        switch (k) {
            .enter => {
                try persistLine(&app, config, buf.items);
                if (buf.items.len == 0) {
                    if (config.default) |def| return try allocator.dupe(u8, def);
                }
                return try allocator.dupe(u8, buf.items);
            },
            .backspace => {
                if (buf.items.len > 0) {
                    Prompts.popTrailingGrapheme(&buf);
                    try renderFrame(&app, p.theme, config, buf.items);
                }
            },
            .ctrl => |c| {
                if (c == 'c') {
                    try persistLine(&app, config, buf.items);
                    return error.UserAborted;
                }
            },
            .char => |c| {
                _ = try Prompts.appendCodepoint(allocator, &buf, c);
                try renderFrame(&app, p.theme, config, buf.items);
            },
            else => {},
        }
    }
}

/// The prompt line as one string: "? message (default) input".
fn composeLine(a: std.mem.Allocator, config: TextConfig, input: []const u8) ![]const u8 {
    return if (config.default) |def|
        std.fmt.allocPrint(a, "{s}{s} ({s}) {s}", .{ config.prefix, config.message, def, input })
    else
        std.fmt.allocPrint(a, "{s}{s} {s}", .{ config.prefix, config.message, input });
}

fn renderFrame(app: *ui.App, ctx: Prompts.ThemeContext, config: TextConfig, input: []const u8) !void {
    const a = app.arena();
    const ws = lr.windowSize();
    const node = try frameNode(a, ctx, config, input, ws);
    try app.frame(node);

    // Real cursor at the insertion point (end of input).
    const usable = @max(@as(usize, ws.col) -| 1, 1);
    const pos = Prompts.endPosition(try composeLine(app.arena(), config, input), usable);
    const preview_rows: u16 = if (config.preview != null) 1 else 0;
    try app.showCursorAt(pos.x, pos.y + preview_rows);
}

/// Build the (preview +) prompt-line frame. Pure and size-explicit for tests.
pub fn frameNode(
    a: std.mem.Allocator,
    ctx: Prompts.ThemeContext,
    config: TextConfig,
    input: []const u8,
    ws: terminal.Winsize,
) !ui.Node {
    const usable: u16 = @intCast(@min(@max(@as(usize, ws.col) -| 1, 1), std.math.maxInt(u16)));

    var rows = std.ArrayList(ui.Node).empty;
    if (config.preview) |preview| {
        const content = (try preview.render(preview.context, a, input)) orelse "";
        const hint_style = ctx.resolveRef(ctx.promptTokens().hint);
        try rows.append(a, ui.textOpts(.{ .style = hint_style, .wrap = .clip }, content));
    }
    try rows.append(a, ui.text(.{}, try composeLine(a, config, input)));
    return ui.column(a, .{ .width = .{ .len = usable } }, rows.items);
}

/// Erase the live prompt and persist its final state as a static line.
fn persistLine(app: *ui.App, config: TextConfig, input: []const u8) !void {
    try app.clear();
    const line = try composeLine(app.arena(), config, input);
    try app.emit("{s}", .{line});
}

/// Read a line from a reader byte by byte until newline. Returns
/// `error.EndOfStream` if the stream closes before any byte is read (nothing to
/// submit); a partial line terminated by EOF (bytes but no trailing newline) is
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

    const result = try text(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
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

    const result = try text(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Name:",
        .default = "world",
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("world", result);
}

test "text: non-TTY EOF errors even with a default" {
    const allocator = std.testing.allocator;
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    // EOF is distinct from an empty submission: it must surface, not silently
    // fall back to the default (a retry loop would spin forever otherwise).
    try std.testing.expectError(error.EndOfStream, text(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Name:",
        .default = "fallback",
    }));
}

test "text: non-TTY partial line without trailing newline still submits" {
    const allocator = std.testing.allocator;
    var input = "typed".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try text(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Name:",
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("typed", result);
}

test "text: prompt message appears in output" {
    const allocator = std.testing.allocator;
    var input = "test\n".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try text(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Enter name:",
        .default = "foo",
    });
    defer allocator.free(result);

    const written = output_writer.buffer[0..output_writer.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "Enter name:") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "(foo)") != null);
}

test "frameNode: prompt line with input; preview row above wears the hint token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Echo = struct {
        fn render(_: *anyopaque, alloc: std.mem.Allocator, input: []const u8) anyerror!?[]const u8 {
            if (input.len == 0) return null;
            return try std.fmt.allocPrint(alloc, "-> {s}", .{input});
        }
    };
    var dummy: u8 = 0;
    const node = try frameNode(a, Prompts.default_style, .{
        .message = "Name:",
        .preview = .{ .context = @ptrCast(&dummy), .render = Echo.render },
    }, "ab", .{ .row = 24, .col = 40 });

    var s = try ui.Surface.init(std.testing.allocator, 39, 2);
    defer s.deinit();
    const rctx = ui.RenderCtx{ .allocator = a };
    try ui.render(&rctx, &node, s.root());

    // Row 0: preview "-> ab" in the hint style; row 1: "? Name: ab".
    try std.testing.expectEqualStrings("-", s.cellText(s.cell(0, 0)));
    const hint = Prompts.default_style.resolveRef(Prompts.default_style.promptTokens().hint);
    try std.testing.expect(ui.styleEql(hint, s.cell(0, 0).style));
    try std.testing.expectEqualStrings("?", s.cellText(s.cell(0, 1)));
    try std.testing.expectEqualStrings("a", s.cellText(s.cell(8, 1)));
}

test "endPosition: insertion point tracks the wrapped prompt line" {
    // "? Name: " is 8 columns; empty input puts the cursor after the space.
    const empty = Prompts.endPosition("? Name: ", 20);
    try std.testing.expectEqual(@as(u16, 8), empty.x);
    try std.testing.expectEqual(@as(u16, 0), empty.y);

    // Input pushes the cursor along; wrapping moves it to the next row.
    const typed = Prompts.endPosition("? Name: abc", 20);
    try std.testing.expectEqual(@as(u16, 11), typed.x);
    const wrapped = Prompts.endPosition("? Name: alpha bravo charlie", 20);
    try std.testing.expect(wrapped.y >= 1);
}
