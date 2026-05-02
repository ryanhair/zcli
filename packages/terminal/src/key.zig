//! Key reading and escape sequence parsing.

const std = @import("std");

/// A parsed key input from the terminal.
pub const Key = union(enum) {
    char: u8,
    enter,
    backspace,
    delete,
    escape,
    tab,
    up,
    down,
    left,
    right,
    home,
    end,
    ctrl: u8,

    pub fn format(self: Key, writer: anytype) !void {
        switch (self) {
            .char => |c| try writer.print("'{c}'", .{c}),
            .enter => try writer.writeAll("<enter>"),
            .backspace => try writer.writeAll("<backspace>"),
            .delete => try writer.writeAll("<delete>"),
            .escape => try writer.writeAll("<escape>"),
            .tab => try writer.writeAll("<tab>"),
            .up => try writer.writeAll("<up>"),
            .down => try writer.writeAll("<down>"),
            .left => try writer.writeAll("<left>"),
            .right => try writer.writeAll("<right>"),
            .home => try writer.writeAll("<home>"),
            .end => try writer.writeAll("<end>"),
            .ctrl => |c| try writer.print("<ctrl+{c}>", .{c}),
        }
    }
};

/// Read a single byte from a reader.
/// Supports std.Io.Reader (pointer with readSliceAll) and GenericReader (value with readByte).
pub fn readByteFn(reader: anytype) !u8 {
    // Pointer types (like *std.Io.Reader) — use readSliceAll
    const info = @typeInfo(@TypeOf(reader));
    if (info == .pointer) {
        const Child = info.pointer.child;
        if (@hasDecl(Child, "readSliceAll")) {
            var buf: [1]u8 = undefined;
            try reader.readSliceAll(&buf);
            return buf[0];
        }
    }
    // Value types (like GenericReader) — use readByte
    if (@hasDecl(@TypeOf(reader), "readByte")) {
        return try reader.readByte();
    }
    // Last resort
    var buf: [1]u8 = undefined;
    const n = try reader.read(&buf);
    if (n == 0) return error.EndOfStream;
    return buf[0];
}

/// Read a single key from a reader, parsing ANSI escape sequences.
/// In raw mode, this reads byte-by-byte and assembles multi-byte
/// sequences (arrow keys, etc.) into Key values.
pub fn readKey(reader: anytype) !Key {
    const byte = try readByteFn(reader);

    return switch (byte) {
        '\r', '\n' => .enter,
        '\t' => .tab,
        127 => .backspace,
        '\x1b' => parseEscapeSequence(reader),
        // Ctrl+A through Ctrl+Z (1-26, excluding 9=tab, 10=newline, 13=cr, 27=esc)
        1...8, 11...12, 14...26 => .{ .ctrl = byte + 'a' - 1 },
        // Printable characters
        32...126 => .{ .char = byte },
        else => .{ .char = byte },
    };
}

fn parseEscapeSequence(reader: anytype) !Key {
    // Try to read the next byte — if it's '[', this is a CSI sequence
    const next = readByteFn(reader) catch return .escape;

    if (next == '[') {
        // CSI sequence: ESC [ ...
        const code = readByteFn(reader) catch return .escape;
        return switch (code) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            '3' => blk: {
                // ESC [ 3 ~ = Delete
                const tilde = readByteFn(reader) catch break :blk .escape;
                if (tilde == '~') break :blk .delete;
                break :blk .escape;
            },
            else => .escape,
        };
    } else if (next == 'O') {
        // SS3 sequence: ESC O ...
        const code = readByteFn(reader) catch return .escape;
        return switch (code) {
            'H' => .home,
            'F' => .end,
            else => .escape,
        };
    }

    return .escape;
}

// Tests
test "Key format" {
    const allocator = std.testing.allocator;
    const k: Key = .enter;
    const str = try std.fmt.allocPrint(allocator, "{f}", .{k});
    defer allocator.free(str);
    try std.testing.expectEqualStrings("<enter>", str);
}

test "Key char format" {
    const allocator = std.testing.allocator;
    const k: Key = .{ .char = 'x' };
    const str = try std.fmt.allocPrint(allocator, "{f}", .{k});
    defer allocator.free(str);
    try std.testing.expectEqualStrings("'x'", str);
}

test "readKey parses enter" {
    var buf = "\r".*;
    var fbs = std.io.fixedBufferStream(&buf);
    const k = try readKey(fbs.reader());
    try std.testing.expect(k == .enter);
}

test "readKey parses tab" {
    var buf = "\t".*;
    var fbs = std.io.fixedBufferStream(&buf);
    const k = try readKey(fbs.reader());
    try std.testing.expect(k == .tab);
}

test "readKey parses backspace" {
    var buf = [_]u8{127};
    var fbs = std.io.fixedBufferStream(&buf);
    const k = try readKey(fbs.reader());
    try std.testing.expect(k == .backspace);
}

test "readKey parses printable char" {
    var buf = "a".*;
    var fbs = std.io.fixedBufferStream(&buf);
    const k = try readKey(fbs.reader());
    try std.testing.expect(k.char == 'a');
}

test "readKey parses arrow up" {
    var buf = "\x1b[A".*;
    var fbs = std.io.fixedBufferStream(&buf);
    const k = try readKey(fbs.reader());
    try std.testing.expect(k == .up);
}

test "readKey parses arrow down" {
    var buf = "\x1b[B".*;
    var fbs = std.io.fixedBufferStream(&buf);
    const k = try readKey(fbs.reader());
    try std.testing.expect(k == .down);
}

test "readKey parses ctrl+c" {
    var buf = [_]u8{3};
    var fbs = std.io.fixedBufferStream(&buf);
    const k = try readKey(fbs.reader());
    try std.testing.expectEqual(Key{ .ctrl = 'c' }, k);
}

test "readKey parses delete" {
    var buf = "\x1b[3~".*;
    var fbs = std.io.fixedBufferStream(&buf);
    const k = try readKey(fbs.reader());
    try std.testing.expect(k == .delete);
}
