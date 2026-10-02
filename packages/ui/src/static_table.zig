//! Plain, one-shot tables for command output. No terminal session or cursor state.

const std = @import("std");
const terminal = @import("terminal");
const theme_mod = @import("theme");

pub const StaticTable = struct {
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    theme: theme_mod.ThemeContext,
    /// Available terminal columns. Null means a pipe/file: preserve full cells.
    width: ?usize = null,

    pub const Align = enum { left, right };
    pub const Overflow = enum { truncate, wrap };
    pub const Column = struct {
        header: []const u8,
        alignment: Align = .left,
        min_width: usize = 1,
        /// Applies to terminal display only; redirected output is complete.
        max_width: ?usize = null,
        /// Higher priorities absorb terminal shrinkage first.
        shrink_priority: u8 = 0,
        overflow: Overflow = .truncate,
    };

    /// Write a header and rows. A short row has blank trailing cells; extra
    /// cells are ignored. Explicit line breaks create additional table lines;
    /// terminal cells may also wrap according to their column's overflow rule.
    /// Input ANSI escapes are removed so untrusted cell text cannot control the
    /// terminal and piped output never inherits styling from cell values.
    pub fn print(self: StaticTable, columns: []const Column, rows: []const []const []const u8) !void {
        if (columns.len == 0) return;
        const widths = try self.allocator.alloc(usize, columns.len);
        defer self.allocator.free(widths);

        for (columns, 0..) |col, ci| {
            if (col.min_width == 0 or (col.max_width != null and col.max_width.? < col.min_width))
                return error.InvalidColumnWidth;
            var natural = maxLineWidth(col.header);
            for (rows) |row| {
                if (ci < row.len) natural = @max(natural, maxLineWidth(row[ci]));
            }
            widths[ci] = if (self.width != null)
                @max(col.min_width, @min(natural, col.max_width orelse natural))
            else
                natural;
        }

        if (self.width) |available| {
            const separators = (columns.len - 1) * 2;
            if (available <= separators) return error.TerminalTooNarrow;
            var total = separators;
            for (widths) |w| total += w;
            while (total > available) {
                var candidate: ?usize = null;
                for (columns, 0..) |col, ci| {
                    if (widths[ci] <= col.min_width) continue;
                    if (candidate == null or col.shrink_priority > columns[candidate.?].shrink_priority or
                        (col.shrink_priority == columns[candidate.?].shrink_priority and widths[ci] > widths[candidate.?]))
                    {
                        candidate = ci;
                    }
                }
                if (candidate == null) {
                    // An extremely narrow terminal takes precedence over the
                    // preferred minimum; every visible column keeps one cell.
                    for (widths, 0..) |w, ci| {
                        if (w > 1 and (candidate == null or w > widths[candidate.?])) candidate = ci;
                    }
                }
                if (candidate == null) return error.TerminalTooNarrow;
                const floor: usize = if (widths[candidate.?] > columns[candidate.?].min_width)
                    columns[candidate.?].min_width
                else
                    1;
                const shrink = @min(total - available, widths[candidate.?] - floor);
                widths[candidate.?] -= shrink;
                total -= shrink;
            }
        }

        // The theme's header role is applied only for terminal output. A pipe
        // receives the same text with no escape sequences.
        try self.printRow(columns, widths, null, self.width != null and self.theme.capability() != .no_color);
        for (rows) |row| try self.printRow(columns, widths, row, false);
    }

    fn printRow(self: StaticTable, columns: []const Column, widths: []const usize, row: ?[]const []const u8, styled_header: bool) !void {
        const cell_lines = try self.allocator.alloc(std.ArrayList([]const u8), columns.len);
        defer self.allocator.free(cell_lines);
        for (cell_lines) |*lines| lines.* = .empty;
        defer for (cell_lines) |*lines| lines.deinit(self.allocator);
        var owned_lines: std.ArrayList([]u8) = .empty;
        defer {
            for (owned_lines.items) |owned| self.allocator.free(owned);
            owned_lines.deinit(self.allocator);
        }

        var height: usize = 1;
        for (columns, 0..) |col, ci| {
            const raw = if (row) |r| (if (ci < r.len) r[ci] else "") else col.header;
            var physical = std.mem.splitScalar(u8, raw, '\n');
            while (physical.next()) |part| {
                const line = try normalizeLine(self.allocator, std.mem.trimEnd(u8, part, "\r"));
                owned_lines.append(self.allocator, line) catch |err| {
                    self.allocator.free(line);
                    return err;
                };
                if (self.width != null and col.overflow == .wrap and visibleWidth(line) > widths[ci]) {
                    const wrapped = try terminal.wrapToWidth(self.allocator, line, widths[ci]);
                    defer self.allocator.free(wrapped);
                    for (wrapped) |segment| try cell_lines[ci].append(self.allocator, segment);
                } else {
                    try cell_lines[ci].append(self.allocator, line);
                }
            }
            height = @max(height, cell_lines[ci].items.len);
        }

        for (0..height) |line_index| {
            for (columns, 0..) |col, ci| {
                if (ci > 0) try self.writer.writeAll("  ");
                const text = if (line_index < cell_lines[ci].items.len) cell_lines[ci].items[line_index] else "";
                const content_width = visibleWidth(text);
                const truncated = self.width != null and content_width > widths[ci];
                const limit = if (truncated) widths[ci] - 1 else widths[ci];
                const text_width = if (self.width == null) content_width else limit;
                const painted_width = visiblePrefixWidth(text, text_width) + @as(usize, if (truncated) 1 else 0);
                const pad = widths[ci] - painted_width;
                if (col.alignment == .right) try spaces(self.writer, pad);
                if (styled_header) {
                    var aw = std.Io.Writer.Allocating.init(self.allocator);
                    defer aw.deinit();
                    try writeVisible(&aw.writer, text, text_width);
                    if (truncated) try aw.writer.writeAll("…");
                    try theme_mod.styled(aw.written()).semanticRole(.muted).render(self.writer, &self.theme);
                } else {
                    try writeVisible(self.writer, text, text_width);
                    if (truncated) try self.writer.writeAll("…");
                }
                if (col.alignment == .left and ci + 1 < columns.len) try spaces(self.writer, pad);
            }
            try self.writer.writeByte('\n');
        }
    }
};

