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
    /// Threaded environ, used to honor `$TMPDIR` when placing the scratch
    /// file. Falls back to `/tmp` when unset (or when `environ` itself is
    /// null, e.g. in tests that don't exercise the temp-file path).
    environ: ?*const std.process.Environ.Map = null,
};

/// Launch the user's editor for multiline input. Returns owned string,
/// `error.UserAborted` if the user presses Ctrl-C, or `error.EndOfStream` if
/// stdin closes with no input to submit.
pub fn editor(p: Prompts, config: EditorConfig) ![]u8 {
    const writer = p.writer;
    const reader = p.reader;
    const allocator = p.allocator;
    const is_tty = terminal.isInteractiveTty();

    if (!is_tty) {
        try writer.print("{s}{s}", .{ config.prefix, config.message });
        // Non-TTY: read all remaining input until EOF.
        try writer.writeAll("\n");
        // Flush so the prompt is visible before we block reading input —
        // buffered writers otherwise strand it until after input arrives.
        Prompts.flushWriter(writer);
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
    var raw_active = true;
    errdefer if (raw_active) raw.disable();
    // Watches for SIGWINCH so a resize while the user is at the hint line
    // repaints instead of leaving the wrapped prompt stale. Torn down (along
    // with raw mode) before the child editor is spawned so it inherits a clean
    // terminal and default signal disposition.
    var watcher = terminal.ResizeWatcher.init();
    var watcher_active = true;
    errdefer if (watcher_active) watcher.deinit();
    const stdin = std.Io.File.stdin().handle;
    var app = try ui.App.init(p.allocator, writer, .{
        .capability = p.theme.capability(),
        .hybrid_raw = raw,
    });
    defer app.deinit();
    try renderFrame(&app, p.theme, config);

    while (true) {
        const k = switch (try terminal.readEvent(reader, stdin, &watcher)) {
            .resize => {
                try renderFrame(&app, p.theme, config);
                continue;
            },
            .key => |key| key,
            else => continue,
        };
        switch (k) {
            .enter => break,
            .ctrl => |c| {
                if (c == 'c') {
                    try app.clear();
                    try app.emit("{s}{s}", .{ config.prefix, config.message });
                    app.deinit();
                    watcher.deinit();
                    watcher_active = false;
                    raw.disable();
                    raw_active = false;
                    Prompts.flushWriter(writer);
                    return error.UserAborted;
                }
            },
            else => {},
        }
    }
    // Persist the prompt line and hand the editor a clean terminal: region
    // closed, cursor restored, resize watcher and raw mode off.
    try app.clear();
    try app.emit("{s}{s}", .{ config.prefix, config.message });
    app.deinit();
    watcher.deinit();
    watcher_active = false;
    raw.disable();
    raw_active = false;
    Prompts.flushWriter(writer);

    // Create temp file and write default content. The name is randomized (a
    // local attacker who knows a fixed name could pre-plant a symlink at it,
    // CWE-59) and created with `.exclusive = true` (refuses to follow an
    // existing path) and mode 0600 (the content — potentially a secret being
    // edited — isn't left world-readable while the editor is open).
    const tmp_dir = if (config.environ) |e| (e.get("TMPDIR") orelse "/tmp") else "/tmp";
    var name_buf: [scratch_name_len]u8 = undefined;
    const scratch_name = randomScratchName(config.io, &name_buf);
    const tmp_name = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ tmp_dir, scratch_name, config.extension });
    defer allocator.free(tmp_name);

    const cwd = std.Io.Dir.cwd();
    var tmp_file = try cwd.createFile(config.io, tmp_name, .{
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    });
    // Remove the scratch file on every exit path. Registered immediately after
    // createFile — before the write below — so a failed initial write can't
    // leak a 0600 file that may hold sensitive pre-fill content.
    defer cwd.deleteFile(config.io, tmp_name) catch {};
    {
        // Close the fd on any exit from this block (success or a write error)
        // so a failed write doesn't leak the descriptor either.
        defer tmp_file.close(config.io);
        if (config.default) |def| {
            try tmp_file.writeStreamingAll(config.io, def);
        }
    }

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
    errdefer allocator.free(raw_content);

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

/// Length of a scratch file name: the ".prompts_edit-" prefix plus 16 hex chars.
const scratch_name_len = ".prompts_edit-".len + 16;

/// A random, unpredictable name for the scratch file, so a local attacker
/// cannot pre-plant anything (e.g. a symlink) at the edit path.
fn randomScratchName(io: std.Io, buf: *[scratch_name_len]u8) []const u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const hex = std.fmt.bytesToHex(&random_bytes, .lower);
    return std.fmt.bufPrint(buf, ".prompts_edit-{s}", .{hex}) catch unreachable;
}

test "randomScratchName - hidden, fixed-length, unpredictable" {
    var buf_a: [scratch_name_len]u8 = undefined;
    var buf_b: [scratch_name_len]u8 = undefined;
    const a = randomScratchName(std.testing.io, &buf_a);
    const b = randomScratchName(std.testing.io, &buf_b);

    try std.testing.expect(std.mem.startsWith(u8, a, ".prompts_edit-"));
    try std.testing.expectEqual(scratch_name_len, a.len);
    try std.testing.expect(!std.mem.eql(u8, a, b));
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
