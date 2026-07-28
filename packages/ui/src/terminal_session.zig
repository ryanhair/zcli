//! TerminalSession: the process-global terminal state an App takes over —
//! raw mode, the resize watcher, the signal/panic restore guard, and the
//! full-screen enter/restore byte protocol (ADR-0015).
//!
//! This is the honestly-untestable part of the App, isolated: enabling raw
//! mode, watching SIGWINCH, and arming the guard all touch the real terminal
//! or process signal state, so the headless `term_size` harness skips them
//! (`headless` on `takeover`; the App never calls `arm` headlessly — tests
//! must not grab process signals). Everything that CAN be tested headlessly
//! lives elsewhere: the render pipeline in `RenderCore`, the parking
//! invariant in `RegionCursor`, the scrollback reflow in `HybridScrollback`.
//!
//! Restore discipline: the guard blob and `writeRestore` emit the same bytes
//! in the same order — disable input modes, undo the paint modes, show cursor,
//! then leave the alt-screen — and restore is the strict reverse of enter
//! (ADR-0015 choice 5). Both live here so they can never diverge.

const std = @import("std");
const terminal = @import("terminal");
const diff = @import("diff.zig");

// Full-screen takeover/restore escape sequences. The `*_on`/`*_off` pairs are
// DECSET enable/disable for the opt-in input modes; `restore_tail` undoes the
// paint modes, shows the cursor, and leaves the alt-screen.
const mouse_on = "\x1b[?1002h\x1b[?1006h"; // button+drag tracking, SGR encoding
const mouse_off = "\x1b[?1002l\x1b[?1006l";
const focus_on = "\x1b[?1004h";
const focus_off = "\x1b[?1004l";
const paste_on = "\x1b[?2004h"; // bracketed paste
const paste_off = "\x1b[?2004l";

/// Undo of the two modes `ui.diff` turns on *for the duration of a paint* and
/// off again in `EmitState.finish`: autowrap OFF (`?7l`) so the renderer can
/// write the last column without a wrap desynchronizing row addressing, and
/// synchronized output (`?2026h`) so the frame presents atomically.
///
/// They belong in every restore blob, not just in `finish`, because the writer
/// buffer drains mid-frame: `?7l` reaches the terminal long before its `?7h`, so
/// a `kill -TERM` (or a panic, or a Ctrl-Z) during a repaint used to leave
/// autowrap off — long shell lines then overwrite the last column instead of
/// wrapping — and synchronized output mid-update, which freezes the display
/// until the terminal's own BSU timeout fires (#760). Undoing a mode that was
/// never entered is a harmless no-op, so this is unconditional.
///
/// Sourced from `diff` rather than respelled, so a mode added to a paint cannot
/// silently go missing from the restore blob.
const paint_off = diff.wrap_on ++ diff.sync_off;

// Alt-screen and cursor visibility, named so the test below can pair each
// takeover byte with the restore byte that undoes it.
const alt_on = "\x1b[?1049h";
const alt_off = "\x1b[?1049l";
const cursor_off = "\x1b[?25l"; // hide
const cursor_on = "\x1b[?25h"; // show

/// What a HYBRID takeover has to undo: the paint modes plus the hidden cursor.
/// Hybrid owns no screen state beyond that (no alt-screen, no input modes).
pub const hybrid_restore = paint_off ++ cursor_on;

/// What a HYBRID takeover turns on: just the hidden cursor. Doubles as the blob
/// the guard replays when a SIGTSTP suspend resumes (#762) — "re-enter" is
/// literally re-emitting the enter bytes, and the paint modes come back with the
/// next paint. Hybrid is the only cooked mode, so it is the only one that can be
/// suspended in the first place.
pub const hybrid_enter = cursor_off;

const restore_tail = hybrid_restore ++ alt_off;

/// The longest blob `restoreBlob` can produce — every optional input mode on.
/// The guard copies it into a fixed buffer, so the bound is checked HERE, at
/// the one site that composes a blob, and at compile time: the runtime check in
/// `guard.arm` is a clamp, and the assert behind it compiles out in ReleaseFast
/// (#760). Adding a sequence above that busts `guard.blob_max` is a build error,
/// not a silent truncation and not a `@memcpy` overrun in release builds.
const restore_max = mouse_off.len + focus_off.len + paste_off.len + restore_tail.len;

comptime {
    if (restore_max > terminal.guard.blob_max) @compileError(std.fmt.comptimePrint(
        "the full-screen restore blob is {d} bytes but terminal.guard.blob_max is {d} — " ++
            "raise blob_max (and its doc comment's byte accounting) to fit",
        .{ restore_max, terminal.guard.blob_max },
    ));
}

