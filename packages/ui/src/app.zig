//! App: the static/live frame loop (ADR-0013 step 3), in two modes (ADR-0015).
//!
//! The App is the orchestrator over four owned components, each with one
//! responsibility:
//!
//! - `RenderCore` (render_core.zig) — the pure measure→paint→diff pipeline:
//!   double-buffered surfaces and the minimal-byte diff paint.
//! - `RegionCursor` (region_cursor.zig) — owns the cursor-parking invariant:
//!   between operations the real cursor sits at column 0 of the live
//!   region's top row (or at the start of an empty line when no region is
//!   painted). `place` is the one sanctioned excursion; every paint path
//!   parks first and asserts `isParked()` before handing bytes to the diff
//!   renderer. Callers must hand over the terminal at the start of a line,
//!   and must not write to the App's writer directly while a live region is
//!   up — that's what `emit` is for.
//! - `TerminalSession` (terminal_session.zig) — raw mode, the resize
//!   watcher, the signal/panic restore guard, and the full-screen
//!   enter/restore protocol: the only part that touches real process state.
//! - `HybridScrollback` (hybrid_scrollback.zig) — the retained static tail
//!   and its width-resize reflow (ADR-0013 resize tier 2).
//!
//! What remains here is the region bookkeeping (`live_rows`, reserve/clear)
//! and the mode orchestration.
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

const std = @import("std");
const theme = @import("theme");
const terminal = @import("terminal");
const surface_mod = @import("surface.zig");
const node_mod = @import("node.zig");
const diff_mod = @import("diff.zig");
const render_core_mod = @import("render_core.zig");
const region_cursor_mod = @import("region_cursor.zig");
const session_mod = @import("terminal_session.zig");
const scrollback_mod = @import("hybrid_scrollback.zig");

const Surface = surface_mod.Surface;
const Point = surface_mod.Point;
const Node = node_mod.Node;
const Size = node_mod.Size;
const Limits = node_mod.Limits;
const RenderCtx = node_mod.RenderCtx;
const RenderCore = render_core_mod.RenderCore;
const RegionCursor = region_cursor_mod.RegionCursor;
const TerminalSession = session_mod.TerminalSession;
const HybridScrollback = scrollback_mod.HybridScrollback;