fn normalizeLine(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = terminal.visibleGraphemes(text);
    while (it.next()) |g| {
        if (isControl(g.bytes)) {
            try out.append(allocator, ' ');
        } else {
            try out.appendSlice(allocator, g.bytes);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn maxLineWidth(text: []const u8) usize {
    var max: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| max = @max(max, visibleWidth(std.mem.trimEnd(u8, line, "\r")));
    return max;
}

fn visibleWidth(text: []const u8) usize {
    var n: usize = 0;
    var it = terminal.visibleGraphemes(text);
    while (it.next()) |g| n += if (isControl(g.bytes)) 1 else g.width;
    return n;
}

fn visiblePrefixWidth(text: []const u8, limit: usize) usize {
    var used: usize = 0;
    var it = terminal.visibleGraphemes(text);
    while (it.next()) |g| {
        const w: usize = if (isControl(g.bytes)) 1 else g.width;
        if (used + w > limit) break;
        used += w;
    }
    return used;
}

fn writeVisible(writer: *std.Io.Writer, text: []const u8, max_width: usize) !void {
    var used: usize = 0;
    var it = terminal.visibleGraphemes(text);
    while (it.next()) |g| {
        const control = isControl(g.bytes);
        const w: usize = if (control) 1 else g.width;
        if (used + w > max_width) break;
        if (control) {
            try writer.writeByte(' ');
        } else {
            try writer.writeAll(g.bytes);
        }
        used += w;
    }
}

fn spaces(writer: *std.Io.Writer, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

// Measurement and rendering must assign the same width to sanitized controls.
fn isControl(bytes: []const u8) bool {
    return bytes.len == 1 and (bytes[0] < 0x20 or bytes[0] == 0x7f);
}

test "table frees multiline and wrapped cells on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn print(allocator: std.mem.Allocator) !void {
            var output: [512]u8 = undefined;
            var writer = std.Io.Writer.fixed(&output);
            const t: StaticTable = .{
                .writer = &writer,
                .allocator = allocator,
                .theme = .{ .caps = .{ .capability = .no_color, .is_tty = true, .color_enabled = false } },
                .width = 10,
            };
            try t.print(&.{ .{ .header = "A" }, .{ .header = "Text", .overflow = .wrap } }, &.{&.{ "a\nb", "one two three\nfour" }});
        }
    }.print, .{});
}

