//! Key reading and escape sequence parsing.

const std = @import("std");
const backend = @import("backend.zig");

/// How long to wait for the rest of an escape sequence before deciding a bare
/// ESC byte was a lone Escape keypress (only used by `readKeyOpt`, and only when
/// nothing is already buffered). Locally the buffered fast path makes this
/// irrelevant; the window mainly matters over a high-latency link (e.g. SSH),
/// where too small a value risks misreading a split arrow-key sequence as Escape.
const esc_timeout_ms = 75;

/// A parsed key input from the terminal.
pub const Key = union(enum) {
    /// A typed Unicode codepoint. Multibyte UTF-8 sequences are assembled by
    /// `readKey`, so one keypress (or one pasted character) is one `.char`.
    char: u21,
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
            .char => |c| try writer.print("'{u}'", .{c}),
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

/// A mouse report (SGR encoding, DECSET 1006). Coordinates are 1-based cells,
/// as the terminal reports them — subtract 1 to index a 0-based surface.
pub const Mouse = struct {
    pub const Button = enum { left, middle, right, wheel_up, wheel_down, none };
    /// `drag` is motion with a button held (needs DECSET 1002); `move` is motion
    /// with no button (hover — needs 1003, not enabled by default, so it does not
    /// occur in the current full-screen wiring).
    pub const Action = enum { press, release, drag, move };
    pub const Mods = struct { shift: bool = false, alt: bool = false, ctrl: bool = false };

    x: u16,
    y: u16,
    button: Button,
    action: Action,
    mods: Mods = .{},
};

/// A focus change (DECSET 1004): the terminal window gained or lost focus.
pub const Focus = enum { in, out };

/// A single parsed input token from the byte stream. `readEvent` lifts this into
/// an `Event` (adding the out-of-band `resize`); `readKey` projects it back to
/// just the key case. Mouse/focus only arrive when their modes are enabled.
pub const Input = union(enum) {
    key: Key,
    mouse: Mouse,
    focus: Focus,
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
/// ambiguous, so we poll `esc_handle` briefly for the rest of a sequence; if none
/// arrives it's a lone Escape. Callers that want ESC to mean something pass the
/// stdin handle here; `readKey` (no poll) is fine for callers that ignore ESC.
pub fn readKeyOpt(reader: anytype, esc_handle: backend.Handle) !Key {
    return readKeyImpl(reader, esc_handle);
}

/// Read one input token — a key, or (when their modes are enabled) a mouse or
/// focus event. The single byte→token parser; `readKey` and the event
/// multiplexer both funnel through it.
pub fn readInput(reader: anytype, esc_handle: ?backend.Handle) !Input {
    const byte = try readByteFn(reader);

    return switch (byte) {
        '\r', '\n' => .{ .key = .enter },
        '\t' => .{ .key = .tab },
        127 => .{ .key = .backspace },
        '\x1b' => parseEscapeSequence(reader, esc_handle),
        // Ctrl+A through Ctrl+Z (1-26, excluding 9=tab, 10=newline, 13=cr, 27=esc)
        1...8, 11...12, 14...26 => .{ .key = .{ .ctrl = byte + 'a' - 1 } },
        // Lead byte of a multibyte UTF-8 sequence
        0x80...0xff => .{ .key = .{ .char = readUtf8Tail(reader, byte) } },
        // Printable ASCII (plus the few remaining C0 codes callers ignore)
        else => .{ .key = .{ .char = byte } },
    };
}

/// Key-only projection of `readInput`. Mouse/focus tokens (which arrive only if
/// those modes are enabled — key-only callers like `prompts` never enable them)
/// collapse to `.escape`, harmlessly ignored.
fn readKeyImpl(reader: anytype, esc_handle: ?backend.Handle) !Key {
    return switch (try readInput(reader, esc_handle)) {
        .key => |k| k,
        .mouse, .focus => .escape,
    };
}

/// U+FFFD REPLACEMENT CHARACTER — what invalid UTF-8 input decodes to.
pub const replacement_char: u21 = 0xFFFD;

/// Assemble the rest of a multibyte UTF-8 sequence whose lead byte was already
/// read. The continuation bytes arrive in the same terminal write as the lead
/// byte, so they're already buffered. Anything invalid (stray continuation
/// byte, bad lead, overlong encoding) decodes to U+FFFD rather than surfacing
/// raw bytes as separate keys.
fn readUtf8Tail(reader: anytype, lead: u8) u21 {
    const len = std.unicode.utf8ByteSequenceLength(lead) catch return replacement_char;
    var seq: [4]u8 = undefined;
    seq[0] = lead;
    for (seq[1..len]) |*b| b.* = readByteFn(reader) catch return replacement_char;
    return std.unicode.utf8Decode(seq[0..len]) catch replacement_char;
}

/// A key token wrapped as an `Input` — the common escape-parse result.
fn keyIn(key: Key) Input {
    return .{ .key = key };
}

fn parseEscapeSequence(reader: anytype, esc_handle: ?backend.Handle) !Input {
    // A lone ESC has no following bytes. Arrow keys, etc. arrive as one chunk, so
    // their bytes are already buffered; if nothing is buffered, only the poll
    // (when a handle is given) decides — otherwise treat it as a lone Escape
    // rather than block.
    if (!escapeSequenceFollows(reader, esc_handle)) return keyIn(.escape);

    // Try to read the next byte — if it's '[', this is a CSI sequence
    const next = readByteFn(reader) catch return keyIn(.escape);

    if (next == '[') {
        // CSI sequence: ESC [ ...
        const code = readByteFn(reader) catch return keyIn(.escape);
        return switch (code) {
            'A' => keyIn(.up),
            'B' => keyIn(.down),
            'C' => keyIn(.right),
            'D' => keyIn(.left),
            'H' => keyIn(.home),
            'F' => keyIn(.end),
            // Focus in/out (DECSET 1004). `ESC [ O` is distinct from the SS3
            // `ESC O …` below (no intervening `[`).
            'I' => .{ .focus = .in },
            'O' => .{ .focus = .out },
            // SGR mouse (DECSET 1006): ESC [ < Cb ; Cx ; Cy (M|m).
            '<' => parseMouseSgr(reader),
            '3' => blk: {
                // ESC [ 3 ~ = Delete
                const tilde = readByteFn(reader) catch break :blk keyIn(.escape);
                if (tilde == '~') break :blk keyIn(.delete);
                break :blk keyIn(.escape);
            },
            else => keyIn(.escape),
        };
    } else if (next == 'O') {
        // SS3 sequence: ESC O ...
        const code = readByteFn(reader) catch return keyIn(.escape);
        return switch (code) {
            'H' => keyIn(.home),
            'F' => keyIn(.end),
            else => keyIn(.escape),
        };
    }

    return keyIn(.escape);
}

/// Parse the tail of an SGR mouse report (`ESC [ <` already consumed):
/// `Cb ; Cx ; Cy` then `M` (press) or `m` (release). Any malformed byte
/// collapses to `.escape` rather than desyncing the stream.
fn parseMouseSgr(reader: anytype) !Input {
    const cb = readCsiNum(reader) catch return keyIn(.escape);
    if (cb.term != ';') return keyIn(.escape);
    const cx = readCsiNum(reader) catch return keyIn(.escape);
    if (cx.term != ';') return keyIn(.escape);
    const cy = readCsiNum(reader) catch return keyIn(.escape);
    if (cy.term != 'M' and cy.term != 'm') return keyIn(.escape);
    return .{ .mouse = decodeMouse(cb.val, cx.val, cy.val, cy.term == 'M') };
}

const CsiNum = struct { val: u16, term: u8 };

/// Read a decimal parameter and the non-digit byte that terminated it.
fn readCsiNum(reader: anytype) !CsiNum {
    var val: u16 = 0;
    var any = false;
    while (true) {
        const b = try readByteFn(reader);
        if (b >= '0' and b <= '9') {
            val = val *% 10 +% (b - '0');
            any = true;
        } else {
            if (!any) return error.InvalidMouse;
            return .{ .val = val, .term = b };
        }
    }
}

/// Decode an SGR button code into a `Mouse`. Low 2 bits pick the button; bit 6
/// (64) marks a wheel; bit 5 (32) marks motion (drag with a button, else move);
/// bits 2/3/4 are shift/alt/ctrl.
fn decodeMouse(cb: u16, x: u16, y: u16, press: bool) Mouse {
    const wheel = (cb & 64) != 0;
    const motion = (cb & 32) != 0;
    const low = cb & 3;

    var button: Mouse.Button = .none;
    var action: Mouse.Action = if (press) .press else .release;
    if (wheel) {
        button = if (low == 0) .wheel_up else .wheel_down;
        action = .press;
    } else {
        button = switch (low) {
            0 => .left,
            1 => .middle,
            2 => .right,
            else => .none,
        };
        if (motion) action = if (button == .none) .move else .drag;
    }

    return .{
        .x = x,
        .y = y,
        .button = button,
        .action = action,
        .mods = .{
            .shift = (cb & 4) != 0,
            .alt = (cb & 8) != 0,
            .ctrl = (cb & 16) != 0,
        },
    };
}

/// Whether more of an escape sequence follows the ESC byte: true if bytes are
/// already buffered (the common case — sequences arrive whole), otherwise a
/// short poll on `esc_handle` (when provided) catches a sequence split across
/// reads.
fn escapeSequenceFollows(reader: anytype, esc_handle: ?backend.Handle) bool {
    if (bufferedLen(reader) > 0) return true;
    const handle = esc_handle orelse return false;
    return backend.waitReadable(handle, esc_timeout_ms);
}

/// Buffered byte count for readers that expose it (std.Io.Reader); 0 otherwise.
/// Public so the event multiplexer can avoid blocking on a poll when the reader
/// already has bytes in hand.
pub fn bufferedLen(reader: anytype) usize {
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

test "readKey assembles multibyte UTF-8 into one char" {
    // 2-byte (é), 3-byte (你), and 4-byte (😊) sequences each yield one key.
    var buf = "é你😊".*;
    var reader: std.Io.Reader = .fixed(&buf);
    try std.testing.expectEqual(Key{ .char = 'é' }, try readKey(&reader));
    try std.testing.expectEqual(Key{ .char = '你' }, try readKey(&reader));
    try std.testing.expectEqual(Key{ .char = '😊' }, try readKey(&reader));
    try std.testing.expectError(error.EndOfStream, readKey(&reader));
}

test "readKey maps invalid UTF-8 to U+FFFD" {
    // Stray continuation byte (no lead).
    var cont = [_]u8{0xa9};
    var r1: std.Io.Reader = .fixed(&cont);
    try std.testing.expectEqual(Key{ .char = replacement_char }, try readKey(&r1));

    // Lead byte with a truncated tail (followed by ASCII, which gets consumed
    // as the would-be continuation byte and fails the decode).
    var trunc = "\xc3a".*;
    var r2: std.Io.Reader = .fixed(&trunc);
    try std.testing.expectEqual(Key{ .char = replacement_char }, try readKey(&r2));

    // Overlong encoding of '/' (0xc0 0xaf) — an invalid lead in modern UTF-8.
    var overlong = "\xc0\xaf".*;
    var r3: std.Io.Reader = .fixed(&overlong);
    try std.testing.expectEqual(Key{ .char = replacement_char }, try readKey(&r3));
}

test "Key format renders a multibyte char" {
    const allocator = std.testing.allocator;
    const k: Key = .{ .char = '你' };
    const str = try std.fmt.allocPrint(allocator, "{f}", .{k});
    defer allocator.free(str);
    try std.testing.expectEqualStrings("'你'", str);
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

fn parseInput(comptime bytes: []const u8) !Input {
    var buf: [bytes.len]u8 = undefined;
    @memcpy(&buf, bytes);
    var reader: std.Io.Reader = .fixed(&buf);
    return readInput(&reader, null);
}

test "readInput parses an SGR mouse press" {
    // ESC [ < 0 ; 10 ; 5 M — left button press at (10, 5).
    const i = try parseInput("\x1b[<0;10;5M");
    try std.testing.expectEqual(Mouse{
        .x = 10,
        .y = 5,
        .button = .left,
        .action = .press,
        .mods = .{},
    }, i.mouse);
}

test "readInput distinguishes press (M) from release (m)" {
    try std.testing.expectEqual(Mouse.Action.press, (try parseInput("\x1b[<2;1;1M")).mouse.action);
    const rel = (try parseInput("\x1b[<2;1;1m")).mouse;
    try std.testing.expectEqual(Mouse.Action.release, rel.action);
    try std.testing.expectEqual(Mouse.Button.right, rel.button);
}

test "readInput decodes wheel, drag, and modifiers" {
    // 64 = wheel bit, low 2 bits 0 -> wheel up.
    const wheel = (try parseInput("\x1b[<64;3;3M")).mouse;
    try std.testing.expectEqual(Mouse.Button.wheel_up, wheel.button);
    try std.testing.expectEqual(Mouse.Action.press, wheel.action);

    // 32 = motion bit, low 2 bits 0 (left held) -> left drag.
    const drag = (try parseInput("\x1b[<32;5;5M")).mouse;
    try std.testing.expectEqual(Mouse.Button.left, drag.button);
    try std.testing.expectEqual(Mouse.Action.drag, drag.action);

    // 16 = ctrl modifier on a left press.
    const ctrl = (try parseInput("\x1b[<16;1;1M")).mouse;
    try std.testing.expect(ctrl.mods.ctrl and !ctrl.mods.shift and !ctrl.mods.alt);
}

test "readInput handles multi-digit mouse coordinates" {
    const m = (try parseInput("\x1b[<0;120;48M")).mouse;
    try std.testing.expectEqual(@as(u16, 120), m.x);
    try std.testing.expectEqual(@as(u16, 48), m.y);
}

test "readInput parses focus in/out" {
    try std.testing.expectEqual(Focus.in, (try parseInput("\x1b[I")).focus);
    try std.testing.expectEqual(Focus.out, (try parseInput("\x1b[O")).focus);
}

test "readInput still parses keys" {
    try std.testing.expectEqual(Key.up, (try parseInput("\x1b[A")).key);
    try std.testing.expectEqual(Key{ .char = 'a' }, (try parseInput("a")).key);
}

test "malformed mouse sequence degrades to escape, not a desync" {
    try std.testing.expectEqual(Key.escape, (try parseInput("\x1b[<0;xM")).key);
}
