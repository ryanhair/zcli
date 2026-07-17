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
//! in the same order — disable input modes, then show cursor, then leave the
//! alt-screen — and restore is the strict reverse of enter (ADR-0015 choice
//! 5). Both live here so they can never diverge.

const std = @import("std");
const terminal = @import("terminal");

// Full-screen takeover/restore escape sequences. The `*_on`/`*_off` pairs are
// DECSET enable/disable for the opt-in input modes; `restore_tail` shows the
// cursor and leaves the alt-screen.
const mouse_on = "\x1b[?1002h\x1b[?1006h"; // button+drag tracking, SGR encoding
const mouse_off = "\x1b[?1002l\x1b[?1006l";
const focus_on = "\x1b[?1004h";
const focus_off = "\x1b[?1004l";
const paste_on = "\x1b[?2004h"; // bracketed paste
const paste_off = "\x1b[?2004l";
const restore_tail = "\x1b[?25h\x1b[?1049l";

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
    pub fn arm(self: *TerminalSession, restore: []const u8, raw: ?terminal.RawMode) void {
        terminal.guard.arm(self.out_handle, restore, raw);
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
            var blob: [64]u8 = undefined;
            self.arm(self.restoreBlob(&blob), self.raw);
        }
        try writer.writeAll("\x1b[?1049h\x1b[?25l");
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
    /// modes are on, then `restore_tail` (show cursor + leave alt-screen).
    /// Same bytes `writeRestore` emits on the normal path, packed into `buf`.
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
    /// disable input modes, then show cursor and leave the alt-screen.
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
