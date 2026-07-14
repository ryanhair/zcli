//! Table widget (ADR-0018, ADR-0021): a read-only data grid with scrolling.

const std = @import("std");
const theme_mod = @import("theme");
const terminal = @import("terminal");
const node_mod = @import("node.zig");
const surface_mod = @import("surface.zig");
const helpers = @import("input_helpers.zig");

const Node = node_mod.Node;
const Dim = node_mod.Dim;
const Limits = node_mod.Limits;
const Size = node_mod.Size;
const RenderCtx = node_mod.RenderCtx;
const Style = surface_mod.Style;
const Region = surface_mod.Region;
const Rect = surface_mod.Rect;
const Key = terminal.Key;
const Theme = theme_mod.Theme;

const scrollFor = helpers.scrollFor;
const scrollbarWrap = helpers.scrollbarWrap;

/// A read-only data grid: a header row over scrollable body rows, with a
/// selection and a scroll window ported straight from `Select`. Rows and columns
/// are caller-owned and passed to `view` each frame (immediate mode); the widget
/// holds only the two persistent fields `Select` does — `highlighted` (the
/// selected row) and `scroll` (the window top) — maintained by the shared
/// `scrollFor` rule.
///
/// ↑/↓/Home/End move the selection one row / to the ends; PgUp/PgDn page by the
/// visible height. Those keys are consumed; Enter/Tab/Escape bubble to the form,
/// which reads the choice as `rows[table.highlighted]`.
///
/// Column widths reuse the existing `Dim` vocabulary (`node.zig`): `.fit` sizes
/// to the widest cell in that column (header included), `.len(n)` is fixed, and
/// `.fill(w)` splits leftover width proportionally — the box engine does the
/// distribution, so there is no bespoke column math beyond resolving `.fit` to a
/// concrete width. Cells that overrun their column truncate with `…` through the
/// same width/ANSI-aware path `Select` uses (`wrap = .truncate`). The header wears
/// `th.prompts.hint`; the highlighted row is a full-width `th.prompts.selected`
/// band; and a 1-cell right gutter carries the dim ↑/↓/↕ overflow arrows, exactly
/// as `Select`'s single-line path (ADR-0018 incr4).
pub const Table = struct {
    highlighted: usize = 0,
    /// First visible body row — persistent, maintained by `handle`.
    scroll: usize = 0,

    /// Non-scrolling rows `view` paints above the body (just the column header).
    /// `rowAt` subtracts these so a click maps to a body row, not the header.
    pub const header_rows: u16 = 1;

    /// A column: a header label and a width in the existing `Dim` vocabulary.
    pub const Column = struct {
        header: []const u8,
        width: Dim = .fit,
    };

    pub const ViewOpts = struct {
        focused: bool = false,
        columns: []const Column,
        /// `rows[r][c]` is the text of row `r`, column `c`. A row must have one
        /// cell per column; a short row renders blanks for the missing cells.
        rows: []const []const []const u8,
        /// Visible body rows (the header sits above and does not scroll).
        height: u16 = 10,
        theme: *const Theme = theme_mod.appTheme(),
        /// Opt in to a proportional scrollbar in the right gutter (ADR-0021 incr5),
        /// OFF by default. When on, the scrollbar *replaces* the ↑/↓/↕ overflow
        /// arrows in the same 1-cell body gutter — the richer indicator for the
        /// same column. The non-scrolling header keeps a blank gutter cell.
        scrollbar: bool = false,
    };

    /// Handle a key; returns whether it was consumed. `row_count` (the row count)
    /// and `visible` (the body height) are what the caller passes to `view`, so
    /// the selection and scroll stay in step with what's rendered. PgUp/PgDn move
    /// by `visible` rows; everything else (Enter/Tab/…) bubbles.
    pub fn handle(self: *Table, key: Key, row_count: usize, visible: u16) bool {
        if (row_count == 0) return false;
        const v = @max(@as(usize, visible), 1);
        switch (key) {
            .up => if (self.highlighted > 0) {
                self.highlighted -= 1;
            },
            .down => if (self.highlighted + 1 < row_count) {
                self.highlighted += 1;
            },
            .home => self.highlighted = 0,
            .end => self.highlighted = row_count - 1,
            .pageup => self.highlighted -|= v,
            .pagedown => self.highlighted = @min(self.highlighted + v, row_count - 1),
            else => return false,
        }
        self.scroll = scrollFor(self.scroll, self.highlighted, visible, row_count);
        return true;
    }

    /// Map a click onto the body row it landed on, or `null` if it missed the
    /// body (the header row, or outside the table). `rect` is the table's rendered
    /// rect (from `ui.probe`) and `y` is the click's row — both in 0-based surface
    /// coordinates. Mouse reports are 1-based, so pass `mouse.y - 1`.
    ///
    /// This exists because `view` paints its column header as the table's first
    /// row (`header_rows`), inside the same rect `probe` reports: a caller doing
    /// `row = y - rect.y` would be off by the header and select the row below the
    /// click. `rowAt` subtracts the header and adds `scroll`, so the returned index
    /// is into the caller's full row slice. It does not bound against the row
    /// count — the caller clamps (a click below the last populated row is theirs to
    /// reject); it only rejects the header and rows past the rendered rect.
    pub fn rowAt(self: *const Table, rect: Rect, y: u16) ?usize {
        if (y < rect.y + header_rows) return null; // header or above
        if (y >= rect.y + rect.h) return null; // below the table
        return self.scroll + (y - rect.y - header_rows);
    }

    pub fn view(self: *const Table, a: std.mem.Allocator, opts: ViewOpts) !Node {
        const th = opts.theme;
        const cols = opts.columns;
        const count = opts.rows.len;
        const hint = th.prompts.hint.resolve(th.palette);

        // Resolve each column's effective width. `.fit` becomes a concrete `.len`
        // of the widest cell in that column (header + every row), so columns align
        // across rows — a per-row `.fit` would size each cell independently. `.len`
        // and `.fill` pass through untouched for the box engine to distribute.
        const widths = try a.alloc(Dim, cols.len);
        for (cols, widths, 0..) |col, *w, ci| {
            w.* = switch (col.width) {
                .fit => blk: {
                    var max = terminal.displayWidth(col.header);
                    for (opts.rows) |r| {
                        if (ci < r.len) max = @max(max, terminal.displayWidth(r[ci]));
                    }
                    break :blk .{ .len = @intCast(max) };
                },
                else => col.width,
            };
        }

        const hi = if (count == 0) 0 else @min(self.highlighted, count - 1);
        const visible = @min(@max(@as(usize, opts.height), 1), count);
        // Persistent scroll, re-derived so the selection stays in view even if the
        // caller set `highlighted` directly, bypassing `handle`.
        const scroll = if (count == 0) 0 else scrollFor(self.scroll, hi, @intCast(visible), count);

        const more_above = scroll > 0;
        const more_below = scroll + visible < count;

        // Header row + one body column of visible lines. The header carries a blank
        // gutter cell so its columns line up with the body's; the body draws its own
        // gutter arrows (or, with a scrollbar, a blank gutter the thumb overpaints).
        const header = try buildRow(a, cols, widths, try headerCells(a, cols), hint, hint, " ", .{});

        const body_rows = try a.alloc(Node, visible);
        for (0..visible) |i| {
            const idx = scroll + i;
            const is_hi = idx == hi;
            const style: Style = if (is_hi) th.prompts.selected.resolve(th.palette) else .{};
            // Full-width band on the highlighted row (the box background paints the
            // gaps between cells too); non-highlighted rows are plain.
            const band: Style = if (is_hi) style else .{};
            // With a scrollbar the gutter carries the thumb instead of arrows.
            const up = !opts.scrollbar and i == 0 and more_above;
            const down = !opts.scrollbar and i == visible - 1 and more_below;
            const arrow: []const u8 = if (up and down) "↕" else if (up) "↑" else if (down) "↓" else " ";
            body_rows[i] = try buildRow(a, cols, widths, opts.rows[idx], style, hint, arrow, band);
        }
        var body: Node = .{ .kind = .{ .box = .{ .dir = .column, .children = body_rows } } };
        // The scrollbar spans only the scrolling body rows (the header is fixed),
        // so it wraps the body column, not the whole table.
        if (opts.scrollbar) body = try scrollbarWrap(a, th, body, count, visible, scroll);

        const lines = try a.dupe(Node, &.{ header, body });
        return .{ .kind = .{ .box = .{ .dir = .column, .children = lines } } };
    }
};

