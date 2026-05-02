//! Editor prompt — launches $EDITOR for multiline text input.

const std = @import("std");
const terminal = @import("terminal");
const zinput = @import("zinput.zig");

pub const EditorConfig = struct {
    message: []const u8,
    default: ?[]const u8 = null,
    extension: []const u8 = ".txt",
    prefix: []const u8 = "? ",
};

/// Launch the user's editor for multiline input. Returns owned string.
pub fn editor(writer: anytype, reader: anytype, allocator: std.mem.Allocator, config: EditorConfig) ![]u8 {
    const is_tty = terminal.isStdinTty();

    try writer.print("{s}{s}", .{ config.prefix, config.message });

    if (!is_tty) {
        // Non-TTY: read all remaining input
        try writer.writeAll("\n");
        var buf = std.ArrayList(u8){};
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

    try writer.writeAll(" \x1b[2m(press Enter to open editor)\x1b[0m ");
    zinput.flushWriter(writer);

    // Wait for Enter in raw mode
    const raw = terminal.enableRawMode(std.fs.File.stdin().handle) catch {
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
    zinput.flushWriter(writer);

    try writer.writeAll("\r\n");
    zinput.flushWriter(writer);

    // Find editor
    const editor_cmd = std.posix.getenv("VISUAL") orelse
        std.posix.getenv("EDITOR") orelse
        "vi";

    // Create temp file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_name = try std.fmt.allocPrint(allocator, "zinput_edit{s}", .{config.extension});
    defer allocator.free(tmp_name);

    // Write default content
    var tmp_file = try tmp_dir.dir.createFile(tmp_name, .{});
    if (config.default) |def| {
        try tmp_file.writeAll(def);
    }
    tmp_file.close();

    // Get the real path for the editor
    const real_path = try tmp_dir.dir.realpathAlloc(allocator, tmp_name);
    defer allocator.free(real_path);

    // Spawn editor
    var child = std.process.Child.init(&.{ editor_cmd, real_path }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const result = try child.wait();

    if (result.Exited != 0) {
        return try allocator.dupe(u8, config.default orelse "");
    }

    // Read back content
    const raw_content = try tmp_dir.dir.readFileAlloc(allocator, tmp_name, 1024 * 1024);

    // Trim trailing newlines that editors typically add
    const trimmed = std.mem.trimRight(u8, raw_content, "\n\r");
    if (trimmed.len < raw_content.len) {
        const trimmed_copy = try allocator.dupe(u8, trimmed);
        allocator.free(raw_content);
        return trimmed_copy;
    }

    return raw_content;
}

test "EditorConfig defaults" {
    const cfg = EditorConfig{ .message = "Edit:" };
    try std.testing.expect(cfg.default == null);
    try std.testing.expectEqualStrings(".txt", cfg.extension);
}
