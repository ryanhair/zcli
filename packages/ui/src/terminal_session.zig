//! TerminalSession: the process-global terminal state an App takes over —
//! raw mode, the resize watcher, the signal/panic restore guard, and the
//! full-screen enter/restore byte protocol (ADR-0015).
//!
//! This is the honestly-untestable part of the App, isolated: enabling raw
//! mode, watching SIGWINCH, and arming the guard all touch the real terminal
//! or process signal state, so the headless `term_size` harness skips them
//! (`headless` on takeover; the App never arms headlessly — tests
//! must not grab process signals). Everything that CAN be tested headlessly
//! lives elsewhere: the render pipeline in `RenderCore`, the parking
//! invariant in `RegionCursor`, the scrollback reflow in `HybridScrollback`.
//!
//! Restore discipline: `close` and the guard blob emit the same bytes in the
//! same order — disable input modes, undo the paint modes, show cursor, then
//! leave the alt-screen — and restore is the strict reverse of enter (ADR-0015
//! choice 5). The session records which takeover actually began, so callers
//! cannot accidentally select a weaker restore and strand terminal state.

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
const hybrid_restore = paint_off ++ cursor_on;

/// What a HYBRID takeover turns on: just the hidden cursor. Doubles as the blob
/// the guard replays when a SIGTSTP suspend resumes (#762) — "re-enter" is
/// literally re-emitting the enter bytes, and the paint modes come back with the
/// next paint. Hybrid is the only cooked mode, so it is the only one that can be
/// suspended in the first place.
const hybrid_enter = cursor_off;

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

    const CloseKind = enum { none, hybrid, full_screen };

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
    /// The display takeover `close` must undo. Set before takeover begins so a
    /// partial write, raw-mode failure, or headless run still selects the same
    /// restore as a completed entry. Kept here rather than passed to `close`:
    /// the session owns the state and a caller-selected weaker restore could
    /// strand the alt-screen.
    close_kind: CloseKind = .none,

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
    fn armGuard(
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

    /// Protect raw mode handed in by a hybrid caller before the first frame.
    /// No display state exists yet, so `close` disarms this registration but
    /// emits no restore bytes if the App never starts painting.
    pub fn protectHybridRaw(self: *TerminalSession, raw: terminal.RawMode) void {
        self.armGuard("", "", raw);
    }

    /// Hybrid takeover: arm the guard, then hide the cursor. Arming first makes
    /// the signal window safe; replaying a restore before the cursor is hidden
    /// is harmless, while hiding first could leave it hidden on interruption.
    /// `headless` still emits the stream but does not touch process signal state.
    pub fn takeoverHybrid(
        self: *TerminalSession,
        writer: *std.Io.Writer,
        headless: bool,
        raw: ?terminal.RawMode,
    ) !void {
        self.close_kind = .hybrid;
        if (!headless) self.armGuard(hybrid_restore, hybrid_enter, raw);
        try writer.writeAll(hybrid_enter);
    }

    /// Disarm the guard if this session armed it — clean teardown owns the
    /// restore from here (and the old signal dispositions come back).
    fn disarm(self: *TerminalSession) void {
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
    /// entered is a harmless no-op. The caller anchors the cursor and flushes;
    /// its enter errdefer and normal deinit both call the same `close` interface.
    pub fn takeoverFullScreen(self: *TerminalSession, writer: *std.Io.Writer, headless: bool) !void {
        // Set before the first fallible operation: even a raw-mode-enable
        // failure closes through the full-screen protocol, exactly as the old
        // enter errdefer did. `alt_off` is harmless if `alt_on` never landed.
        self.close_kind = .full_screen;
        if (!headless) {
            self.raw = try terminal.enableRawMode(std.Io.File.stdin().handle);
            self.watcher = terminal.ResizeWatcher.init();
            // Sized from the guard's own bound, so the two buffers can't drift;
            // `restore_max` proves at compile time that the blob fits both.
            var blob: [terminal.guard.blob_max]u8 = undefined;
            // No re-enter bytes: full-screen owns raw mode, raw mode clears
            // `ISIG`, and the guard only installs SIGTSTP for cooked takeovers —
            // so nothing here can ever be suspended into a resume (#762).
            self.armGuard(self.restoreBlob(&blob), "", self.raw);
        }
        try writer.writeAll(alt_on ++ cursor_off);
        if (self.modes.mouse) try writer.writeAll(mouse_on);
        if (self.modes.focus) try writer.writeAll(focus_on);
        if (self.modes.paste) try writer.writeAll(paste_on);
    }

    /// The restore blob for the signal/panic guard: disable whichever input
    /// modes are on, then `restore_tail` (undo the paint modes + show cursor +
    /// leave alt-screen). Same bytes `close` emits on the normal path, packed
    /// into `buf`.
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

    /// Close whichever takeover this session began. This is the sole teardown
    /// interface: withdraw the async guard, attempt every restore sequence,
    /// flush those bytes, then release the watcher and raw mode. The latter two
    /// must happen after the flush so alt-screen leave reaches the terminal
    /// while the process still owns it (ADR-0015 choice 5).
    ///
    /// Each sequence is an independent best-effort write. A writer failure on
    /// (say) mouse disable must not suppress the later autowrap, cursor, or
    /// alt-screen restores. A dead sink still cannot be repaired; the guard is
    /// the abnormal-exit path that bypasses this buffered writer entirely.
    pub fn close(self: *TerminalSession, writer: *std.Io.Writer) void {
        const kind = self.close_kind;
        self.close_kind = .none;
        self.disarm();

        switch (kind) {
            .none => {},
            .hybrid => writeDisplayRestore(writer, false),
            .full_screen => {
                if (self.modes.mouse) writeBestEffort(writer, mouse_off);
                if (self.modes.focus) writeBestEffort(writer, focus_off);
                if (self.modes.paste) writeBestEffort(writer, paste_off);
                writeDisplayRestore(writer, true);
            },
        }
        writer.flush() catch {};
        self.release();
    }

    /// Release the process state: stop the resize watcher and restore the
    /// termios. Must come AFTER the restore bytes are flushed — the
    /// alt-screen leave has to go out while we still own the terminal.
    fn release(self: *TerminalSession) void {
        if (self.watcher) |*w| w.deinit();
        self.watcher = null;
        if (self.raw) |r| r.disable();
        self.raw = null;
    }
};

fn writeDisplayRestore(writer: *std.Io.Writer, leave_alt_screen: bool) void {
    // Keep these independent: one failed writer call costs at most its own
    // sequence instead of suppressing every terminal-global restore after it.
    writeBestEffort(writer, diff.wrap_on);
    writeBestEffort(writer, diff.sync_off);
    writeBestEffort(writer, cursor_on);
    if (leave_alt_screen) writeBestEffort(writer, alt_off);
}

fn writeBestEffort(writer: *std.Io.Writer, bytes: []const u8) void {
    writer.writeAll(bytes) catch {};
}

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
    try session.takeoverFullScreen(&aw.writer, true);

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

test "full-screen close emits byte-for-byte what the guard blob registers" {
    // The two restore paths — normal teardown and an async replay — must stay
    // identical, which is the whole reason both live in this file.
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    inline for ([_]TerminalSession.InputModes{
        .{},
        .{ .mouse = true },
        .{ .mouse = true, .focus = true, .paste = true },
    }) |modes| {
        var session = TerminalSession{ .out_handle = std.Io.File.stdout().handle, .modes = modes };
        var buf: [terminal.guard.blob_max]u8 = undefined;
        try session.takeoverFullScreen(&aw.writer, true);
        aw.clearRetainingCapacity();
        session.close(&aw.writer);
        try std.testing.expectEqualStrings(session.restoreBlob(&buf), aw.written());
    }
}

test "hybrid close preserves its final frame restore and is byte-idempotent" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var session = TerminalSession{ .out_handle = std.Io.File.stdout().handle };
    try session.takeoverHybrid(&aw.writer, true, null);
    try std.testing.expectEqualStrings(hybrid_enter, aw.written());

    aw.clearRetainingCapacity();
    session.close(&aw.writer);
    try std.testing.expectEqualStrings(hybrid_restore, aw.written());

    // The takeover state was consumed: a repeated close may flush, but cannot
    // emit another restore or release process resources twice.
    session.close(&aw.writer);
    try std.testing.expectEqualStrings(hybrid_restore, aw.written());
}

