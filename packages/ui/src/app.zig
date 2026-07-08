//! App: the static/live frame loop (ADR-0013 step 3).
//!
//! Owns everything the demo used to hand-roll: the frame arena, the
//! double-buffered surfaces, reserving the live region's rows, parking the
//! cursor at the region's top-left (the diff renderer's addressing
//! contract), and cursor hide/restore.
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

pub const App = struct {
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
        /// touched.
        interactive: bool = true,
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

    pub const CursorPos = struct { x: u16, y: u16 };

    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !App {
        return .{
            .writer = writer,
            .gpa = gpa,
            .options = options,
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
            .front = try Surface.init(gpa, 0, 0),
            .back = try Surface.init(gpa, 0, 0),
        };
    }

    /// Restores the terminal (cursor shown, parked on a fresh line below the
    /// live region — the final frame stays visible, flowing into scrollback)
    /// and frees everything. Idempotent.
    pub fn deinit(self: *App) void {
        if (self.deinited) return;
        self.deinited = true;
        if (self.started) {
            self.unplace() catch {};
            if (self.live_rows > 1) {
                self.writer.print("\x1b[{d}B", .{self.live_rows - 1}) catch {};
            }
            if (self.live_rows > 0) self.writer.writeAll("\r\n") catch {};
            self.writer.writeAll("\x1b[?25h") catch {};
        }
        self.writer.flush() catch {};
        for (self.retained.items) |b| self.gpa.free(b.text);
        self.retained.deinit(self.gpa);
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
        // A root with `.fill` stretches to the terminal edge (a full-screen
        // app is just a root with `height = fill`, not a separate mode).
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

    fn start(self: *App) !void {
        if (self.started) return;
        self.started = true;
        try self.writer.writeAll("\x1b[?25l");
    }

    fn termSize(self: *App) Size {
        if (self.options.term_size) |s| return s;
        const ws = terminal.getWindowSize(std.Io.File.stdout().handle) catch
            return .{ .w = 80, .h = 24 };
        return .{ .w = ws.col, .h = ws.row };
    }
};