/// An input event surfaced by `nextEvent` in full-screen mode: a key press, a
/// terminal resize, or (when enabled) a mouse or focus event (re-exported from
/// `terminal`). Bracketed paste joins here when it lands (ADR-0015 deferred).
pub const Event = terminal.Event;

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

    /// The app-author session knobs, shared as a single embedded core between
    /// `Options` (as `Options.session`) and `context.ui()` /
    /// `context.uiFullScreen()`. The environment-derived fields (capability,
    /// unicode, interactive, stdin) are wired by the context or the
    /// constructor; these are the choices left to the app author. Declared once
    /// here and embedded, so a new knob can't drift between the two structs.
    pub const SessionOptions = struct {
        /// Wrap paints in synchronized output (DECSET 2026).
        sync: bool = true,
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

    pub const Options = struct {
        capability: theme.TerminalCapability = .ansi_16,
        /// Chooses border/ellipsis glyphs (`terminal.unicodeSupported`).
        unicode: bool = true,
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
        /// The caller's raw mode, in hybrid only. Hybrid input ownership stays
        /// with the caller (e.g. a prompt enables raw mode itself), but the
        /// restore guard is armed here — the single arm/disarm site — so the
        /// caller hands its `RawMode` in and the guard replays `disable()` on a
        /// signal/panic that skips `deinit`. `null` leaves the guard's raw
        /// restore empty (the historical hybrid behaviour: cursor only).
        hybrid_raw: ?terminal.RawMode = null,
        /// The file handle `writer` targets — used to arm the restore guard
        /// (the signal/panic replay must hit the same tty the escapes went to)
        /// and to poll the terminal size. `null` means stdout. Callers whose
        /// writer is stderr (progress indicators) must pass stderr's handle,
        /// or a redirected stdout swallows the cursor restore (#385).
        out_handle: ?std.Io.File.Handle = null,
        /// The app-author session knobs (sync + the full-screen input modes),
        /// shared with `context.ui()` / `context.uiFullScreen()`.
        session: SessionOptions = .{},
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
    /// The measure→paint→diff pipeline: double-buffered surfaces + validity.
    core: RenderCore,
    /// Owner of the cursor-parking invariant (see module docs).
    cursor: RegionCursor = .{},
    /// Process-global terminal state: raw mode, resize watcher, restore guard.
    session: TerminalSession,
    /// The retained static tail and its width-resize reflow (hybrid only).
    scrollback: HybridScrollback,
    /// Rows currently reserved on screen for the live region.
    live_rows: u16 = 0,
    /// Whether we've taken over the terminal (cursor hidden) yet.
    started: bool = false,
    /// Terminal width at the last frame/emit; a change triggers the tail
    /// repaint.
    last_width: ?u16 = null,
    /// Guard for idempotent deinit (finish paths may close the App early).
    deinited: bool = false,
    /// Reused accumulator for bracketed-paste content (full-screen, `paste`
    /// enabled). `Event.paste` borrows its bytes until the next `nextEvent`.
    paste_buf: std.ArrayList(u8) = .empty,

    pub const CursorPos = RegionCursor.Pos;

    /// A hybrid App (ADR-0013): a static stream flowing into scrollback with a
    /// live region pinned above it. Shares the screen, stays in cooked mode,
    /// input ownership is the caller's.
    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !App {
        comptime assertPanicInstalled();
        var self: App = .{
            .writer = writer,
            .gpa = gpa,
            .options = options,
            .mode = .hybrid,
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
            .core = try RenderCore.init(gpa),
            .session = .{
                .out_handle = options.out_handle orelse std.Io.File.stdout().handle,
                .modes = .{
                    .mouse = options.session.mouse,
                    .focus = options.session.focus,
                    .paste = options.session.paste,
                },
            },
            .scrollback = HybridScrollback.init(gpa),
        };
        // Arm the restore guard the moment we hold the caller's raw mode: in
        // hybrid the caller enables raw mode *before* constructing the App (a
        // prompt owns its input), so a signal in the gap before the first frame
        // would otherwise strand the terminal raw (issue #322). Only on a real
        // terminal (`term_size` null); `start` re-arms with the cursor-show blob
        // once it hides the cursor. The blob is empty here — nothing on screen to
        // undo yet, only the termios carried in `hybrid_raw`.
        if (options.term_size == null and options.hybrid_raw != null) {
            self.session.arm("", options.hybrid_raw);
        }
        return self;
    }

    /// A full-screen App (ADR-0015): takes the screen over via the
    /// alternate-screen buffer, owns raw mode for the session, and reads input
    /// through `nextEvent`. Pass a stdin reader in `options.stdin`.
    ///
    /// A distinct constructor, not a `mode` option, because full-screen hands the
    /// terminal to the alt-screen in raw mode and drives input itself. The panic
    /// hook a panic needs to un-strand the terminal is required for every App and
    /// enforced in `init` (see `assertPanicInstalled`); full-screen just raises
    /// the stakes — a wedged alt-screen needs `reset`, not merely a lost cursor.
    pub fn initFullScreen(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !App {
        var self = try init(gpa, writer, options);
        self.mode = .full_screen;
        errdefer {
            self.core.deinit();
            self.frame_arena.deinit();
        }
        try self.enterFullScreen();
        return self;
    }

    /// Compile-time guard on App construction (`init`, so both modes): an App
    /// takes over process-global terminal state a panic must undo — the
    /// alt-screen + raw mode in full-screen, raw mode + a hidden cursor in hybrid
    /// (the caller hands its raw mode in via `options.hybrid_raw`). A panic runs
    /// no `defer`, so only `ui.panic` restores it. Zig resolves the handler as
    /// `@import("root").panic` — a root-module decl an imported module can't
    /// provide — so this checks the root source file for it.
    ///
    /// This can only check that a `panic` decl *exists*, not that it restores
    /// the terminal (its identity is unknowable at comptime): a root `panic`
    /// that doesn't call `terminal.guard.restore()` (directly, or by delegating
    /// to `ui.panic`) satisfies the check yet still strands the terminal on a
    /// panic. The error text spells that out so a hand-rolled handler doesn't
    /// silently reopen the hole.
    fn assertPanicInstalled() void {
        // `zig test` roots at the test runner (no panic hook) and builds Apps
        // only headlessly (fixed `term_size`, no real terminal to strand), so
        // the requirement doesn't apply there.
        if (@import("builtin").is_test) return;
        if (!@hasDecl(@import("root"), "panic")) @compileError(
            "ui.App requires a panic handler, so a panic can't strand the terminal " ++
                "(the alt-screen in full-screen; raw mode with a hidden cursor in hybrid — " ++
                "every prompt and progress indicator). Add to your root source file (main.zig):\n\n" ++
                "    pub const panic = zcli.ui.panic;\n\n" ++
                "(standalone ui users: `pub const panic = ui.panic;`)\n\n" ++
                "A custom handler is only safe if it calls `terminal.guard.restore()` " ++
                "before it aborts (`ui.panic` does this first, then delegates to the " ++
                "default handler) — this check can't verify that, only that some " ++
                "`panic` decl exists.",
        );
    }

    /// Panic handler that restores the terminal (replays the `terminal.guard`
    /// blob) *before* the default handler prints — so the stack trace lands on
    /// the shell's real screen, not the discarded alt-screen. Install in your
    /// root source file: `pub const panic = zcli.ui.panic;`. Required for every
    /// `ui.App` (enforced at construction by `assertPanicInstalled`): full-screen
    /// leaves the alt-screen; hybrid re-shows the hidden cursor and restores the
    /// caller's raw mode.
    pub const panic = std.debug.FullPanic(struct {
        fn call(msg: []const u8, first_trace_addr: ?usize) noreturn {
            terminal.guard.restore();
            std.debug.defaultPanic(msg, first_trace_addr);
        }
    }.call);

    /// Take the terminal over (ADR-0015): the session enables raw mode,
    /// starts the resize watcher, arms the guard, and writes the takeover
    /// bytes; then the parked-cursor invariant is established explicitly at
    /// the origin — `?1049h` clears the alt buffer but carries the cursor
    /// position over from the main screen (ADR-0015 choice 2).
    fn enterFullScreen(self: *App) !void {
        if (!self.options.interactive) return error.NotATerminal;
        // Restore terminal state if any step below fails — same bytes/order as
        // deinit, so a half-entered session never strands the terminal.
        errdefer self.session.abortEnter(self.writer);
        self.started = true; // cursor hidden, terminal owned
        // A fixed `term_size` is the headless-harness path (tests): there is
        // no real terminal to put in raw mode, watch for resizes, or arm the
        // restore guard against (tests must not grab process signals). The
        // alt-screen takeover bytes still go out so the stream is exercised;
        // live input (`nextEvent`) is a real-terminal-only affair.
        try self.session.takeover(self.writer, self.options.term_size != null);
        try self.cursor.anchor(self.writer, self.termSize().h);
        try self.writer.flush();
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
        self.session.disarm();
        if (self.mode == .full_screen) {
            // Restore in strict reverse of enter (ADR-0015 choice 5): disable
            // input modes → show cursor → leave alt-screen (restores the shell's
            // screen and scrollback; the final frame is discarded by design) →
            // disable raw mode. The alt-screen leave must precede the raw-mode
            // restore so its bytes still go out while we own the terminal.
            if (self.started) self.session.writeRestore(self.writer);
            self.writer.flush() catch {};
            self.session.release();
        } else if (self.started) {
            self.cursor.park(self.writer) catch {};
            if (self.live_rows > 1) {
                self.writer.print("\x1b[{d}B", .{self.live_rows - 1}) catch {};
            }
            if (self.live_rows > 0) self.writer.writeAll("\r\n") catch {};
            self.writer.writeAll("\x1b[?25h") catch {};
            self.writer.flush() catch {};
        } else {
            self.writer.flush() catch {};
        }
        self.scrollback.deinit();
        self.paste_buf.deinit(self.gpa);
        self.core.deinit();
        self.frame_arena.deinit();
    }

    /// Show the real terminal cursor at (x, y) in live-region coordinates —
    /// a line editor's insertion point. Cleared by the next frame, emit, or
    /// clear (the region invariant parks the cursor at the top-left between
    /// operations; `RegionCursor.place` is the one sanctioned excursion).
    /// No-op without an interactive live region.
    pub fn showCursorAt(self: *App, x: u16, y: u16) !void {
        if (!self.options.interactive or self.live_rows == 0) return;
        try self.cursor.place(self.writer, .{
            .x = @min(x, self.core.front.width -| 1),
            .y = @min(y, self.live_rows - 1),
        });
        try self.writer.flush();
    }

    /// Place the real terminal cursor at an absolute screen cell, or hide it
    /// (`null`) — the full-screen entry point for a focused text field's caret
    /// (ADR-0019). In full-screen the surface fills the viewport from the origin,
    /// so a widget's reported cell (`TextInput`'s `cursor_out`) is already a
    /// screen coordinate. Call it after `frame`, before blocking on input — the
    /// natural home is `run`'s post-frame hook. `frameFullScreen` returns the
    /// cursor to the origin before the next diff.
    pub fn cursorAt(self: *App, p: ?Point) !void {
        if (p) |pt| {
            try self.showCursorAt(pt.x, pt.y);
        } else {
            try self.cursor.park(self.writer);
            try self.writer.flush();
        }
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

        try self.cursor.park(self.writer);
        const had_live = self.live_rows > 0;
        try self.clearLive();
        try self.writer.writeAll(text);
        if (had_live) try self.repaintLive();
        try self.writer.flush();

        try self.scrollback.retain(text, ts.w, ts.h -| self.live_rows);
    }

    /// Live output: measure, lay out, paint the diff. The tree (built from
    /// `self.arena()`) is consumed — the arena resets when this returns.
    /// A no-op when the output is not interactive.
    pub fn frame(self: *App, node: Node) !void {
        defer _ = self.frame_arena.reset(.retain_capacity);
        if (!self.options.interactive) return;
        if (self.mode == .full_screen) return self.frameFullScreen(node);
        try self.cursor.park(self.writer);

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
        try self.core.setSize(size.w, size.h);

        // Resize tier 2 (ADR-0013): on a width change, the visible static
        // tail is erased and reprinted reflowed at the new width, in the
        // same synchronized write as the live repaint. The paint's own sync
        // guard is suppressed — DECSET 2026 doesn't nest.
        const tail_repaint = width_changed and self.live_rows > 0;
        if (tail_repaint) {
            if (self.options.session.sync) try self.writer.writeAll("\x1b[?2026h");
            try self.scrollback.reflow(
                self.writer,
                self.frame_arena.allocator(),
                ts.w,
                ts.h -| size.h,
            );
            self.live_rows = 0;
            self.core.invalidate();
            try self.reserve(size.h);
        } else if (size.h != self.live_rows) {
            // Region height changed (or first frame): re-reserve from
            // scratch. Erasing rather than incrementally growing keeps the
            // bookkeeping trivial; the sync guard makes it flicker-free.
            try self.clearLive();
            try self.reserve(size.h);
        }

        // The diff renderer addresses everything relative to the park —
        // the invariant `RegionCursor` owns, checked before every paint.
        std.debug.assert(self.cursor.isParked());
        const renderer = diff_mod.Renderer{
            .capability = self.options.capability,
            .sync = self.options.session.sync and !tail_repaint,
        };
        try self.core.frame(self.writer, &rctx, &node, renderer);
        if (tail_repaint and self.options.session.sync) try self.writer.writeAll("\x1b[?2026l");
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
        // A hardware cursor placed after the last frame (`cursorAt`) sits away
        // from the origin the diff renderer addresses relative to — return it
        // before painting, mirroring the hybrid `frame`.
        try self.cursor.park(self.writer);

        const ts = self.termSize();
        const size = Size{ .w = ts.w, .h = ts.h };
        if (size.w == 0 or size.h == 0) return;

        // A width or height change invalidates the parked cursor and the
        // surface both. Re-anchor, then let the surface-size mismatch below
        // force the full repaint.
        const resized = self.last_width != null and
            (self.last_width.? != ts.w or self.live_rows != ts.h);
        self.last_width = ts.w;
        if (resized) try self.cursor.anchor(self.writer, ts.h);

        const rctx = RenderCtx{
            .allocator = self.frame_arena.allocator(),
            .unicode = self.options.unicode,
        };

        try self.core.setSize(size.w, size.h);
        self.live_rows = size.h;

        std.debug.assert(self.cursor.isParked());
        const renderer = diff_mod.Renderer{
            .capability = self.options.capability,
            .sync = self.options.session.sync,
        };
        try self.core.frame(self.writer, &rctx, &node, renderer);
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
        if (self.session.watcher == null) return error.NoInput;
        try self.writer.flush();
        // The paste sink borrows `paste_buf` (reused each call); the returned
        // `Event.paste` is valid only until the next `nextEvent`.
        const sink: ?terminal.PasteSink = if (self.options.session.paste) .{
            .buf = &self.paste_buf,
            .allocator = self.gpa,
            .max = self.options.session.paste_max,
        } else null;
        return terminal.readEventTimeout(
            reader,
            std.Io.File.stdin().handle,
            &self.session.watcher.?,
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
    ///
    /// `after_frame` (optional) runs after each paint, just before blocking on
    /// input — the post-frame hook for work that depends on the rendered layout.
    /// Its home use is the hardware cursor: place the focused field's caret with
    /// `app.cursorAt(...)` (ADR-0019), reading a `Point` the field reported into
    /// caller state during render. It receives the App and state; keep it to
    /// terminal side effects (don't re-enter `frame`). Pass `null` for none.
    pub fn run(
        self: *App,
        io: std.Io,
        state: anytype,
        tick_ms: ?u32,
        comptime view: fn (std.mem.Allocator, @TypeOf(state)) anyerror!Node,
        comptime update: fn (@TypeOf(state), ?Event) anyerror!Flow,
        comptime after_frame: ?fn (*App, @TypeOf(state)) anyerror!void,
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

            // Post-frame hook, right before we block: the frame is painted and
            // its layout (e.g. a caret position) is settled.
            if (after_frame) |hook| try hook(self, state);

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
        try self.cursor.park(self.writer);
        try self.clearLive();
        try self.writer.flush();
    }

    // ------------------------------------------------------------------
    // Region bookkeeping. The cursor-parking invariant (column 0 of the
    // region's top row, or of an empty line when live_rows == 0) is owned
    // by `RegionCursor`; these keep `live_rows` in step with the screen.
    // ------------------------------------------------------------------

    /// Erase the live region (cursor-to-end-of-screen — the region is the
    /// bottom edge; everything below it is ours).
    fn clearLive(self: *App) !void {
        if (self.live_rows == 0) return;
        try self.writer.writeAll("\r\x1b[0J");
        self.live_rows = 0;
        self.core.invalidate();
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
        if (self.core.front.width == 0 or self.core.front.height == 0) return;
        try self.start();
        try self.reserve(self.core.front.height);
        std.debug.assert(self.cursor.isParked());
        try self.core.repaint(self.writer, .{
            .capability = self.options.capability,
            .sync = self.options.session.sync,
        });
    }

    /// Hybrid takeover: hide the cursor (the only *display* state hybrid owns).
    /// Arm the guard to re-show it — and, when the caller handed its `RawMode`
    /// in via `options.hybrid_raw`, to also restore termios — on a signal/panic
    /// that skips deinit. Input ownership stays with the caller (it enables and
    /// `disable()`s raw mode itself), but the guard is armed here, the single
    /// arm/disarm site, so the registered raw restore never diverges from the
    /// cursor blob. Only on a real terminal (`term_size` null); the headless
    /// harness must not grab process signals.
    fn start(self: *App) !void {
        if (self.started) return;
        self.started = true;
        try self.writer.writeAll("\x1b[?25l");
        if (self.options.term_size == null) {
            self.session.arm("\x1b[?25h", self.options.hybrid_raw);
        }
    }

    fn termSize(self: *App) Size {
        if (self.options.term_size) |s| return s;
        const ws = terminal.getWindowSize(self.outHandle()) catch
            return .{ .w = 80, .h = 24 };
        return .{ .w = ws.col, .h = ws.row };
    }

    /// The handle output escapes actually reach — `options.out_handle` when the
    /// caller's writer targets something other than stdout (e.g. progress on
    /// stderr), stdout otherwise. Owned by the session (it arms the guard
    /// against it); exposed for the size poll above and tests.
    fn outHandle(self: *const App) std.Io.File.Handle {
        return self.session.out_handle;
    }
};

// The restore guard and size polling must target the fd the writer actually
// goes to — progress renders on stderr, and arming the guard with stdout sent
// the cursor-show escape into a redirected file while the stderr tty stayed
// cursorless (#385). Headless (fixed term_size), so no guard is armed here.
test "outHandle: caller-supplied handle overrides the stdout default" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    var app = try App.init(std.testing.allocator, &aw.writer, .{
        .term_size = .{ .w = 20, .h = 5 },
        .out_handle = std.Io.File.stderr().handle,
    });
    defer app.deinit();
    try std.testing.expectEqual(std.Io.File.stderr().handle, app.outHandle());

    var default_app = try App.init(std.testing.allocator, &aw.writer, .{
        .term_size = .{ .w = 20, .h = 5 },
    });
    defer default_app.deinit();
    try std.testing.expectEqual(std.Io.File.stdout().handle, default_app.outHandle());
}