test "close without a display takeover emits no restore bytes" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var session = TerminalSession{ .out_handle = std.Io.File.stdout().handle };
    session.close(&aw.writer);
    try std.testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "a failed full-screen takeover still selects the full restore" {
    var fw: FlakyWriter = undefined;
    fw.init(std.testing.allocator, 0);
    defer fw.deinit();

    var session = TerminalSession{ .out_handle = std.Io.File.stdout().handle };
    try std.testing.expectError(
        error.WriteFailed,
        session.takeoverFullScreen(&fw.interface, true),
    );
    session.close(&fw.interface);
    fw.interface.flush() catch {};

    try std.testing.expect(std.mem.indexOf(u8, fw.log.items, diff.wrap_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, fw.log.items, diff.sync_off) != null);
    try std.testing.expect(std.mem.indexOf(u8, fw.log.items, cursor_on) != null);
    try std.testing.expect(std.mem.indexOf(u8, fw.log.items, alt_off) != null);
}

test "close attempts later restores after one writer failure" {
    const restores = [_][]const u8{
        mouse_off,
        focus_off,
        paste_off,
        diff.wrap_on,
        diff.sync_off,
        cursor_on,
        alt_off,
    };

    var saw_failure = false;
    for (0..20) |fail_at| {
        var setup = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer setup.deinit();
        var session = TerminalSession{
            .out_handle = std.Io.File.stdout().handle,
            .modes = .{ .mouse = true, .focus = true, .paste = true },
        };
        try session.takeoverFullScreen(&setup.writer, true);

        var fw: FlakyWriter = undefined;
        fw.init(std.testing.allocator, fail_at);
        defer fw.deinit();
        session.close(&fw.interface);
        // A close sequence may be buffered after the nominated drain failed;
        // this is the later retry App cleanup can rely on for a recoverable sink.
        fw.interface.flush() catch {};
        if (!fw.failed) continue;
        saw_failure = true;

        var missing: usize = 0;
        for (restores) |bytes| {
            if (std.mem.indexOf(u8, fw.log.items, bytes) == null) missing += 1;
        }
        // One failed drain may cost the sequence it was carrying, but it must
        // not stop the independent best-effort writes that follow it.
        try std.testing.expect(missing <= 1);
    }
    try std.testing.expect(saw_failure);
}

