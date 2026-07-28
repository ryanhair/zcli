//! Frame-diff renderer: turns a (previous, next) surface pair into a minimal
//! byte stream of relative cursor moves and SGR runs (ADR-0013).
//!
//! Addressing contract: the cursor is at column 0 of the region's TOP row on
//! entry and is returned there on exit. All vertical movement is relative
//! (CUD/CUU) and columns are addressed with CR + CUF, never absolute CUP —
//! the live region floats in normal-screen scrollback, where absolute rows
//! are meaningless. The App loop owns creating the region's rows; the parked
//! cursor is owned and enforced by `RegionCursor` (region_cursor.zig) — the
//! App asserts `isParked()` before every paint. This renderer never scrolls.

const std = @import("std");
const theme = @import("theme");
const surface_mod = @import("surface.zig");

const Surface = surface_mod.Surface;
const Cell = surface_mod.Cell;
const Style = surface_mod.Style;
const styleEql = surface_mod.styleEql;

/// The two terminal modes a paint holds open for its own duration, and their
/// undo. Named (rather than spelled inline in `EmitState`) because they are
/// *terminal-global* state that outlives the frame if a paint is interrupted:
/// `terminal_session` folds `wrap_on ++ sync_off` into every guard restore blob
/// so a signal, a panic, or a Ctrl-Z landing mid-frame can put them back (#760).
/// Adding a mode here means adding its undo to `terminal_session.paint_off` —
/// the test there asserts every one of these is covered.
pub const sync_on = "\x1b[?2026h"; // DECSET 2026: synchronized output (BSU)
pub const sync_off = "\x1b[?2026l";
pub const wrap_off = "\x1b[?7l"; // DECRST 7: autowrap OFF
pub const wrap_on = "\x1b[?7h";

