//! App: the static/live frame loop (ADR-0013 step 3), in two modes (ADR-0015).
//!
//! Owns everything the demo used to hand-roll: the frame arena, the
//! double-buffered surfaces, reserving the live region's rows, parking the
//! cursor at the region's top-left (the diff renderer's addressing
//! contract), and cursor hide/restore.
//!
//! The default is `hybrid`: a static stream (`emit`) flowing into scrollback
//! with a live region (`frame`) pinned above it, sharing the screen. Opting
//! into `full_screen` (ADR-0015) takes the screen over via the alternate-screen
//! buffer, grants the frame the whole viewport, owns raw mode for the session,
//! and reads input through `nextEvent` — `emit` is unavailable there (no
//! scrollback). The measure/render/diff core is identical between the two;
//! full-screen is a mode, not a fork.
//!
//! The two verbs:
//!
//! - `emit` — static output. Erases the live region, prints above it (into
//!   what becomes scrollback), and repaints the region below. Line-oriented:
//!   a trailing newline is added if the format string lacks one. Streaming
//!   partial lines into the static stream is future work (it needs cursor
//!   column tracking across emits).
//! - `frame` — live output. Measures the node against the terminal (height
//!   clamped to the viewport, ADR-0013's clip rule), lays it out, paints the
//!   diff against the previous frame, and resets the frame arena.
//!
//! Build each frame's tree from `app.arena()`: allocations live until the
//! next `frame()` call consumes them, then the arena resets wholesale —
//! that's the immediate-mode contract.
//!
//! Cursor bookkeeping invariant: between calls, the cursor sits at column 0
//! of the live region's top row (or at the start of an empty line when no
//! region is painted). Callers must hand over the terminal at the start of a
//! line, and must not write to the App's writer directly while a live region
//! is up — that's what `emit` is for.

const std = @import("std");
const theme = @import("theme");
const terminal = @import("terminal");
const surface_mod = @import("surface.zig");
const node_mod = @import("node.zig");
const diff_mod = @import("diff.zig");

const Surface = surface_mod.Surface;
const Node = node_mod.Node;
const Size = node_mod.Size;
const Limits = node_mod.Limits;
const RenderCtx = node_mod.RenderCtx;

/// An input event surfaced by `nextEvent` in full-screen mode: a key press, a
/// terminal resize, or (when enabled) a mouse or focus event (re-exported from
/// `terminal`). Bracketed paste joins here when it lands (ADR-0015 deferred).
pub const Event = terminal.Event;

// Full-screen takeover/restore escape sequences. The `*_on`/`*_off` pairs are
// DECSET enable/disable for the opt-in input modes; `restore_tail` shows the
// cursor and leaves the alt-screen. Restore order is the reverse of enter:
// disable input modes, then cursor, then alt-screen.
const mouse_on = "\x1b[?1002h\x1b[?1006h"; // button+drag tracking, SGR encoding
const mouse_off = "\x1b[?1002l\x1b[?1006l";
const focus_on = "\x1b[?1004h";
const focus_off = "\x1b[?1004l";
const paste_on = "\x1b[?2004h"; // bracketed paste
const paste_off = "\x1b[?2004l";
const restore_tail = "\x1b[?25h\x1b[?1049l";