pub const TerminalSession = struct {
    /// The opt-in full-screen input modes (`App.Options.mouse/focus/paste`).
    pub const InputModes = struct {
        mouse: bool = false,
        focus: bool = false,
        paste: bool = false,
    };

    /// The file handle output escapes actually reach — the guard's replay and
    /// size polling must hit the same tty the escapes went to (#385).
    out_handle: std.Io.File.Handle,
    modes: InputModes = .{},
    /// Session-owned raw mode, in full-screen only (the App reads input via
    /// `nextEvent`). `null` in hybrid, where input ownership stays external.
    raw: ?terminal.RawMode = null,
    /// Resize watcher backing `nextEvent`, full-screen only.
    watcher: ?terminal.ResizeWatcher = null,
    /// Whether this session armed the process-global restore guard. Gates the
    /// disarm — arming can precede the App's `started`, so `started` alone
    /// would leak the guard on a construct-then-error path.
    guard_armed: bool = false,

    /// Arm the process-global restore guard: replay `restore` (and the raw
    /// termios, when given) on a signal/panic that skips deinit. The single
    /// arm site for both modes, so the disarm gate can't drift.
    ///
    /// The push/replace split matters (#761): a session that has already armed
    /// is *re-registering* (hybrid arms with an empty blob in `App.init`, then
    /// again with the cursor-show blob in `App.start`) and must replace its own
    /// entry, whereas a session arming for the first time may be nested inside
    /// another one — a `prompts` prompt opened inside a full-screen App — and
    /// must stack on top of it instead of overwriting the outer session's blob
    /// and its pre-raw termios. `guard_armed` is what tells the two apart, and
    /// it already gates the matching single `disarm`.
    ///
    /// `reenter` is what puts the takeover back after a SIGTSTP suspend resumes
    /// (#762); empty for full-screen, which is raw and therefore never installs
    /// a suspend handler at all.
    pub fn arm(
        self: *TerminalSession,
        restore: []const u8,
        reenter: []const u8,
        raw: ?terminal.RawMode,
    ) void {
        const r: terminal.guard.Restore = .{
            .out = self.out_handle,
            .blob = restore,
            .reenter = reenter,
            .raw = raw,
        };
        if (self.guard_armed) terminal.guard.rearm(r) else terminal.guard.arm(r);
        self.guard_armed = true;
    }

    /// Disarm the guard if this session armed it — clean teardown owns the
    /// restore from here (and the old signal dispositions come back).
    pub fn disarm(self: *TerminalSession) void {
        if (!self.guard_armed) return;
        self.guard_armed = false;
        terminal.guard.disarm();
    }

    /// Full-screen takeover: enable session raw mode, start the resize
    /// watcher, arm the guard, and write the enter bytes (alt-screen, hide
    /// cursor, opt-in input modes). `headless` (the fixed-`term_size`
    /// harness) skips the process state but still emits the takeover bytes so
    /// the stream is exercised. The guard is armed BEFORE the bytes go out,
    /// so a signal in the gap still restores; undoing modes we haven't
    /// entered is a harmless no-op. The caller anchors the cursor and
    /// flushes; on a later enter failure it calls `abortEnter`.
    pub fn takeover(self: *TerminalSession, writer: *std.Io.Writer, headless: bool) !void {
        if (!headless) {
            self.raw = try terminal.enableRawMode(std.Io.File.stdin().handle);
            self.watcher = terminal.ResizeWatcher.init();
            // Sized from the guard's own bound, so the two buffers can't drift;
            // `restore_max` proves at compile time that the blob fits both.
            var blob: [terminal.guard.blob_max]u8 = undefined;
            // No re-enter bytes: full-screen owns raw mode, raw mode clears
            // `ISIG`, and the guard only installs SIGTSTP for cooked takeovers —
            // so nothing here can ever be suspended into a resume (#762).
            self.arm(self.restoreBlob(&blob), "", self.raw);
        }
        try writer.writeAll(alt_on ++ cursor_off);
        if (self.modes.mouse) try writer.writeAll(mouse_on);
        if (self.modes.focus) try writer.writeAll(focus_on);
        if (self.modes.paste) try writer.writeAll(paste_on);
    }

    /// Unwind a half-entered full-screen session (the enter path's errdefer):
    /// same bytes and order as clean teardown, so a failure between takeover
    /// and the first frame never strands the terminal.
    pub fn abortEnter(self: *TerminalSession, writer: *std.Io.Writer) void {
        self.disarm();
        self.writeRestore(writer);
        writer.flush() catch {};
        self.release();
    }

    /// The restore blob for the signal/panic guard: disable whichever input
    /// modes are on, then `restore_tail` (undo the paint modes + show cursor +
    /// leave alt-screen). Same bytes `writeRestore` emits on the normal path,
    /// packed into `buf`.
    fn restoreBlob(self: *const TerminalSession, buf: []u8) []const u8 {
        var n: usize = 0;
        const put = struct {
            fn f(dst: []u8, at: *usize, s: []const u8) void {
                @memcpy(dst[at.*..][0..s.len], s);
                at.* += s.len;
            }
        }.f;
        if (self.modes.mouse) put(buf, &n, mouse_off);
        if (self.modes.focus) put(buf, &n, focus_off);
        if (self.modes.paste) put(buf, &n, paste_off);
        put(buf, &n, restore_tail);
        return buf[0..n];
    }

    /// Emit the restore sequence to the writer (normal teardown / abort):
    /// disable input modes, undo the paint modes, then show cursor and leave the
    /// alt-screen. Byte-for-byte what `restoreBlob` registers with the guard.
    pub fn writeRestore(self: *const TerminalSession, writer: *std.Io.Writer) void {
        if (self.modes.mouse) writer.writeAll(mouse_off) catch {};
        if (self.modes.focus) writer.writeAll(focus_off) catch {};
        if (self.modes.paste) writer.writeAll(paste_off) catch {};
        writer.writeAll(restore_tail) catch {};
    }

    /// Release the process state: stop the resize watcher and restore the
    /// termios. Must come AFTER the restore bytes are flushed — the
    /// alt-screen leave has to go out while we still own the terminal.
    pub fn release(self: *TerminalSession) void {
        if (self.watcher) |*w| w.deinit();
        self.watcher = null;
        if (self.raw) |r| r.disable();
        self.raw = null;
    }
};

