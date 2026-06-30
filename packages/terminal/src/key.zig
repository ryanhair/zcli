//! Key reading and escape sequence parsing.

const std = @import("std");
const posix = std.posix;

/// How long to wait for the rest of an escape sequence before deciding a bare
/// ESC byte was a lone Escape keypress (only used by `readKeyOpt`).
const esc_timeout_ms = 50;

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
    const T = @TypeOf(reader);
    const info = @typeInfo(T);
    if (info == .pointer) {
        const Child = info.pointer.child;
        if (@hasDecl(Child, "takeByte")) return try reader.takeByte();
        if (@hasDecl(Child, "readSliceAll")) {
            var buf: [1]u8 = undefined;
            try reader.readSliceAll(&buf);
            return buf[0];
        }
    }
    if (@hasDecl(T, "takeByte")) return try reader.takeByte();
    if (@hasDecl(T, "readByte")) return try reader.readByte();
    var buf: [1]u8 = undefined;
    const n = try reader.read(&buf);
    if (n == 0) return error.EndOfStream;
    return buf[0];
}

/// Read a single key from a reader, parsing ANSI escape sequences.
/// In raw mode, this reads byte-by-byte and assembles multi-byte
/// sequences (arrow keys, etc.) into Key values.
pub fn readKey(reader: anytype) !Key {
    return readKeyImpl(reader, null);
}

/// Like `readKey`, but reliably distinguishes a lone Escape from the start of an
/// escape sequence (arrow keys, etc.). A bare ESC byte with nothing buffered is
/// ambiguous, so we poll `esc_fd` briefly for the rest of a sequence; if none
/// arrives it's a lone Escape. Callers that want ESC to mean something pass the
/// stdin fd here; `readKey` (no poll) is fine for callers that ignore ESC.
pub fn readKeyOpt(reader: anytype, esc_fd: posix.fd_t) !Key {
    return readKeyImpl(reader, esc_fd);
}

fn readKeyImpl(reader: anytype, esc_fd: ?posix.fd_t) !Key {
    const byte = try readByteFn(reader);

    return switch (byte) {
        '\r', '\n' => .enter,
        '\t' => .tab,
        127 => .backspace,
        '\x1b' => parseEscapeSequence(reader, esc_fd),
        // Ctrl+A through Ctrl+Z (1-26, excluding 9=tab, 10=newline, 13=cr, 27=esc)
        1...8, 11...12, 14...26 => .{ .ctrl = byte + 'a' - 1 },
        // Printable characters
        32...126 => .{ .char = byte },
        else => .{ .char = byte },
    };
}

fn parseEscapeSequence(reader: anytype, esc_fd: ?posix.fd_t) !Key {
    // A lone ESC has no following bytes. Arrow keys, etc. arrive as one chunk, so
    // their bytes are already buffered; if nothing is buffered, only poll (when a
    // fd is given) decides — otherwise treat it as a lone Escape rather than block.
    if (!escapeSequenceFollows(reader, esc_fd)) return .escape;

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

/// Whether more of an escape sequence follows the ESC byte: true if bytes are
/// already buffered (the common case — sequences arrive whole), otherwise a
/// short poll on `esc_fd` (when provided) catches a sequence split across reads.
fn escapeSequenceFollows(reader: anytype, esc_fd: ?posix.fd_t) bool {
    if (bufferedLenOf(reader) > 0) return true;
    const fd = esc_fd orelse return false;
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, esc_timeout_ms) catch return false;
    return n > 0;
}

/// Buffered byte count for readers that expose it (std.Io.Reader); 0 otherwise.
fn bufferedLenOf(reader: anytype) usize {
    const T = @TypeOf(reader);
    if (@typeInfo(T) == .pointer) {
        const Child = @typeInfo(T).pointer.child;
        if (@hasDecl(Child, "bufferedLen")) return reader.bufferedLen();
    }
    return 0;
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
    var reader: std.Io.Reader = .fixed(&buf);
    const k = try readKey(&reader);
    try std.testing.expect(k == .enter);
}

test "readKey parses tab" {
    var buf = "\t".*;
    var reader: std.Io.Reader = .fixed(&buf);
    const k = try readKey(&reader);
    try std.testing.expect(k == .tab);
}

test "readKey parses backspace" {
    var buf = [_]u8{127};
    var reader: std.Io.Reader = .fixed(&buf);
    const k = try readKey(&reader);
    try std.testing.expect(k == .backspace);
}

test "readKey parses printable char" {
    var buf = "a".*;
    var reader: std.Io.Reader = .fixed(&buf);
    const k = try readKey(&reader);
    try std.testing.expect(k.char == 'a');
}

test "readKey parses arrow up" {
    var buf = "\x1b[A".*;
    var reader: std.Io.Reader = .fixed(&buf);
    const k = try readKey(&reader);
    try std.testing.expect(k == .up);
}

test "readKey parses arrow down" {
    var buf = "\x1b[B".*;
    var reader: std.Io.Reader = .fixed(&buf);
    const k = try readKey(&reader);
    try std.testing.expect(k == .down);
}

test "readKey parses ctrl+c" {
    var buf = [_]u8{3};
    var reader: std.Io.Reader = .fixed(&buf);
    const k = try readKey(&reader);
    try std.testing.expectEqual(Key{ .ctrl = 'c' }, k);
}

test "readKey parses delete" {
    var buf = "\x1b[3~".*;
    var reader: std.Io.Reader = .fixed(&buf);
    const k = try readKey(&reader);
    try std.testing.expect(k == .delete);
}
