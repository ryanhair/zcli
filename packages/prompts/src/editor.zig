//! Editor prompt — launches $EDITOR for multiline text input.

const std = @import("std");
const terminal = @import("terminal");
const prompts = @import("prompts.zig");

pub const EditorConfig = struct {
    message: []const u8,
    default: ?[]const u8 = null,
    extension: []const u8 = ".txt",
    prefix: []const u8 = "? ",
    editor_cmd: []const u8 = "vi",
    io: std.Io,
    /// Theme + terminal capabilities for styling; zcli commands pass `context.theme`.
    theme: prompts.theme.ThemeContext = prompts.default_style,
};

/// Launch the user's editor for multiline input. Returns owned string.
pub fn editor(writer: anytype, reader: anytype, allocator: std.mem.Allocator, config: EditorConfig) ![]u8 {
    const is_tty = terminal.isStdinTty();

    try writer.print("{s}{s}", .{ config.prefix, config.message });

    if (!is_tty) {
        // Non-TTY: read all remaining input
        try writer.writeAll("\n");
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        while (true) {
            const byte = terminal.key.readByteFn(reader) catch break;
            try buf.append(allocator, byte);
        }
        if (buf.items.len == 0) {
            if (config.default) |def| return try allocator.dupe(u8, def);
        }
        return try buf.toOwnedSlice(allocator);
    }

    var obuf: [64]u8 = undefined;
    const open = prompts.openSeq(&obuf, config.theme, config.theme.promptTokens().hint);
    try writer.print(" {s}(press Enter to open editor){s} ", .{ open, prompts.closeSeq(open) });
    prompts.flushWriter(writer);

    // Wait for Enter in raw mode
    const raw = terminal.enableRawMode(std.Io.File.stdin().handle) catch {
        try writer.writeAll("\r\n");
        return try allocator.dupe(u8, config.default orelse "");
    };

    while (true) {
        const k = try terminal.readKey(reader);
        switch (k) {
            .enter => break,
            .ctrl => |c| {
                if (c == 'c') {
                    raw.disable();
                    try writer.writeAll("\r\n");
                    return error.UserAborted;
                }
            },
            else => {},
        }
    }
    raw.disable();
    prompts.flushWriter(writer);

    try writer.writeAll("\r\n");
    prompts.flushWriter(writer);

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