pub const Renderer = struct {
    capability: theme.TerminalCapability,
    /// Wrap paints in synchronized output (DECSET 2026) so the terminal
    /// presents the frame atomically. An anti-flicker optimization, never a
    /// correctness dependency — terminals that don't know the mode ignore it.
    sync: bool = true,

    /// Paint `next` given that the terminal currently shows `prev`. Passing
    /// `prev = null` (or surfaces of different sizes) forces a full repaint
    /// that assumes nothing about what's on screen. Emits nothing at all for
    /// an unchanged frame.
    pub fn paint(
        self: Renderer,
        writer: *std.Io.Writer,
        prev: ?*const Surface,
        next: *const Surface,
    ) !void {
        const full = prev == null or
            prev.?.width != next.width or prev.?.height != next.height;

        var st = EmitState{
            .writer = writer,
            .capability = self.capability,
            .sync = self.sync,
        };
        // A mid-paint failure must still close what `start` opened. Autowrap and
        // the sync guard are terminal-global, not frame-local: bailing out with
        // `?7l` still in effect leaves the shell overwriting its last column,
        // and with `?2026h` still in effect leaves the display frozen until the
        // terminal's own BSU timeout (#760). `finish` is idempotent, so the
        // success path's `try st.finish()` below does not double-emit — and
        // `finish` attempts every step even after one fails, so the case where
        // `finish` ITSELF is what threw is already fully handled by the time
        // this fires (see its doc comment; that interaction was a live bug).
        //
        // Best-effort, and worth being precise about what that means, since the
        // only way to reach it is a writer error. `std.Io.Writer` keeps no
        // sticky error flag — `error.WriteFailed` is per call, and `File.Writer`
        // records the errno but retries the syscall on the next drain — so these
        // bytes are not dead on arrival by construction. Three outcomes:
        //
        //   - The usual one: the paint failed on a *drain*, and `finish`'s
        //     handful of bytes fit in the writer's buffer. They reach the
        //     terminal on the next successful flush, which `App.deinit` always
        //     attempts. This is the case the fix is for.
        //   - The sink is genuinely dead (EPIPE on a closed pipe): nothing gets
        //     out — but then the sink was never a terminal, so there is no
        //     terminal state stranded to care about.
        //   - The writer is a fixed buffer with no room left: dropped. Only
        //     tests paint into one of those.
        //
        // So this closes the real case and cannot make any case worse. It is NOT
        // a guarantee that the terminal is restored; `terminal.guard` is what
        // covers the paths where no writer survives at all.
        errdefer st.finish() catch {};

        var row: u16 = 0;
        while (row < next.height) : (row += 1) {
            if (full) {
                try self.paintRowFull(&st, next, row);
            } else {
                try self.paintRowDiff(&st, prev.?, next, row);
            }
        }
        try st.finish();
    }

    /// Full repaint of one row: emit from column 0 through the last cell that
    /// is visibly non-empty, then erase the unknown remainder with EL.
    fn paintRowFull(self: Renderer, st: *EmitState, next: *const Surface, row: u16) !void {
        _ = self;
        var last: u16 = 0;
        var has_content = false;
        var x: u16 = 0;
        while (x < next.width) : (x += 1) {
            const c = next.cell(x, row);
            if (!(c.isBlank() and styleEql(c.style, .{}))) {
                last = x;
                has_content = true;
            }
        }
        try st.moveTo(row, 0);
        if (has_content) try st.emitCells(next, row, 0, last);
        // Erase the unknown remainder — unless the row ran through the last
        // column, where there is nothing right of the cursor to erase (and
        // with autowrap disabled the cursor is clamped ON the last cell, so
        // EL would eat it). Normalize style first: EL fills with the SGR
        // background.
        if (!has_content or last + 1 < next.width) {
            try st.setStyle(.{});
            try st.writer.writeAll("\x1b[K");
        }
    }

    /// Diff one row: emit the single span from the first to the last changed
    /// cell (unchanged cells inside the span repaint — cheaper than extra
    /// cursor moves). A span never starts on a wide continuation: either half
    /// changing repaints from the head, so a wide grapheme is always whole.
    fn paintRowDiff(
        self: Renderer,
        st: *EmitState,
        prev: *const Surface,
        next: *const Surface,
        row: u16,
    ) !void {
        _ = self;
        var first: u16 = 0;
        var last: u16 = 0;
        var dirty = false;
        var x: u16 = 0;
        while (x < next.width) : (x += 1) {
            if (cellEql(prev, prev.cell(x, row), next, next.cell(x, row))) continue;
            if (!dirty) first = x;
            last = x;
            dirty = true;
        }
        if (!dirty) return;

        while (first > 0 and next.cell(first, row).isContinuation()) first -= 1;
        // Extend the span over a wide grapheme's continuation. Bound-check so a
        // torn head at the last column (width 2 with no continuation cell) can
        // never push `last` past the surface edge.
        if (last + 1 < next.width and next.cell(last, row).width == 2) last += 1;

        try st.moveTo(row, first);
        try st.emitCells(next, row, first, last);
    }
};

fn cellEql(ps: *const Surface, a: Cell, ns: *const Surface, b: Cell) bool {
    return a.width == b.width and
        styleEql(a.style, b.style) and
        std.mem.eql(u8, ps.cellText(a), ns.cellText(b));
}