pub const App = struct {
    /// How the App shares the terminal (ADR-0015).
    ///
    /// - `hybrid` (default, ADR-0013): a static stream flowing into scrollback
    ///   with a live region pinned above it. `emit` + `frame`, shared screen.
    /// - `full_screen`: takes the screen over via the alternate-screen buffer
    ///   (the shell and its scrollback are saved on enter, restored on exit),
    ///   owns raw mode for the session, and reads input through `nextEvent`.
    ///   The static stream goes unused — `emit` is an error — and the frame is
    ///   granted the whole viewport. The layout/measure/render/diff core is
    ///   identical; full-screen is a mode, not a fork.
    pub const Mode = enum { hybrid, full_screen };

    pub const Options = struct {
        capability: theme.TerminalCapability = .ansi_16,
        /// Chooses border/ellipsis glyphs (`terminal.unicodeSupported`).
        unicode: bool = true,
        /// Wrap paints in synchronized output (DECSET 2026).
        sync: bool = true,
        /// Fixed terminal size (tests, non-TTY output). `null` polls the
        /// real terminal on every frame, which is what makes the live
        /// region re-layout on resize.
        term_size: ?Size = null,
        /// Whether the output is a live terminal (callers pass
        /// `terminal.isStdoutTty()`). When false — piped to a file, CI —
        /// the App degrades to plain line output: `frame` is a no-op,
        /// `emit` prints without escapes or retention, the cursor is never
        /// touched. A `full_screen` App on a non-TTY is an error at `init` —
        /// a TUI into a pipe is meaningless.
        interactive: bool = true,
        /// Stdin reader for full-screen input, wired by `initFullScreen` (the
        /// App owns raw mode and drives `nextEvent`). Unused in hybrid, where
        /// input ownership stays with the caller (e.g. `prompts`).
        stdin: ?*std.Io.Reader = null,
        /// Report mouse press/release/drag as `Event.mouse` (full-screen only).
        /// Off by default — mouse reporting overrides the terminal's own text
        /// selection, so it's opt-in.
        mouse: bool = false,
        /// Report window focus in/out as `Event.focus` (full-screen only).
        focus: bool = false,
        /// Deliver bracketed paste as `Event.paste` (full-screen only). Off by
        /// default; the borrowed slice is valid until the next `nextEvent`.
        paste: bool = false,
        /// Cap on a single paste's buffered bytes — a pathological multi-MB
        /// paste is truncated to this, not an OOM. Only meaningful with `paste`.
        paste_max: usize = 5 << 20, // 5 MiB
    };

    /// The caller-facing subset of `Options` for `context.ui()` /
    /// `context.uiFullScreen()`: the environment-derived fields (capability,
    /// unicode, interactive, stdin) are wired by the context, so this is the
    /// choice left to the app author.
    pub const SessionOptions = struct {
        /// Wrap paints in synchronized output (DECSET 2026).
        sync: bool = true,
        /// Report mouse events (full-screen only; see `Options.mouse`).
        mouse: bool = false,
        /// Report focus in/out (full-screen only; see `Options.focus`).
        focus: bool = false,
        /// Deliver bracketed paste as `Event.paste` (see `Options.paste`).
        paste: bool = false,
        /// Cap on a single paste's buffered bytes (see `Options.paste_max`).
        paste_max: usize = 5 << 20, // 5 MiB
    };

    /// A static block kept for the resize tail repaint (ADR-0013 resize
    /// tier 2): the SOURCE text, not rendered cells, so it can rewrap at a
    /// new width. `rows` is what it occupies at the width it was last
    /// printed at (terminal character-wrapping, not word-wrapping).
    const StaticBlock = struct {
        text: []u8,
        rows: u16,
    };

    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    options: Options,
    /// How the App shares the terminal — set by the constructor (`init` →
    /// hybrid, `initFullScreen` → full-screen), not a caller option, so the
    /// full-screen path (and its compile-time panic-hook requirement) rides on
    /// a distinct constructor rather than a runtime flag.
    mode: Mode = .hybrid,

    frame_arena: std.heap.ArenaAllocator,
    /// What the terminal currently shows (diff source) / the paint target.
    front: Surface,
    back: Surface,
    /// Rows currently reserved on screen for the live region.
    live_rows: u16 = 0,
    /// Whether `front` matches what's on screen (false forces a full paint).
    front_valid: bool = false,
    /// Whether we've taken over the terminal (cursor hidden) yet.
    started: bool = false,
    /// Recently emitted static blocks that may still be visible above the
    /// live region — the reflowable tail. Bounded to about a screenful by
    /// `evictRetained`; oldest first.
    retained: std.ArrayList(StaticBlock) = .empty,
    /// Terminal width at the last frame/emit; a change triggers the tail
    /// repaint.
    last_width: ?u16 = null,
    /// Where `showCursorAt` placed the real cursor within the live region
    /// (region-relative), if anywhere. Any frame/emit/clear un-places it.
    placed: ?CursorPos = null,
    /// Guard for idempotent deinit (finish paths may close the App early).
    deinited: bool = false,
    /// Session-owned raw mode, in full-screen only (the App reads input via
    /// `nextEvent`). `null` in hybrid, where input ownership stays external.
    raw: ?terminal.RawMode = null,
    /// Resize watcher backing `nextEvent`, full-screen only.
    watcher: ?terminal.ResizeWatcher = null,
    /// Reused accumulator for bracketed-paste content (full-screen, `paste`
    /// enabled). `Event.paste` borrows its bytes until the next `nextEvent`.
    paste_buf: std.ArrayList(u8) = .empty,

    pub const CursorPos = struct { x: u16, y: u16 };

    /// A hybrid App (ADR-0013): a static stream flowing into scrollback with a
    /// live region pinned above it. Shares the screen, stays in cooked mode,
    /// input ownership is the caller's.
    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !App {
        return .{
            .writer = writer,
            .gpa = gpa,
            .options = options,
            .mode = .hybrid,
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
            .front = try Surface.init(gpa, 0, 0),
            .back = try Surface.init(gpa, 0, 0),
        };
    }

    /// A full-screen App (ADR-0015): takes the screen over via the
    /// alternate-screen buffer, owns raw mode for the session, and reads input
    /// through `nextEvent`. Pass a stdin reader in `options.stdin`.
    ///
    /// A distinct constructor, not a `mode` option, for one reason: full-screen
    /// hands the terminal to the alt-screen in raw mode, so a panic (which does
    /// not run `defer app.deinit()`) would strand it — the app MUST install the
    /// restore panic hook. Because `mode` is comptime-known here (unlike a
    /// runtime flag), `assertPanicInstalled` can turn a forgotten hook into a
    /// build error instead of a wedged terminal, and only for full-screen apps.
    pub fn initFullScreen(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !App {
        comptime assertPanicInstalled();
        var self = try init(gpa, writer, options);
        self.mode = .full_screen;
        errdefer {
            self.front.deinit();
            self.back.deinit();
            self.frame_arena.deinit();
        }
        try self.enterFullScreen();
        return self;
    }

    /// Compile-time guard on `initFullScreen`: full-screen needs a panic handler
    /// (see the constructor). Zig resolves the handler as `@import("root").panic`
    /// — a root-module decl an imported module can't provide — so this checks the
    /// root source file for it. Hybrid carries no such requirement (cooked mode,
    /// cursor-only), which is why the check lives here and not in `init`.
    fn assertPanicInstalled() void {
        // `zig test` roots at the test runner (no panic hook) and constructs
        // full-screen Apps only headlessly (fixed `term_size`, no real terminal
        // to strand), so the requirement doesn't apply there.
        if (@import("builtin").is_test) return;
        if (!@hasDecl(@import("root"), "panic")) @compileError(
            "full-screen ui.App requires a panic handler, so a panic can't strand the " ++
                "terminal in the alt-screen. Add to your root source file (main.zig):\n\n" ++
                "    pub const panic = zcli.ui.panic;\n\n" ++
                "(standalone ui users: `pub const panic = ui.panic;`)",
        );
    }

    /// Panic handler that restores the terminal (replays the `terminal.guard`
    /// blob) *before* the default handler prints — so the stack trace lands on
    /// the shell's real screen, not the discarded alt-screen. Install in your
    /// root source file: `pub const panic = zcli.ui.panic;`. Required for
    /// full-screen (enforced by `initFullScreen`); optional but recommended for
    /// hybrid, where it re-shows the hidden cursor.
    pub const panic = std.debug.FullPanic(struct {
        fn call(msg: []const u8, first_trace_addr: ?usize) noreturn {
            terminal.guard.restore();
            std.debug.defaultPanic(msg, first_trace_addr);
        }
    }.call);

    /// Take the terminal over: enable session raw mode, switch to the
    /// alternate-screen buffer (saving the shell's screen + scrollback), hide
    /// the cursor, and anchor at the origin — `?1049h` clears the alt buffer
    /// but carries the cursor position over from the main screen, so the diff
    /// renderer's "cursor parked at the region's top-left" contract must be
    /// established explicitly before the first paint (ADR-0015 choice 2).
    fn enterFullScreen(self: *App) !void {
        if (!self.options.interactive) return error.NotATerminal;
        // Restore terminal state if any step below fails — same bytes/order as
        // deinit, so a half-entered session never strands the terminal.
        errdefer {
            terminal.guard.disarm();
            self.writeRestore();
            self.writer.flush() catch {};
            if (self.watcher) |*w| w.deinit();
            if (self.raw) |r| r.disable();
        }
        // A fixed `term_size` is the headless-harness path (tests): there is
        // no real terminal to put in raw mode, watch for resizes, or arm the
        // restore guard against (tests must not grab process signals). Still
        // emit the alt-screen takeover so the byte stream is exercised; live
        // input (`nextEvent`) is a real-terminal-only affair.
        if (self.options.term_size == null) {
            self.raw = try terminal.enableRawMode(std.Io.File.stdin().handle);
            self.watcher = terminal.ResizeWatcher.init();
            // Register the full restore (disable input modes → show cursor →
            // leave alt-screen → restore termios) for the signal/panic paths
            // that skip deinit. Armed before the takeover bytes go out so a
            // signal in the gap still restores; disabling modes / leaving an
            // alt-screen we haven't entered yet is a harmless no-op.
            var blob: [64]u8 = undefined;
            terminal.guard.arm(std.Io.File.stdout().handle, self.restoreBlob(&blob), self.raw);
        }
        self.started = true; // cursor hidden, terminal owned
        try self.writer.writeAll("\x1b[?1049h\x1b[?25l");
        if (self.options.mouse) try self.writer.writeAll(mouse_on);
        if (self.options.focus) try self.writer.writeAll(focus_on);
        if (self.options.paste) try self.writer.writeAll(paste_on);
        try self.anchor();
        try self.writer.flush();
    }

    /// The restore blob for the signal/panic guard: disable whichever input
    /// modes are on, then `restore_tail` (show cursor + leave alt-screen). Same
    /// bytes `writeRestore` emits on the normal path, packed into `buf`.
    fn restoreBlob(self: *App, buf: []u8) []const u8 {
        var n: usize = 0;
        const put = struct {
            fn f(dst: []u8, at: *usize, s: []const u8) void {
                @memcpy(dst[at.*..][0..s.len], s);
                at.* += s.len;
            }
        }.f;
        if (self.options.mouse) put(buf, &n, mouse_off);
        if (self.options.focus) put(buf, &n, focus_off);
        if (self.options.paste) put(buf, &n, paste_off);
        put(buf, &n, restore_tail);
        return buf[0..n];
    }

    /// Emit the restore sequence to the writer (normal teardown / errdefer):
    /// disable input modes, then show cursor and leave the alt-screen.
    fn writeRestore(self: *App) void {
        if (self.options.mouse) self.writer.writeAll(mouse_off) catch {};
        if (self.options.focus) self.writer.writeAll(focus_off) catch {};
        if (self.options.paste) self.writer.writeAll(paste_off) catch {};
        self.writer.writeAll(restore_tail) catch {};
    }

    /// Park the cursor at the screen origin (the diff renderer's addressing
    /// anchor in full-screen). One relative sequence — CR plus a
    /// viewport-height CUU that clamps at the top row — so the renderer stays
    /// CUP-free and shared byte-for-byte with the hybrid. Used on entry and
    /// after a resize, the two moments the parked position is invalidated.
    fn anchor(self: *App) !void {
        const h = self.termSize().h;
        try self.writer.writeByte('\r');
        if (h > 0) try self.writer.print("\x1b[{d}A", .{h});
    }

    /// Restores the terminal (cursor shown, parked on a fresh line below the
    /// live region — the final frame stays visible, flowing into scrollback)
    /// and frees everything. Idempotent.
    pub fn deinit(self: *App) void {
        if (self.deinited) return;
        self.deinited = true;
        // Clean teardown owns the restore from here — disarm so a racing signal
        // doesn't also replay, and to put the old signal dispositions back.
        // Idempotent: a no-op on the headless path that never armed.
        if (self.started) terminal.guard.disarm();
        if (self.mode == .full_screen) {
            // Restore in strict reverse of enter (ADR-0015 choice 5): disable
            // input modes → show cursor → leave alt-screen (restores the shell's
            // screen and scrollback; the final frame is discarded by design) →
            // disable raw mode. The alt-screen leave must precede the raw-mode
            // restore so its bytes still go out while we own the terminal.
            if (self.started) self.writeRestore();
            self.writer.flush() catch {};
            if (self.watcher) |*w| w.deinit();
            if (self.raw) |r| r.disable();
        } else if (self.started) {
            self.unplace() catch {};
            if (self.live_rows > 1) {
                self.writer.print("\x1b[{d}B", .{self.live_rows - 1}) catch {};
            }
            if (self.live_rows > 0) self.writer.writeAll("\r\n") catch {};
            self.writer.writeAll("\x1b[?25h") catch {};
            self.writer.flush() catch {};
        } else {
            self.writer.flush() catch {};
        }
        for (self.retained.items) |b| self.gpa.free(b.text);
        self.retained.deinit(self.gpa);
        self.paste_buf.deinit(self.gpa);
        self.front.deinit();
        self.back.deinit();
        self.frame_arena.deinit();
    }

    /// Show the real terminal cursor at (x, y) in live-region coordinates —
    /// a line editor's insertion point. Cleared by the next frame, emit, or
    /// clear (the region invariant parks the cursor at the top-left between
    /// operations; this is the one sanctioned excursion). No-op without an
    /// interactive live region.
    pub fn showCursorAt(self: *App, x: u16, y: u16) !void {
        if (!self.options.interactive or self.live_rows == 0) return;
        try self.unplace();
        const pos = CursorPos{
            .x = @min(x, self.front.width -| 1),
            .y = @min(y, self.live_rows - 1),
        };
        if (pos.y > 0) try self.writer.print("\x1b[{d}B", .{pos.y});
        try self.writer.writeByte('\r');
        if (pos.x > 0) try self.writer.print("\x1b[{d}C", .{pos.x});
        try self.writer.writeAll("\x1b[?25h");
        try self.writer.flush();
        self.placed = pos;
    }

    /// Hide the placed cursor and return to the region's top-left, restoring
    /// the parking invariant every other operation assumes.
    fn unplace(self: *App) !void {
        const pos = self.placed orelse return;
        self.placed = null;
        try self.writer.writeAll("\x1b[?25l\r");
        if (pos.y > 0) try self.writer.print("\x1b[{d}A", .{pos.y});
    }

    /// The frame arena: build each frame's node tree from this. Valid until
    /// the `frame()` call that consumes the tree returns.
    pub fn arena(self: *App) std.mem.Allocator {
        return self.frame_arena.allocator();
    }

    /// Static output: printed above the live region, flows into scrollback,
    /// never repainted in place. Line-oriented (see module docs). The block
    /// is retained in source form while it may still be visible, so a width
    /// resize can reflow the visible tail (ADR-0013 resize tier 2).
    ///
    /// Interactive output terminates lines with CRLF: prompts run the
    /// terminal in raw mode, where a bare `\n` moves down without returning
    /// the column (no ONLCR post-processing), and CRLF is harmless in
    /// cooked mode. Piped output keeps plain `\n`.
    pub fn emit(self: *App, comptime fmt: []const u8, args: anytype) !void {
        // Full-screen owns the whole viewport — there is no scrollback for a
        // static line to flow into (ADR-0015). Code that wants both a
        // scrollback log and a live frame is, by definition, the hybrid.
        if (self.mode == .full_screen) return error.EmitInFullScreen;
        const base = comptime std.mem.trimEnd(u8, fmt, "\r\n");
        if (!self.options.interactive) {
            // Plain line output: no live region exists, nothing to retain.
            try self.writer.print(base ++ "\n", args);
            try self.writer.flush();
            return;
        }
        const ts = self.termSize();
        self.last_width = ts.w;

        const text = try std.fmt.allocPrint(self.gpa, base ++ "\r\n", args);
        errdefer self.gpa.free(text);

        try self.unplace();
        const had_live = self.live_rows > 0;
        try self.clearLive();
        try self.writer.writeAll(text);
        if (had_live) try self.repaintLive();
        try self.writer.flush();

        // Retain last: eviction may free the block we just printed.
        try self.retained.append(self.gpa, .{
            .text = text,
            .rows = textRows(text, ts.w),
        });
        _ = self.evictRetained(ts.h -| self.live_rows);
    }

    /// Live output: measure, lay out, paint the diff. The tree (built from
    /// `self.arena()`) is consumed — the arena resets when this returns.
    /// A no-op when the output is not interactive.
    pub fn frame(self: *App, node: Node) !void {
        defer _ = self.frame_arena.reset(.retain_capacity);
        if (!self.options.interactive) return;
        if (self.mode == .full_screen) return self.frameFullScreen(node);
        try self.unplace();

        const ts = self.termSize();
        const width_changed = self.last_width != null and self.last_width.? != ts.w;
        self.last_width = ts.w;
        // The viewport clamp: a live region taller than the terminal cannot
        // exist (ADR-0013 — scrollback corruption made impossible, not
        // handled). One row is held back so the region plus the static
        // line above it fit without forcing a scroll on every repaint.
        const limits = Limits{ .max_w = ts.w, .max_h = ts.h -| 1 };
        const rctx = RenderCtx{
            .allocator = self.frame_arena.allocator(),
            .unicode = self.options.unicode,
        };

        var size = node_mod.measure(&rctx, &node, limits);
        // A root with `.fill` stretches to the terminal edge. Full-screen
        // (ADR-0015) reuses the same measure/render, but grants the whole
        // viewport and takes the alt-screen — see `frameFullScreen`.
        if (node.width == .fill) size.w = limits.max_w;
        if (node.height == .fill) size.h = limits.max_h;

        if (size.w == 0 or size.h == 0) {
            try self.clearLive();
            try self.writer.flush();
            return;
        }

        try self.start();

        if (size.w != self.back.width or size.h != self.back.height) {
            try self.back.resize(size.w, size.h);
            try self.front.resize(size.w, size.h);
            self.front_valid = false;
        }

        // Resize tier 2 (ADR-0013): on a width change, the visible static
        // tail is erased and reprinted reflowed at the new width, in the
        // same synchronized write as the live repaint. The paint's own sync
        // guard is suppressed — DECSET 2026 doesn't nest.
        const tail_repaint = width_changed and self.live_rows > 0;
        if (tail_repaint) {
            if (self.options.sync) try self.writer.writeAll("\x1b[?2026h");
            try self.repaintTail(ts, size.h);
        } else if (size.h != self.live_rows) {
            // Region height changed (or first frame): re-reserve from
            // scratch. Erasing rather than incrementally growing keeps the
            // bookkeeping trivial; the sync guard makes it flicker-free.
            try self.clearLive();
            try self.reserve(size.h);
        }

        self.back.clear();
        try node_mod.render(&rctx, &node, self.back.root());

        const prev: ?*const Surface = if (self.front_valid) &self.front else null;
        const renderer = diff_mod.Renderer{
            .capability = self.options.capability,
            .sync = self.options.sync and !tail_repaint,
        };
        try renderer.paint(self.writer, prev, &self.back);
        std.mem.swap(Surface, &self.front, &self.back);
        self.front_valid = true;
        if (tail_repaint and self.options.sync) try self.writer.writeAll("\x1b[?2026l");
        try self.writer.flush();
    }

    /// Full-screen frame (ADR-0015). The alt-screen buffer is ours end to
    /// end, so this is markedly simpler than the hybrid `frame`: no row
    /// reservation (the buffer starts blank), no scrollback seam, no tail
    /// reflow. The surface is always the whole viewport — the root is granted
    /// the full terminal rect (a `fill`×`fill` root is the norm; centering or
    /// margins are the root's own layout, via spacers/alignment) — and the
    /// diff renderer addresses it relative to the origin, where the cursor is
    /// parked between paints.
    ///
    /// Resize is just: re-anchor the parked cursor (the one piece of state the
    /// terminal silently invalidates) and force a full repaint. A viewport
    /// change already resizes the surface, which forces the repaint on its
    /// own; the re-anchor is the resize-specific step.
    fn frameFullScreen(self: *App, node: Node) !void {
        const ts = self.termSize();
        const size = Size{ .w = ts.w, .h = ts.h };
        if (size.w == 0 or size.h == 0) return;

        // A width or height change invalidates the parked cursor and the
        // surface both. Re-anchor, then let the surface-size mismatch below
        // force the full repaint.
        const resized = self.last_width != null and
            (self.last_width.? != ts.w or self.live_rows != ts.h);
        self.last_width = ts.w;
        if (resized) try self.anchor();

        const rctx = RenderCtx{
            .allocator = self.frame_arena.allocator(),
            .unicode = self.options.unicode,
        };

        if (size.w != self.back.width or size.h != self.back.height) {
            try self.back.resize(size.w, size.h);
            try self.front.resize(size.w, size.h);
            self.front_valid = false;
        }
        self.live_rows = size.h;

        self.back.clear();
        try node_mod.render(&rctx, &node, self.back.root());

        const prev: ?*const Surface = if (self.front_valid) &self.front else null;
        const renderer = diff_mod.Renderer{
            .capability = self.options.capability,
            .sync = self.options.sync,
        };
        try renderer.paint(self.writer, prev, &self.back);
        std.mem.swap(Surface, &self.front, &self.back);
        self.front_valid = true;
        try self.writer.flush();
    }

    /// Full-screen input (ADR-0015). Block for the next key or resize, or
    /// return `null` when `timeout_ms` elapses first — the timeout is what
    /// lets a loop repaint on a tick with no input (`nextEvent(250) orelse
    /// tick()`), no background thread. `null` blocks indefinitely.
    ///
    /// Flushes the App's writer before blocking: the frame just built must
    /// reach the terminal before we wait on the user (the flush-before-read
    /// discipline `prompts` learned, enforced here in one place). Ctrl-C
    /// arrives as an ordinary `.key` — raw mode cleared `ISIG` — so whether
    /// it quits, cancels, or is ignored is the caller's `update`.
    pub fn nextEvent(self: *App, timeout_ms: ?u32) !?Event {
        std.debug.assert(self.mode == .full_screen);
        const reader = self.options.stdin orelse return error.NoInput;
        // No watcher means the headless-harness path (`term_size` set): there
        // is no real terminal to read from.
        if (self.watcher == null) return error.NoInput;
        try self.writer.flush();
        // The paste sink borrows `paste_buf` (reused each call); the returned
        // `Event.paste` is valid only until the next `nextEvent`.
        const sink: ?terminal.PasteSink = if (self.options.paste) .{
            .buf = &self.paste_buf,
            .allocator = self.gpa,
            .max = self.options.paste_max,
        } else null;
        return terminal.readEventTimeout(
            reader,
            std.Io.File.stdin().handle,
            &self.watcher.?,
            timeout_ms,
            sink,
        );
    }

    /// `update`'s verdict: keep looping, or stop `run`.
    pub const Flow = enum { keep, quit };

    /// The full-screen driver (ADR-0015): own the `frame → nextEvent → update`
    /// loop so callers don't hand-roll it. Each pass renders `view(state)`,
    /// blocks for the next event, and routes it to `update`; loop until `update`
    /// returns `.quit`. Sugar over the explicit loop — state stays caller-owned
    /// and mutable (immediate mode), `view` should treat it as read-only.
    ///
    /// `tick_ms` drives a periodic refresh with no input (a `top`-style clock):
    /// the tick is delivered to `update` as a `null` event, and it is scheduled
    /// against a DEADLINE — a burst of keys shrinks the wait rather than
    /// resetting it, so input can't starve the tick. `null` disables ticking
    /// (block on input only — a form or menu). `io` is only the monotonic clock
    /// the deadline reads (`std.Io.Clock`). Full-screen only.
    pub fn run(
        self: *App,
        io: std.Io,
        state: anytype,
        tick_ms: ?u32,
        comptime view: fn (std.mem.Allocator, @TypeOf(state)) anyerror!Node,
        comptime update: fn (@TypeOf(state), ?Event) anyerror!Flow,
    ) !void {
        std.debug.assert(self.mode == .full_screen);
        const ns_per_ms = std.time.ns_per_ms;
        var next_tick: u64 = if (tick_ms) |ms| nowNs(io) + @as(u64, ms) * ns_per_ms else 0;

        while (true) {
            try self.frame(try view(self.arena(), state));

            // How long until the next tick — the remaining window, not a fresh
            // `tick_ms`, so early key wakeups can't push the tick out forever.
            var timeout: ?u32 = null;
            if (tick_ms) |ms| {
                const now = nowNs(io);
                if (now >= next_tick) {
                    if (try update(state, null) == .quit) return;
                    next_tick = nowNs(io) + @as(u64, ms) * ns_per_ms;
                    continue; // re-render, then re-arm the wait
                }
                timeout = @intCast((next_tick - now) / ns_per_ms);
            }

            const ev = try self.nextEvent(timeout) orelse {
                // Deadline reached with no input: a tick.
                if (try update(state, null) == .quit) return;
                if (tick_ms) |ms| next_tick = nowNs(io) + @as(u64, ms) * ns_per_ms;
                continue;
            };
            if (try update(state, ev) == .quit) return;
        }
    }

    /// Monotonic nanoseconds — the deadline source for `run`'s tick, via the
    /// `.awake` clock `progress` also animates against.
    fn nowNs(io: std.Io) u64 {
        return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
    }

    /// Erase the live region and leave nothing in its place — the ending
    /// for a widget whose result is an `emit`ted line (or no output at
    /// all), as opposed to `deinit`'s leave-the-final-frame-visible.
    pub fn clear(self: *App) !void {
        try self.unplace();
        try self.clearLive();
        try self.writer.flush();
    }

    // ------------------------------------------------------------------
    // Region bookkeeping. Invariant: cursor at column 0 of the region's
    // top row (or of an empty line when live_rows == 0).
    // ------------------------------------------------------------------

    /// Erase the live region (cursor-to-end-of-screen — the region is the
    /// bottom edge; everything below it is ours).
    fn clearLive(self: *App) !void {
        if (self.live_rows == 0) return;
        try self.writer.writeAll("\r\x1b[0J");
        self.live_rows = 0;
        self.front_valid = false;
    }

    /// Create `rows` rows starting at the cursor's line (scrolling as
    /// needed) and park at the region's top-left.
    fn reserve(self: *App, rows: u16) !void {
        std.debug.assert(self.live_rows == 0);
        try self.writer.writeByte('\r');
        var i: u16 = 1;
        // CRLF, not LF: under raw mode (prompts) there is no ONLCR
        // post-processing, and the explicit CR is harmless in cooked mode.
        while (i < rows) : (i += 1) try self.writer.writeAll("\r\n");
        if (rows > 1) try self.writer.print("\x1b[{d}A", .{rows - 1});
        self.live_rows = rows;
    }

    /// Re-reserve and fully repaint the last frame (after `emit` erased it).
    fn repaintLive(self: *App) !void {
        if (self.front.width == 0 or self.front.height == 0) return;
        try self.start();
        try self.reserve(self.front.height);
        const renderer = diff_mod.Renderer{
            .capability = self.options.capability,
            .sync = self.options.sync,
        };
        try renderer.paint(self.writer, null, &self.front);
        self.front_valid = true;
    }

    /// The width-resize repaint (ADR-0013 resize tier 2). The cursor sits at
    /// the live region's top; the retained tail sits directly above it. Move
    /// up over the tail's footprint (bottom-anchored, relative — CUU clamps
    /// at the viewport top exactly when the tail extends into scrollback),
    /// erase from there down, reprint the tail so the terminal rewraps it at
    /// the new width, and re-reserve the live region below.
    ///
    /// The erase covers the LARGER of the kept blocks' old footprint and
    /// their new one: a tail that unwraps (width grew) must not leave its
    /// old extra rows stale above the reprint. Content above that is never
    /// touched; deeper scrollback keeps its old wrap width — that seam is
    /// immutable by terminal authority.
    fn repaintTail(self: *App, ts: Size, live_h: u16) !void {
        // Old footprints, index-aligned with `retained` (frame arena — this
        // runs inside frame(), which resets it on return).
        const olds = try self.frame_arena.allocator().alloc(u16, self.retained.items.len);
        for (self.retained.items, olds) |*b, *old| {
            old.* = b.rows;
            b.rows = textRows(b.text, ts.w);
        }
        const dropped = self.evictRetained(ts.h -| live_h);

        var old_tail: u32 = 0;
        for (olds[dropped..]) |r| old_tail += r;
        var new_tail: u32 = 0;
        for (self.retained.items) |b| new_tail += b.rows;

        try self.writer.writeByte('\r');
        const up = @max(old_tail, new_tail);
        if (up > 0) try self.writer.print("\x1b[{d}A", .{up});
        try self.writer.writeAll("\x1b[0J");
        for (self.retained.items) |b| try self.writer.writeAll(b.text);
        self.live_rows = 0;
        self.front_valid = false;
        try self.reserve(live_h);
    }

    /// Drop retained blocks (oldest first) whose rows no longer fit in
    /// `budget` (the viewport rows above the live region) — they have
    /// scrolled beyond the viewport, where nothing can repaint them anyway.
    /// Returns how many were dropped.
    fn evictRetained(self: *App, budget: u32) usize {
        var total: u32 = 0;
        var keep_from = self.retained.items.len;
        var i = self.retained.items.len;
        while (i > 0) {
            i -= 1;
            const rows = self.retained.items[i].rows;
            if (total + rows > budget) break;
            total += rows;
            keep_from = i;
        }
        if (keep_from == 0) return 0;
        for (self.retained.items[0..keep_from]) |b| self.gpa.free(b.text);
        const kept = self.retained.items.len - keep_from;
        std.mem.copyForwards(
            StaticBlock,
            self.retained.items[0..kept],
            self.retained.items[keep_from..],
        );
        self.retained.shrinkRetainingCapacity(kept);
        return keep_from;
    }

    /// Rows `text` occupies at `width` — the terminal's own soft-wrapping
    /// (hard character wrap at the last column), NOT `terminal.wrap`'s word
    /// wrap: emit prints raw text and the terminal breaks the lines, so the
    /// bookkeeping must count the way the terminal counts. (Tabs would
    /// desync this — emit output is expected tab-free.)
    fn textRows(text: []const u8, width: u16) u16 {
        const w: u32 = @max(width, 1);
        const body = std.mem.trimEnd(u8, text, "\r\n");
        var rows: u32 = 0;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            const cols: u32 = @intCast(terminal.displayWidth(line));
            rows += @max(1, (cols + w - 1) / w);
        }
        return @intCast(@min(rows, std.math.maxInt(u16)));
    }

    /// Hybrid takeover: hide the cursor (the only process-global state hybrid
    /// touches). Arm the guard to re-show it on a signal/panic that skips
    /// deinit — the mode-agnostic restore, minus the alt-screen and termios
    /// full-screen also registers. Only on a real terminal (`term_size` null);
    /// the headless harness must not grab process signals.
    fn start(self: *App) !void {
        if (self.started) return;
        self.started = true;
        try self.writer.writeAll("\x1b[?25l");
        if (self.options.term_size == null)
            terminal.guard.arm(std.Io.File.stdout().handle, "\x1b[?25h", null);
    }

    fn termSize(self: *App) Size {
        if (self.options.term_size) |s| return s;
        const ws = terminal.getWindowSize(std.Io.File.stdout().handle) catch
            return .{ .w = 80, .h = 24 };
        return .{ .w = ws.col, .h = ws.row };
    }
};
