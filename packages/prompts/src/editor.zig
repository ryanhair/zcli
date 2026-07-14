//! Editor prompt — launches $EDITOR for multiline text input.
//!
//! The hint line renders on the ui engine; before spawning the editor the
//! App is closed (cursor restored, region persisted) so the editor gets a
//! clean terminal.

const std = @import("std");
const terminal = @import("terminal");
const Prompts = @import("Prompts.zig");
const lr = @import("list_render.zig");
const ui = lr.ui;

pub const EditorConfig = struct {
    message: []const u8,
    default: ?[]const u8 = null,
    extension: []const u8 = ".txt",
    prefix: []const u8 = "? ",
    editor_cmd: []const u8 = "vi",
    io: std.Io,
};

/// Launch the user's editor for multiline input. Returns owned string, or
/// `error.EndOfStream` if stdin closes with no input to submit.
pub fn editor(p: Prompts, config: EditorConfig) ![]u8 {
    const writer = p.writer;
    const reader = p.reader;
    const allocator = p.allocator;
    const is_tty = terminal.isStdinTty();

    if (!is_tty) {
        try writer.print("{s}{s}", .{ config.prefix, config.message });
        // Non-TTY: read all remaining input until EOF.
        try writer.writeAll("\n");
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        while (true) {
            const byte = terminal.key.readByteFn(reader) catch break;
            try buf.append(allocator, byte);
        }
        // Nothing typed on a closed stdin surfaces rather than masquerading as
        // an empty document (the `default` is pre-fill content, not a fallback).
        if (buf.items.len == 0) return error.EndOfStream;
        return try buf.toOwnedSlice(allocator);
    }

    // Wait for Enter in raw mode, hint line rendered as a frame.
    Prompts.flushWriter(writer);
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch {
        try writer.print("{s}{s}\n", .{ config.prefix, config.message });
        return try allocator.dupe(u8, config.default orelse "");
    };
    var app = try ui.App.init(p.allocator, writer, .{
        .capability = p.theme.capability(),
        .hybrid_raw = raw,
    });
    defer app.deinit();
    try renderFrame(&app, p.theme, config);

    while (true) {
        const k = try terminal.readKey(reader);
        switch (k) {
            .enter => break,
            .ctrl => |c| {
                if (c == 'c') {
                    try app.clear();
                    try app.emit("{s}{s}", .{ config.prefix, config.message });
                    app.deinit();
                    raw.disable();
                    Prompts.flushWriter(writer);
                    return error.UserAborted;
                }
            },
            else => {},
        }
    }
    // Persist the prompt line and hand the editor a clean terminal: region
    // closed, cursor restored, raw mode off.
    try app.clear();
    try app.emit("{s}{s}", .{ config.prefix, config.message });
    app.deinit();
    raw.disable();
    Prompts.flushWriter(writer);

    // Create temp file and write default content
    const tmp_name = try std.fmt.allocPrint(allocator, "/tmp/prompts_edit{s}", .{config.extension});
    defer allocator.free(tmp_name);

    const cwd = std.Io.Dir.cwd();
    var tmp_file = try cwd.createFile(config.io, tmp_name, .{});
    if (config.default) |def| {
        try tmp_file.writeStreamingAll(config.io, def);
    }
    tmp_file.close(config.io);

    // Spawn editor
    var child = try std.process.spawn(config.io, .{
        .argv = &.{ config.editor_cmd, tmp_name },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(config.io);

    if (term != .exited or term.exited != 0) {
        return try allocator.dupe(u8, config.default orelse "");
    }

    // Read back content
    const raw_content = try cwd.readFileAlloc(config.io, tmp_name, allocator, .limited(1024 * 1024));

    // Trim trailing newlines
    const trimmed = std.mem.trimEnd(u8, raw_content, "\n\r");
    if (trimmed.len < raw_content.len) {
        const trimmed_copy = try allocator.dupe(u8, trimmed);
        allocator.free(raw_content);
        return trimmed_copy;
    }

    return raw_content;
}

test "EditorConfig defaults" {
    const cfg = EditorConfig{ .message = "Edit:", .io = std.testing.io };
    try std.testing.expect(cfg.default == null);
    try std.testing.expectEqualStrings(".txt", cfg.extension);
}

test "non-TTY: EOF with no input errors" {
    const allocator = std.testing.allocator;
    var input = "".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    try std.testing.expectError(error.EndOfStream, editor(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Edit:",
        .default = "prefill",
        .io = std.testing.io,
    }));
}

test "non-TTY: reads piped multiline input" {
    const allocator = std.testing.allocator;
    var input = "line one\nline two".*;
    var input_reader: std.Io.Reader = .fixed(&input);
    var output: [256]u8 = undefined;
    var output_writer: std.Io.Writer = .fixed(&output);

    const result = try editor(.{ .writer = &output_writer, .reader = &input_reader, .allocator = allocator }, .{
        .message = "Edit:",
        .io = std.testing.io,
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("line one\nline two", result);
}

fn renderFrame(app: *ui.App, ctx: Prompts.ThemeContext, config: EditorConfig) !void {
    const a = app.arena();
    const ws = terminal.getWindowSize(std.Io.File.stdout().handle) catch terminal.Winsize{ .row = 24, .col = 80 };
    const usable: u16 = @intCast(@min(@max(@as(usize, ws.col) -| 1, 1), std.math.maxInt(u16)));
    const head = try std.fmt.allocPrint(a, "{s}{s} ", .{ config.prefix, config.message });
    const hint = "(press Enter to open editor) ";
    const hint_style = ctx.resolveRef(ctx.promptTokens().hint);
    try app.frame(try ui.column(a, .{ .width = .{ .len = usable } }, &.{
        try ui.row(a, .{}, &.{
            ui.textOpts(.{ .wrap = .clip }, head),
            ui.textOpts(.{ .style = hint_style, .wrap = .clip }, hint),
        }),
    }));
    const line = try std.fmt.allocPrint(app.arena(), "{s}{s}", .{ head, hint });
    const pos = Prompts.endPosition(line, usable);
    try app.showCursorAt(pos.x, pos.y);
}