const EmitState = struct {
    writer: *std.Io.Writer,
    capability: theme.TerminalCapability,
    sync: bool,
    started: bool = false,
    cur_row: u16 = 0,
    cur_col: u16 = 0,
    cur_style: Style = .{},

    /// Lazily open the paint: the sync guard, autowrap OFF, and an SGR reset
    /// (the terminal's current attributes are unknown). Only runs if
    /// something gets painted, so an unchanged frame emits zero bytes.
    ///
    /// Autowrap (DECAWM) is disabled for the paint's duration because this
    /// renderer legitimately writes the last column (borders, full-width
    /// rows), and a wrap there desynchronizes relative row addressing —
    /// worse, terminals disagree on WHEN it happens (deferred on the xterm
    /// family, immediate on the legacy Windows console). With wrap off the
    /// cursor deterministically clamps and CR/CUU stay exact.
    fn start(self: *EmitState) !void {
        if (self.started) return;
        self.started = true;
        if (self.sync) try self.writer.writeAll(sync_on);
        try self.writer.writeAll(wrap_off);
        if (self.capability != .no_color) try self.writer.writeAll("\x1b[0m");
    }

    /// Return the cursor to the region's top-left, restore default SGR and
    /// autowrap, and close the sync guard.
    ///
    /// Idempotent by clearing `started`: `paint` closes on both the success and
    /// the error path (an `errdefer`), and a failing `finish` would otherwise
    /// run twice — the second pass emitting a bogus second cursor-up against a
    /// writer that is already erroring.
    ///
    /// Every step is ATTEMPTED even when an earlier one failed, and that is not
    /// belt-and-braces — it is what makes the idempotence above safe. Written
    /// the obvious way, with `try` on each line, a writer that failed on the
    /// cursor-park would return early with `started` already false, so `paint`'s
    /// `errdefer` retry would hit the `!self.started` guard and do nothing at
    /// all: the modes stay open in precisely the case the errdefer exists for.
    /// (Caught by "a paint that fails midway still closes the modes it opened" —
    /// it was a live bug in the first cut of #760.) The park is cosmetic and the
    /// mode close is terminal-global, so the two must not share a fate. The
    /// first error is remembered and returned, so `paint` still reports the
    /// frame as failed rather than silently swallowing a dead writer.
    fn finish(self: *EmitState) !void {
        if (!self.started) return;
        self.started = false;

        var first_err: ?anyerror = null;
        const keep = struct {
            fn f(slot: *?anyerror, e: anyerror) void {
                if (slot.* == null) slot.* = e;
            }
        }.f;

        // Cosmetic: park the cursor at the region's top-left with default SGR.
        self.setStyle(.{}) catch |e| keep(&first_err, e);
        self.writer.writeByte('\r') catch |e| keep(&first_err, e);
        if (self.cur_row > 0) {
            self.writer.print("\x1b[{d}A", .{self.cur_row}) catch |e| keep(&first_err, e);
        }
        // Terminal-global: these outlive the frame, so they go out regardless.
        self.writer.writeAll(wrap_on) catch |e| keep(&first_err, e);
        if (self.sync) self.writer.writeAll(sync_off) catch |e| keep(&first_err, e);

        if (first_err) |e| return e;
    }

    /// Move to (row, col) in region coordinates. Rows are visited in order,
    /// so vertical movement is always downward.
    fn moveTo(self: *EmitState, row: u16, col: u16) !void {
        try self.start();
        std.debug.assert(row >= self.cur_row);
        if (row > self.cur_row) {
            try self.writer.print("\x1b[{d}B", .{row - self.cur_row});
            self.cur_row = row;
        }
        try self.writer.writeByte('\r');
        if (col > 0) try self.writer.print("\x1b[{d}C", .{col});
        self.cur_col = col;
    }

    fn setStyle(self: *EmitState, style: Style) !void {
        if (self.capability == .no_color) return;
        if (styleEql(style, self.cur_style)) return;
        try self.writer.writeAll("\x1b[0m");
        _ = try style.writeSequence(self.writer, self.capability);
        self.cur_style = style;
    }

    /// Emit the cells first..=last of `row`. A wide grapheme's head advances
    /// `x` by 2, stepping over its continuation cell so both columns are
    /// painted by the head's write. An orphan continuation — reachable only
    /// when a span begins mid-character during a full repaint of a
    /// blank-headed row — falls through to the general path below, which
    /// paints it as a styled space (`text_len == 0`) and advances one column
    /// (`@max(c.width, 1)`), keeping `cur_col` in lockstep with the model.
    fn emitCells(self: *EmitState, s: *const Surface, row: u16, first: u16, last: u16) !void {
        var x = first;
        while (x <= last) {
            const c = s.cell(x, row);
            try self.setStyle(c.style);
            if (c.text_len == 0) {
                try self.writer.writeByte(' ');
            } else {
                try self.writer.writeAll(s.cellText(c));
            }
            self.cur_col += @max(c.width, 1);
            x += @max(c.width, 1);
        }
    }
};

// ============================================================================
// Tests (byte-level; behavior-level golden tests live in golden_test.zig)
// ============================================================================

const testing = std.testing;

fn paintToString(
    allocator: std.mem.Allocator,
    r: Renderer,
    prev: ?*const Surface,
    next: *const Surface,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try r.paint(&aw.writer, prev, next);
    return allocator.dupe(u8, aw.written());
}

