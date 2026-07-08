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
    };

    writer: *std.Io.Writer,
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

    pub fn init(gpa: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !App {
        return .{
            .writer = writer,
            .options = options,
            .frame_arena = std.heap.ArenaAllocator.init(gpa),
            .front = try Surface.init(gpa, 0, 0),
            .back = try Surface.init(gpa, 0, 0),
        };
    }

    /// Restores the terminal (cursor shown, parked on a fresh line below the
    /// live region — the final frame stays visible, flowing into scrollback)
    /// and frees everything.
    pub fn deinit(self: *App) void {
        if (self.started) {
            if (self.live_rows > 1) {
                self.writer.print("\x1b[{d}B", .{self.live_rows - 1}) catch {};
            }
            if (self.live_rows > 0) self.writer.writeAll("\r\n") catch {};
            self.writer.writeAll("\x1b[?25h") catch {};
        }
        self.writer.flush() catch {};
        self.front.deinit();
        self.back.deinit();
        self.frame_arena.deinit();
    }

    /// The frame arena: build each frame's node tree from this. Valid until
    /// the `frame()` call that consumes the tree returns.
    pub fn arena(self: *App) std.mem.Allocator {
        return self.frame_arena.allocator();
    }

    /// Static output: printed above the live region, flows into scrollback,
    /// never repainted. Line-oriented (see module docs).
    pub fn emit(self: *App, comptime fmt: []const u8, args: anytype) !void {
        const had_live = self.live_rows > 0;
        try self.clearLive();
        try self.writer.print(fmt, args);
        if (comptime !std.mem.endsWith(u8, fmt, "\n")) try self.writer.writeByte('\n');
        if (had_live) try self.repaintLive();
        try self.writer.flush();
    }

    /// Live output: measure, lay out, paint the diff. The tree (built from
    /// `self.arena()`) is consumed — the arena resets when this returns.
    pub fn frame(self: *App, node: Node) !void {
        defer _ = self.frame_arena.reset(.retain_capacity);

        const ts = self.termSize();
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
        if (size.h != self.live_rows) {
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
            .sync = self.options.sync,
        };
        try renderer.paint(self.writer, prev, &self.back);
        std.mem.swap(Surface, &self.front, &self.back);
        self.front_valid = true;
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
        while (i < rows) : (i += 1) try self.writer.writeAll("\n");
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