/// Every terminal mode a full-screen session leaves the terminal in, paired with
/// the bytes that undo it. The one enumeration both halves of the test below
/// read, so "the session turns X on" and "the restore turns X off" can't be
/// satisfied independently.
///
/// The last two entries are the ones #760 was about: they belong to a *paint*,
/// not to the session, and the 4096-byte writer buffer drains mid-frame — so
/// `?7l` reaches the terminal long before its `?7h` and an async restore has to
/// carry the undo itself.
const mode_pairs = [_]struct { on: []const u8, off: []const u8 }{
    .{ .on = alt_on, .off = alt_off },
    .{ .on = cursor_off, .off = cursor_on },
    .{ .on = mouse_on, .off = mouse_off },
    .{ .on = focus_on, .off = focus_off },
    .{ .on = paste_on, .off = paste_off },
    .{ .on = diff.wrap_off, .off = diff.wrap_on },
    .{ .on = diff.sync_on, .off = diff.sync_off },
};

test "the takeover stream turns on exactly the modes mode_pairs lists" {
    // Guards the enumeration itself: if `takeover` starts emitting a mode that
    // `mode_pairs` doesn't know about, the blob assertions below would keep
    // passing while the new mode went unrestored. Everything the takeover writes
    // has to be accounted for, so the check is on the *whole* stream.
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var session = TerminalSession{
        .out_handle = std.Io.File.stdout().handle,
        .modes = .{ .mouse = true, .focus = true, .paste = true },
    };
    // headless: emits the takeover bytes without touching real process state
    // (no raw mode, no resize watcher, no guard).
    try session.takeover(&aw.writer, true);

    var accounted: usize = 0;
    for (mode_pairs) |p| {
        if (std.mem.indexOf(u8, aw.written(), p.on) != null) accounted += p.on.len;
    }
    // Not `expect(indexOf != null)` per pair: the paint modes are legitimately
    // absent here (they belong to `diff`, not to the takeover), so the real
    // claim is that every byte the takeover wrote came from a listed `on`.
    try std.testing.expectEqual(aw.written().len, accounted);
}

test "the guard blob undoes every mode the session and its paints turn on" {
    // The #760 regression test. The blob is what a signal, a panic, or a Ctrl-Z
    // replays; anything the terminal is left in that the blob doesn't undo is a
    // mode the user's shell inherits. `?7h` was the one missing.
    const session = TerminalSession{
        .out_handle = std.Io.File.stdout().handle,
        .modes = .{ .mouse = true, .focus = true, .paste = true },
    };
    var buf: [terminal.guard.blob_max]u8 = undefined;
    const blob = session.restoreBlob(&buf);

    for (mode_pairs) |p| {
        std.testing.expect(std.mem.indexOf(u8, blob, p.off) != null) catch |e| {
            std.debug.print("restore blob is missing the undo for {f}\n", .{std.zig.fmtString(p.on)});
            return e;
        };
    }
}

test "writeRestore emits byte-for-byte what the guard blob registers" {
    // The two restore paths — normal teardown and an async replay — must stay
    // identical, which is the whole reason both live in this file.
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    inline for ([_]TerminalSession.InputModes{
        .{},
        .{ .mouse = true },
        .{ .mouse = true, .focus = true, .paste = true },
    }) |modes| {
        const session = TerminalSession{ .out_handle = std.Io.File.stdout().handle, .modes = modes };
        var buf: [terminal.guard.blob_max]u8 = undefined;
        aw.clearRetainingCapacity();
        session.writeRestore(&aw.writer);
        try std.testing.expectEqualStrings(session.restoreBlob(&buf), aw.written());
    }
}