/// A writer that logs everything it drains, except for one nominated drain call
/// which fails instead — the shape of a real mid-paint failure, where a buffered
/// writer takes most writes into its buffer and only the occasional drain
/// touches the sink.
///
/// The failure is deliberately NOT sticky, because `std.Io.Writer` isn't: a
/// `File.Writer` records the errno and retries on the next drain. That is what
/// makes `paint`'s `errdefer` worth having — the restore bytes still have a
/// route out — and a permanently-failing writer would test the opposite
/// assumption.
const FlakyWriter = struct {
    /// Small on purpose: a big buffer would swallow the whole frame and never
    /// drain, so the failure could never land mid-paint.
    buf: [8]u8 = undefined,
    interface: std.Io.Writer = undefined,
    log: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    calls: usize = 0,
    fail_at: usize,

    /// Initialized in place: `interface.buffer` points into `self`, so the
    /// struct can't be returned by value.
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
        // Fail before consuming anything, the way a failed `write(2)` does.
        if (call == self.fail_at) return error.WriteFailed;

        // Contract: buffered bytes first, then each slice of `data`, with the
        // last one repeated `splat` times. Only `data` counts toward the return.
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

// The #760 error-path regression test. `start` turns autowrap off and opens the
// sync guard for the paint's duration; before the `errdefer`, a paint that threw
// between those and `finish` left both set on a terminal it no longer owned.
//
// Swept over every drain index rather than pinned to one, so the test doesn't
// encode the byte arithmetic of a frame (which any renderer change would shift).
//
// What is asserted is COMPLETION, not the presence of any particular sequence,
// and the difference matters. Neither `wrap_on` nor `sync_off` can be demanded
// per-case: for one position in the sweep the failing drain is the one carrying
// that very sequence, and nothing can push bytes through a writer that rejects
// them. What CAN be demanded is that a single failure costs a single sequence —
// `finish` attempts every step, so at most the one whose own write failed is
// lost.
//
// That bound is exactly what separates the bug from the fix, and it holds
// regardless of buffer size or frame contents. The first cut of #760 used `try`
// on every line of `finish`: a writer that failed on the cursor-park returned
// early with `started` already cleared, so `paint`'s `errdefer` retry hit the
// `!started` guard and did nothing — losing BOTH sequences. Two missing is the
// bug; one is the writer.
test "a paint that fails midway still runs the whole close-out" {
    var next = try Surface.init(testing.allocator, 12, 3);
    defer next.deinit();
    _ = try next.root().writeText(0, 0, "hello there", .{});
    _ = try next.root().writeText(0, 1, "second row", .{});

    var saw_interrupted_paint = false;
    var saw_full_close = false;
    for (0..24) |fail_at| {
        var fw: FlakyWriter = undefined;
        fw.init(testing.allocator, fail_at);
        defer fw.deinit();

        const r = Renderer{ .capability = .ansi_16, .sync = true };
        const result = r.paint(&fw.interface, null, &next);
        // The close-out bytes land in the writer's buffer; a later flush is what
        // puts them on the wire. `App.deinit` always attempts one — this is that
        // flush, and by now the flaky drain has moved past `fail_at`.
        fw.interface.flush() catch {};

        const opened = std.mem.indexOf(u8, fw.log.items, wrap_off) != null;
        if (result) |_| {
            // Completed frames are covered by the other tests here; nothing to
            // prove on the success path.
            continue;
        } else |_| {
            if (!opened) continue; // failed before `start` — nothing was opened
            saw_interrupted_paint = true;
            const closed_wrap = std.mem.lastIndexOf(u8, fw.log.items, wrap_on);
            const closed_sync = std.mem.lastIndexOf(u8, fw.log.items, sync_off);

            // The invariant: one failed write costs at most one sequence. Two
            // missing means `finish` stopped at the first error instead of
            // attempting the rest.
            var missing: usize = 0;
            if (closed_wrap == null) missing += 1;
            if (closed_sync == null) missing += 1;
            try testing.expect(missing <= 1);

            if (closed_wrap) |w| {
                if (closed_sync != null) saw_full_close = true;
                // Ordering, not just presence: the close has to come after the open.
                try testing.expect(w > std.mem.lastIndexOf(u8, fw.log.items, wrap_off).?);
            }
        }
    }
    // Guards the test itself: if a renderer change made the frame small enough
    // to never drain, every iteration would `continue` and this would assert
    // nothing at all.
    try testing.expect(saw_interrupted_paint);
    // And guards the assertion above from passing on a `finish` that only ever
    // gets its tail out: at least one interrupted paint must close BOTH modes.
    try testing.expect(saw_full_close);
}

test "unchanged frame emits zero bytes" {
    var a = try Surface.init(testing.allocator, 8, 2);
    defer a.deinit();
    var b = try Surface.init(testing.allocator, 8, 2);
    defer b.deinit();
    _ = try a.root().writeText(0, 0, "same", .{});
    _ = try b.root().writeText(0, 0, "same", .{});

    const out = try paintToString(testing.allocator, .{ .capability = .ansi_16 }, &a, &b);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "diff paints only the changed span" {
    var a = try Surface.init(testing.allocator, 20, 2);
    defer a.deinit();
    var b = try Surface.init(testing.allocator, 20, 2);
    defer b.deinit();
    _ = try a.root().writeText(0, 0, "stable line", .{});
    _ = try a.root().writeText(0, 1, "count 1", .{});
    _ = try b.root().writeText(0, 0, "stable line", .{});
    _ = try b.root().writeText(0, 1, "count 2", .{});

    const out = try paintToString(testing.allocator, .{ .capability = .ansi_16, .sync = false }, &a, &b);
    defer testing.allocator.free(out);
    // Only the one changed cell on row 1: move down, column 6, paint "2",
    // return. No trace of the unchanged text.
    try testing.expect(std.mem.indexOf(u8, out, "stable") == null);
    try testing.expect(std.mem.indexOf(u8, out, "2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "count") == null);
    try testing.expect(out.len < 32);
}

test "sync guard wraps the paint when enabled" {
    var next = try Surface.init(testing.allocator, 4, 1);
    defer next.deinit();
    _ = try next.root().writeText(0, 0, "x", .{});

    const out = try paintToString(testing.allocator, .{ .capability = .ansi_16 }, null, &next);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "\x1b[?2026h"));
    try testing.expect(std.mem.endsWith(u8, out, "\x1b[?2026l"));
}

test "diff never extends a span past the surface edge on a torn wide head" {
    var prev = try Surface.init(testing.allocator, 4, 1);
    defer prev.deinit();
    var next = try Surface.init(testing.allocator, 4, 1);
    defer next.deinit();
    // Synthesize a torn wide head at the last column: a width-2 cell whose
    // continuation would fall at column 4, off the surface edge. copyRows now
    // prevents this tear at the source, but the diff's wide-span extension must
    // still stay in bounds — `last + 1 < next.width` guards `last += 1` from
    // ever addressing column `width`.
    next.cells[3] = .{ .width = 2 };

    const out = try paintToString(testing.allocator, .{ .capability = .ansi_16, .sync = false }, &prev, &next);
    defer testing.allocator.free(out);
    try testing.expect(out.len > 0);
}

test "span starting on an orphan continuation paints a space so the cursor stays in lockstep" {
    var prev = try Surface.init(testing.allocator, 4, 1);
    defer prev.deinit();
    var next = try Surface.init(testing.allocator, 4, 1);
    defer next.deinit();
    // Synthesize an orphan continuation at column 0: a width-0 cell with no
    // head to its left. `paintRowDiff` cannot back `first` off column 0
    // (the `first > 0` guard), so `emitCells` begins the span on the
    // continuation itself. It must paint a space and advance `cur_col`, or the
    // following real cell would be written one column too far left.
    next.cells[0] = .{ .width = 0 };
    _ = try next.root().writeText(1, 0, "X", .{});

    const out = try paintToString(testing.allocator, .{ .capability = .no_color, .sync = false }, &prev, &next);
    defer testing.allocator.free(out);
    // The continuation renders as a space, immediately followed by the head of
    // the next cell — no shift.
    try testing.expect(std.mem.indexOf(u8, out, " X") != null);
}

test "no_color paints text but never SGR" {
    var next = try Surface.init(testing.allocator, 6, 1);
    defer next.deinit();
    _ = try next.root().writeText(0, 0, "hi", .{ .bold = true, .foreground = .red });

    const out = try paintToString(testing.allocator, .{ .capability = .no_color, .sync = false }, null, &next);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "hi") != null);
    try testing.expect(std.mem.indexOf(u8, out, "m") == null); // no SGR final byte
}