test "redirected controls and CRLF preserve following column alignment" {
    const testing = std.testing;
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const t: StaticTable = .{
        .writer = &aw.writer,
        .allocator = testing.allocator,
        .theme = .{ .caps = .{ .capability = .no_color, .is_tty = false, .color_enabled = false } },
    };
    try t.print(&.{ .{ .header = "A" }, .{ .header = "B" } }, &.{ &.{ "a\x07\x08\x7fb", "x" }, &.{ "z\r\nq\r", "y" } });
    try testing.expectEqualStrings("A      B\na   b  x\nz      y\nq      \n", aw.written());

    aw.clearRetainingCapacity();
    try t.print(&.{ .{ .header = "A\r" }, .{ .header = "B" } }, &.{&.{ "x\r", "y" }});
    try testing.expectEqualStrings("A  B\nx  y\n", aw.written());
}

test "redirected table preserves Unicode text without color" {
    const testing = std.testing;
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const t: StaticTable = .{
        .writer = &aw.writer,
        .allocator = testing.allocator,
        .theme = .{ .caps = .{ .capability = .true_color, .is_tty = false, .color_enabled = false } },
    };
    try t.print(&.{ .{ .header = "ID" }, .{ .header = "Title" } }, &.{&.{ "1", "你好 e\u{301} long" }});
    try testing.expectEqualStrings("ID  Title\n1   你好 e\u{301} long\n", aw.written());
}

test "terminal width shrinks selected column on grapheme boundaries" {
    const testing = std.testing;
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const t: StaticTable = .{
        .writer = &aw.writer,
        .allocator = testing.allocator,
        .theme = .{ .caps = .{ .capability = .no_color, .is_tty = true, .color_enabled = false } },
        .width = 12,
    };
    try t.print(&.{ .{ .header = "ID", .min_width = 2 }, .{ .header = "Title", .min_width = 2, .shrink_priority = 1 } }, &.{&.{ "42", "你好世界 hello" }});
    try testing.expectEqualStrings("ID  Title\n42  你好世…\n", aw.written());
}

test "redirected table preserves physical lines and strips input ANSI" {
    const testing = std.testing;
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const t: StaticTable = .{
        .writer = &aw.writer,
        .allocator = testing.allocator,
        .theme = .{ .caps = .{ .capability = .no_color, .is_tty = false, .color_enabled = false } },
    };
    try t.print(&.{ .{ .header = "Name" }, .{ .header = "Value", .alignment = .right } }, &.{&.{ "first\nsecond", "\x1b[31mred\x1b[0m\nblue" }});
    try testing.expectEqualStrings("Name    Value\nfirst     red\nsecond   blue\n", aw.written());
}

test "cell control bytes and OSC escapes cannot control table output" {
    const testing = std.testing;
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const t: StaticTable = .{
        .writer = &aw.writer,
        .allocator = testing.allocator,
        .theme = .{ .caps = .{ .capability = .no_color, .is_tty = false, .color_enabled = false } },
    };
    try t.print(&.{.{ .header = "Value" }}, &.{&.{"a\x07\x08\x7fb\x1b]0;evil\x07"}});
    try testing.expectEqualStrings("Value\na   b\n", aw.written());
}

test "terminal wrap and a truncated CJK column retain following alignment" {
    const testing = std.testing;
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const theme: theme_mod.ThemeContext = .{ .caps = .{ .capability = .no_color, .is_tty = true, .color_enabled = false } };
    const wrapped: StaticTable = .{ .writer = &aw.writer, .allocator = testing.allocator, .theme = theme, .width = 12 };
    try wrapped.print(&.{ .{ .header = "ID" }, .{ .header = "Text", .overflow = .wrap, .shrink_priority = 1 } }, &.{&.{ "1", "one two three" }});
    try testing.expectEqualStrings("ID  Text\n1   one two\n    three\n", aw.written());

    aw.clearRetainingCapacity();
    const truncated: StaticTable = .{ .writer = &aw.writer, .allocator = testing.allocator, .theme = theme, .width = 8 };
    try truncated.print(&.{ .{ .header = "Name", .shrink_priority = 1 }, .{ .header = "N" } }, &.{&.{ "你好好", "x" }});
    try testing.expectEqualStrings("Name   N\n你好…  x\n", aw.written());
}

test "column constraints report invalid declarations and unusable terminals" {
    const testing = std.testing;
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    const t: StaticTable = .{
        .writer = &aw.writer,
        .allocator = testing.allocator,
        .theme = .{ .caps = .{ .capability = .no_color, .is_tty = true, .color_enabled = false } },
        .width = 2,
    };
    try testing.expectError(error.InvalidColumnWidth, t.print(&.{.{ .header = "A", .min_width = 3, .max_width = 2 }}, &.{}));
    try testing.expectError(error.TerminalTooNarrow, t.print(&.{ .{ .header = "A" }, .{ .header = "B" } }, &.{}));
}