/// The header cells (one per column) as a `[]const []const u8`, so the header
/// row is built through the same `buildRow` path as a body row.
fn headerCells(a: std.mem.Allocator, cols: []const Table.Column) ![]const []const u8 {
    const cells = try a.alloc([]const u8, cols.len);
    for (cols, cells) |col, *c| c.* = col.header;
    return cells;
}

/// One table row: an inner `row{}` of per-cell `text` nodes carrying the resolved
/// column `Dim`s (so the box engine distributes the columns), paired with a fixed
/// 1-cell gutter for the overflow arrow — the same shape as `Select`'s single-line
/// row. The inner row carries the highlight `band` background (so it spans the
/// gaps between cells for a full-width band) but *not* the gutter, which keeps a
/// plain background under the dim arrow exactly as `Select` does. `cell_style`
/// styles the cell text; `gutter_style` styles the arrow.
fn buildRow(
    a: std.mem.Allocator,
    cols: []const Table.Column,
    widths: []const Dim,
    cells: []const []const u8,
    cell_style: Style,
    gutter_style: Style,
    arrow: []const u8,
    band: Style,
) !Node {
    const cells_nodes = try a.alloc(Node, cols.len);
    for (widths, 0..) |w, ci| {
        const content: []const u8 = if (ci < cells.len) cells[ci] else "";
        cells_nodes[ci] = .{
            .width = w,
            .kind = .{ .text = .{ .content = content, .style = cell_style, .wrap = .truncate } },
        };
    }
    const inner: Node = .{
        .width = .{ .fill = 1 },
        .kind = .{ .box = .{ .dir = .row, .gap = 1, .children = cells_nodes, .style = band } },
    };
    const gutter: Node = .{
        .width = .{ .len = 1 },
        .kind = .{ .text = .{ .content = arrow, .style = gutter_style, .wrap = .clip } },
    };
    const outer = try a.dupe(Node, &.{ inner, gutter });
    return .{ .kind = .{ .box = .{ .dir = .row, .children = outer } } };
}