/// A buffered writer that rejects exactly one drain, then recovers. This is the
/// real File.Writer failure shape `close` can improve: errors are per call, not
/// sticky, so later restore writes and a later flush still have a route out.
const FlakyWriter = struct {
    buf: [8]u8 = undefined,
    interface: std.Io.Writer = undefined,
    log: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    calls: usize = 0,
    fail_at: usize,
    failed: bool = false,

    fn init(self: *FlakyWriter, gpa: std.mem.Allocator, fail_at: usize) void {
        self.* = .{ .gpa = gpa, .fail_at = fail_at };
        self.interface = .{ .vtable = &vtable, .buffer = &self.buf };
    }

    fn deinit(self: *FlakyWriter) void {
        self.log.deinit(self.gpa);
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FlakyWriter = @alignCast(@fieldParentPtr("interface", io_w));
        const call = self.calls;
        self.calls += 1;
        if (call == self.fail_at) {
            self.failed = true;
            return error.WriteFailed;
        }

        self.log.appendSlice(self.gpa, io_w.buffered()) catch return error.WriteFailed;
        io_w.end = 0;

        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.log.appendSlice(self.gpa, bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            self.log.appendSlice(self.gpa, pattern) catch return error.WriteFailed;
            n += pattern.len;
        }
        return n;
    }
};
