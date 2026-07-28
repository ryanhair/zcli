//! A virtual terminal emulator: feed it the bytes a program wrote, ask it what
//! a real terminal would be showing.
//!
//! This is what makes terminal output *testable*. Rendered output is a stream of
//! interleaved text and escape sequences — asserting on those bytes means
//! asserting on an implementation detail (`\x1b[2K\x1b[1G` vs. `\r\x1b[K` paint
//! the same thing), and any change to how a frame is drawn breaks tests that
//! were never about drawing. `VTerm` collapses the stream to the state it
//! produces, so a test says "row 3 reads `Done`, and it is bold" instead of
//! naming the sequences that got it there.
//!
//! **The grid.** Cells live in a circular buffer holding `scrollback_lines`
//! rows, not just the visible ones. A *logical line* is an absolute line number
//! (line 0 = the first line ever written) and occupies ring row
//! `line % scrollback_lines`, so the mapping survives any number of laps and any
//! resize. The **viewport** is the `height` rows currently on screen; every
//! public read and write below (`getCell`, `moveCursor`, `containsText`, …) is
//! viewport-relative, and the scrollback is reached by moving the viewport
//! (`scrollViewportUp`, `pageUp`) rather than by addressing it directly.
//!
//! **The model is deliberately narrow.** One cell per codepoint (wide CJK/emoji
//! glyphs claim a second continuation cell), the eight basic ANSI colors, and
//! bold/italic/underline. It is built to answer questions test authors actually
//! ask, not to be a conformant DEC terminal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const DisplayWidth = @import("DisplayWidth");

const CellModule = @import("cell.zig");
const PositionModule = @import("position.zig");

/// One grid cell: a codepoint plus the colors and attributes in force when it
/// was written. `char == 0` is an empty cell; `wide_continuation` marks the
/// second half of a wide glyph (it carries no codepoint of its own, so text
/// extraction skips it rather than emitting a stray space).
pub const Cell = CellModule.Cell;

/// A viewport-relative `(x, y)` coordinate: column from the left edge, row from
/// the top of the visible area — the same frame `getCell` and `moveCursor` use.
pub const Position = PositionModule.Position;

/// A snapshot of the screen taken by `captureState`, for comparing "before" and
/// "after" without holding two live terminals. `content` is `getAllText`'s flat
/// `width * height` run with no row breaks — use `getAllLines` if the snapshot
/// needs to preserve row structure. Owns `content`; call `deinit`.
pub const TerminalState = struct {
    content: []u8, // All text as single string
    cursor: Position,
    dimensions: struct { width: u16, height: u16 },

    /// Frees `content`. Pass the same allocator `captureState` was given — the
    /// snapshot does not store one.
    pub fn deinit(self: *TerminalState, allocator: Allocator) void {
        allocator.free(self.content);
    }
};

/// A keystroke to send *to* the program under test, named rather than spelled.
/// `inputKey` turns it into the bytes a real terminal would emit, so a test
/// writes `.arrow_up` instead of `"\x1b[A"` and does not encode which of the
/// several legal encodings this harness happens to use.
///
/// Deliberately small: ASCII characters, arrows, enter/escape, F1-F12, and
/// Ctrl+A..Ctrl+Z (as the control codes 1-26). Anything outside that — Alt
/// combinations, bracketed paste, mouse reports — is written as raw bytes.
pub const Key = union(enum) {
    char: u8, // ASCII character input only
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    enter,
    escape,
    function: u8, // F1-F12 (1-12)
    ctrl_char: u8, // Ctrl+A through Ctrl+Z (1-26)
};

/// The eight basic ANSI colors, plus `default` for "never set". Values are the
/// SGR *foreground* codes (30-37) so the enum reads like the sequences it
/// models; cells store the 0-7 index, and `getTextColor`/`getBackgroundColor`
/// translate.
///
/// `default` is genuinely ambiguous in one direction each way, because a cell
/// cannot record "no color was set" separately from the color it defaults to:
/// a white foreground reports `.default` (7 is the default fg), and a black
/// background reports `.default` (0 is the default bg). Assert on the other six
/// when a test needs to prove a color was applied.
pub const Color = enum(u8) {
    default = 0,
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
};

/// The text attributes the emulator tracks, for `hasAttribute`. Styling that
/// does not survive into a cell (reverse video, blink, dim, strikethrough) is
/// parsed and discarded — this is the set worth asserting on.
pub const TextAttribute = enum {
    bold,
    italic,
    underline,
};

/// Cells occupied by one codepoint: 2 for wide glyphs (CJK, emoji), 1 for
/// everything else.
///
/// vterm uses a fixed one-cell-per-codepoint model, so only the wide/narrow
/// distinction matters here; the underlying Unicode data comes from zg's
/// DisplayWidth table rather than a hand-maintained list of ranges.
pub fn charWidth(codepoint: u21) u8 {
    return if (DisplayWidth.codePointWidth(codepoint) == 2) 2 else 1;
}

// Parser state
const ParserState = enum {
    ground, // Normal text input
    escape, // After ESC (0x1B)
    csi, // After ESC[ - collecting parameters
    osc, // After ESC] - consuming an OSC payload until BEL or ST (ESC \)
    osc_escape, // Inside an OSC payload, just saw ESC (maybe ST)
};

/// Where the viewport sits in history, from `getScrollbackPosition`. `at_bottom`
/// is the one to assert on: any `write` snaps the viewport back to the present,
/// so a test that scrolled up and expects to still be there is asserting on a
/// terminal nobody wrote to in between.
pub const ScrollPosition = struct {
    current_line: u32, // Current viewport position in history
    total_lines: u32, // Total lines in scrollback
    at_bottom: bool, // Whether viewport is at bottom
};

/// The emulator itself: `write` the bytes a program produced, then read the
/// resulting screen. See the module doc for the grid/viewport model.
pub const VTerm = struct {
    allocator: Allocator,

    // Circular buffer for scrollback
    cells: []Cell,
    scrollback_lines: u16, // Total lines in buffer (e.g., 1000)
    width: u16,
    height: u16, // Viewport height (visible lines, e.g., 24)

    // Circular buffer management
    total_lines_written: u32, // Total lines ever written (for history tracking)
    virtual_cursor_y: u32, // Cursor Y that continues beyond height (for line tracking)

    // Viewport
    viewport_offset: i32, // Offset from bottom (0 = bottom, negative = scrolled up)

    // Cursor state (viewport-relative)
    cursor: Position,

    // Parser state
    parser_state: ParserState,
    params: [16]u16, // Parameter buffer (fixed size for simplicity)
    param_count: u8,
    private_sequence: bool, // Track if this is a private sequence (starts with ?)

    // A UTF-8 sequence can be split across write() calls; the partial sequence
    // is stashed here and completed by the next write. Dropping the lead byte
    // instead would smear the continuation bytes into mojibake.
    utf8_partial: [4]u8,
    utf8_partial_have: u8,
    utf8_partial_expected: u8,

    // Current text attributes
    current_fg: u8,
    current_bg: u8,
    current_bold: bool,
    current_italic: bool,
    current_underline: bool,

    // Terminal modes
    alt_screen: bool,
    cursor_visible: bool,
    autowrap: bool, // DECAWM (CSI ?7 h/l); off = clamp at the last column

    /// Circular buffer coordinate translation. Logical lines are ABSOLUTE
    /// line numbers (line 0 = first line ever written); the ring holds the
    /// most recent `scrollback_lines` of them at row `line % scrollback_lines`.
    /// Writes and reads share this one mapping, so the viewport stays in sync
    /// no matter how many times the ring laps (#393).
    ///
    /// Public for the scrollback tests, which assert the mapping directly rather
    /// than inferring it from rendered output; ordinary use goes through
    /// `getCell`/`getLine`, which apply it for you.
    pub fn bufferLineIndex(self: *VTerm, logical_line: u32) u16 {
        return @intCast(logical_line % self.scrollback_lines);
    }

    /// The ring row backing viewport row `viewport_y`, honoring the user's
    /// scrollback offset — or null when that row has no content: above the
    /// first line, past the last, or old enough that the ring has overwritten
    /// it. Callers must treat null as "empty", never as row 0; reading through
    /// the raw `% scrollback_lines` mapping instead would return the *newer*
    /// line that overwrote it.
    pub fn viewportToBuffer(self: *VTerm, viewport_y: u16) ?u16 {
        // Convert viewport Y to buffer line index

        // Special case: if we have no content or fewer lines than viewport height,
        // just map viewport_y directly to logical line (for the entire viewport)
        if (self.total_lines_written <= self.height and self.viewport_offset == 0) {
            if (viewport_y < self.height) {
                return self.bufferLineIndex(@as(u32, viewport_y));
            } else {
                return null; // Beyond viewport
            }
        }

        const bottom_line = self.getBottomLine();
        // viewport_y = 0 is the top of viewport, viewport_y = height-1 is bottom
        // bottom line - (height-1) + viewport_y gives the logical line for this viewport position
        const logical_line_signed = @as(i32, @intCast(bottom_line)) - @as(i32, @intCast(self.height - 1)) + @as(i32, @intCast(viewport_y)) + self.viewport_offset;

        if (logical_line_signed < 0) return null;
        const logical_line = @as(u32, @intCast(logical_line_signed));
        if (logical_line >= self.total_lines_written) return null;
        // Lines older than the ring's capacity have been overwritten by newer
        // content — reading them through the mod mapping would return the
        // overwriting line's cells.
        if (self.total_lines_written > self.scrollback_lines and
            logical_line < self.total_lines_written - self.scrollback_lines) return null;

        return self.bufferLineIndex(logical_line);
    }

    /// The absolute logical line number of the newest line written — the line
    /// at the bottom of the viewport when it is at the present. Uncapped by
    /// `scrollback_lines` on purpose: capping it desynced reads from writes once
    /// the ring lapped (#393).
    pub fn getBottomLine(self: *VTerm) u32 {
        // The absolute logical line number at the bottom of the viewport —
        // always the newest line written, however many times the ring lapped.
        if (self.total_lines_written == 0) return 0;
        return self.total_lines_written - 1;
    }

    /// Convert a viewport-relative row (0..height-1) to the ABSOLUTE logical
    /// line number the write path uses (`virtual_cursor_y`, `setCellDirect`,
    /// `openLine`). CSI cursor moves (CUP/CUU/CUD) are addressed in viewport
    /// coordinates, but writes and reads operate on absolute lines — without
    /// this conversion, repositioning after the buffer scrolls past one
    /// screen lands subsequent output on scrolled-off lines the viewport never
    /// shows (#504). Mirrors the present-view mapping in `viewportToBuffer`
    /// (user scrollback offset excluded: the cursor always addresses the live
    /// bottom of the buffer).
    fn viewportToLogicalLine(self: *VTerm, viewport_y: u16) u32 {
        // Mirror viewportToBuffer's special case: before the buffer has filled
        // one screen the bottom line sits above viewport row height-1, so the
        // scroll formula would underflow — viewport rows map straight through.
        if (self.total_lines_written <= self.height) {
            return viewport_y;
        }
        const bottom_line = self.getBottomLine();
        return bottom_line - (self.height - 1) + viewport_y;
    }

    // Bounds checking
    fn isValidPos(self: VTerm, x: u16, y: u16) bool {
        return x < self.width and y < self.height;
    }

    // Initialization and Cleanup
    const DEFAULT_SCROLLBACK = 1000;

    /// A `width` x `height` terminal with 1000 lines of scrollback. `deinit`
    /// frees the cell buffer. The whole scrollback is allocated up front
    /// (`scrollback_lines * width` cells), so a huge scrollback costs memory
    /// immediately — `initWithScrollback` exists for tests that want it small.
    pub fn init(allocator: Allocator, width: u16, height: u16) !VTerm {
        return initWithScrollback(allocator, width, height, .{
            .scrollback_lines = DEFAULT_SCROLLBACK,
        });
    }

    /// Options for `initWithScrollback`. `scrollback_lines` is the ring's total
    /// capacity, not extra rows above the viewport: a value below `height`
    /// leaves the viewport unable to show a full screen of history.
    pub const InitOptions = struct {
        scrollback_lines: u16,
    };

    /// `init` with an explicit ring capacity. Worth reaching for when a test
    /// needs to exercise ring *wraparound* — set it just above `height` and a
    /// handful of writes will lap the buffer, which is where line-mapping bugs
    /// live (#393).
    pub fn initWithScrollback(allocator: Allocator, width: u16, height: u16, options: InitOptions) !VTerm {
        const total_cells = @as(usize, options.scrollback_lines) * @as(usize, width);
        const cells = try allocator.alloc(Cell, total_cells);

        // Initialize all cells to empty
        @memset(cells, Cell.empty());

        return VTerm{
            .allocator = allocator,
            .cells = cells,
            .scrollback_lines = options.scrollback_lines,
            .width = width,
            .height = height,
            .total_lines_written = 0,
            .virtual_cursor_y = 0,
            .viewport_offset = 0,
            .cursor = Position.init(0, 0),

            // Parser state
            .parser_state = .ground,
            .params = [_]u16{0} ** 16,
            .param_count = 0,
            .private_sequence = false,

            .utf8_partial = undefined,
            .utf8_partial_have = 0,
            .utf8_partial_expected = 0,

            // Text attributes
            .current_fg = 7, // Default white
            .current_bg = 0, // Default black
            .current_bold = false,
            .current_italic = false,
            .current_underline = false,

            // Terminal modes
            .alt_screen = false,
            .cursor_visible = true,
            .autowrap = true,
        };
    }

    /// Frees the cell buffer. Text returned by `getAllText`/`getLine`/`getRegion`
    /// was allocated separately by the caller's allocator and is not freed here.
    pub fn deinit(self: *VTerm) void {
        self.allocator.free(self.cells);
    }

    // Scrollback navigation
    /// Where the viewport currently sits in history — see `ScrollPosition`.
    pub fn getScrollbackPosition(self: *VTerm) ScrollPosition {
        return ScrollPosition{
            .current_line = if (self.total_lines_written > 0) self.total_lines_written - 1 else 0,
            .total_lines = self.total_lines_written,
            .at_bottom = self.viewport_offset == 0,
        };
    }

    /// Scroll the viewport back into history by `lines`, clamped so it can never
    /// pass the oldest line the ring still holds. Saturates rather than erroring:
    /// scrolling further than there is history leaves you at the top.
    pub fn scrollViewportUp(self: *VTerm, lines: u16) void {
        // Scroll viewport up in history (user scrollback). Only the most
        // recent `scrollback_lines` are retained — older lines have been
        // overwritten by the ring and can't be scrolled to.
        const retained = @min(self.total_lines_written, @as(u32, self.scrollback_lines));
        const max_scroll_lines = if (retained > self.height)
            retained - self.height
        else
            0;
        const max_scroll = @as(i32, @intCast(max_scroll_lines));
        self.viewport_offset = @max(-max_scroll, self.viewport_offset - @as(i32, @intCast(lines)));
    }

    /// Scroll the viewport `lines` toward the present, clamped at the live
    /// bottom.
    pub fn scrollViewportDown(self: *VTerm, lines: u16) void {
        // Scroll viewport down toward present
        self.viewport_offset = @min(0, self.viewport_offset + @as(i32, @intCast(lines)));
    }

    /// Jump the viewport to the present. `write` does this implicitly — new
    /// output always pulls the view back to the bottom, as a real terminal does.
    pub fn scrollToBottom(self: *VTerm) void {
        // Jump to bottom (present)
        self.viewport_offset = 0;
    }

    /// `scrollViewportUp` by one full screen.
    pub fn pageUp(self: *VTerm) void {
        self.scrollViewportUp(self.height);
    }

    /// `scrollViewportDown` by one full screen.
    pub fn pageDown(self: *VTerm) void {
        self.scrollViewportDown(self.height);
    }

    // Basic Cell Operations (viewport-relative)
    /// The cell at viewport row `y`, column `x`. Out of bounds — or a row the
    /// ring no longer holds — reads as an empty cell rather than erroring, so a
    /// test asserting on a region larger than the content still gets spaces
    /// instead of a crash.
    pub fn getCell(self: *VTerm, x: u16, y: u16) Cell {
        if (!self.isValidPos(x, y)) return Cell.empty();
        const buffer_line = self.viewportToBuffer(y) orelse return Cell.empty();
        const idx = @as(usize, buffer_line) * self.width + x;
        return self.cells[idx];
    }

    /// Overwrite the cell at viewport row `y`, column `x`; silently ignored out
    /// of bounds. Paints the grid directly without touching the cursor or the
    /// parser — for seeding a fixture. Use `write` to model what a program did.
    pub fn setCell(self: *VTerm, x: u16, y: u16, cell: Cell) void {
        if (!self.isValidPos(x, y)) return;
        const buffer_line = self.viewportToBuffer(y) orelse return;
        const idx = @as(usize, buffer_line) * self.width + x;
        self.cells[idx] = cell;
    }

    /// Extend the written-line count to cover `line`, clearing each
    /// newly-entered ring row first — a lapped row still holds the cells of
    /// the line it carried `scrollback_lines` ago, which must not show
    /// through on the fresh line (#393). No-op for already-open lines.
    fn openLine(self: *VTerm, line: u32) void {
        while (self.total_lines_written < line + 1) {
            const row = @as(usize, self.bufferLineIndex(self.total_lines_written)) * self.width;
            @memset(self.cells[row .. row + self.width], Cell.empty());
            self.total_lines_written += 1;
        }
    }

    // Direct buffer writing for content (not viewport-relative)
    fn setCellDirect(self: *VTerm, x: u16, logical_line: u32, cell: Cell) void {
        if (x >= self.width) return;
        const buffer_line = self.bufferLineIndex(logical_line);
        const idx = @as(usize, buffer_line) * self.width + x;
        self.cells[idx] = cell;
    }

    /// Write one codepoint at the cursor and advance it, honoring wide glyphs
    /// (a second continuation cell) and DECAWM (wrap vs. clamp at the right
    /// edge). This is the text path `write` funnels into once the parser has
    /// decoded a character — call it directly only to bypass escape-sequence
    /// parsing entirely.
    pub fn putChar(self: *VTerm, char: u21) void {
        var width = charWidth(char);

        // A 2-cell character cannot fit on a terminal narrower than 2 columns.
        // Degrade it to a single-cell write so the `self.width - 2` math below
        // never underflows u16 (and the continuation `cursor.x + 1` never
        // overflows) on a 1-column terminal (#529). The wide glyph still lands
        // in the single available cell; no continuation cell is written.
        if (width == 2 and self.width < 2) width = 1;

        // Handle delayed wrapping: if cursor is at width, wrap before writing
        // (with DECAWM off, clamp to the last column and overwrite instead)
        if (self.cursor.x >= self.width) {
            if (self.autowrap) {
                self.cursor.x = 0;
                self.virtual_cursor_y += 1;
                self.cursor.y = @min(self.virtual_cursor_y, self.height - 1);
            } else {
                self.cursor.x = self.width - 1;
            }
        }

        // For wide characters, check if there's room for both cells
        if (width == 2 and self.cursor.x >= self.width - 1) {
            if (self.autowrap) {
                // Not enough room, wrap to next line
                self.cursor.x = 0;
                self.virtual_cursor_y += 1;
                self.cursor.y = @min(self.virtual_cursor_y, self.height - 1);
            } else {
                self.cursor.x = self.width - 2;
            }
        }

        // Track the line being written to, clearing it if it re-enters a
        // lapped ring row.
        self.openLine(self.virtual_cursor_y);

        // Write character at current position
        const cell = Cell.withAttributes(char, self.current_fg, self.current_bg, self.current_bold, self.current_italic, self.current_underline);
        // Use direct buffer writing based on virtual cursor position
        self.setCellDirect(self.cursor.x, self.virtual_cursor_y, cell);

        // For wide characters, write continuation cell
        if (width == 2) {
            const continuation_cell = Cell.wideContinuation(self.current_fg, self.current_bg, self.current_bold, self.current_italic, self.current_underline);
            self.setCellDirect(self.cursor.x + 1, self.virtual_cursor_y, continuation_cell);
        }

        // Advance cursor by character width
        self.advanceCursorByWidth(width);
    }

    fn advanceCursor(self: *VTerm) void {
        self.advanceCursorByWidth(1);
    }

    fn advanceCursorByWidth(self: *VTerm, width: u8) void {
        self.cursor.x += width;
        // Wrap when cursor reaches width (immediate wrapping for putChar)
        // This allows cursor to be positioned at width for delayed wrapping in write()
        if (self.cursor.x >= self.width) {
            if (!self.autowrap) {
                // DECAWM off: stay on this line, clamped to the last column
                self.cursor.x = self.width - 1;
                return;
            }
            // Check if we're already at the last line - if so, clamp cursor instead of wrapping
            if (self.cursor.y >= self.height - 1 and self.virtual_cursor_y >= self.height - 1) {
                // At bottom of terminal - clamp cursor to last position instead of wrapping
                self.cursor.x = self.width - 1;
            } else {
                // Normal wrapping behavior
                self.cursor.x = 0;
                self.virtual_cursor_y += 1;
                self.cursor.y = @min(self.virtual_cursor_y, self.height - 1);
                self.openLine(self.virtual_cursor_y);
            }
        } else {
            // Update cursor.y to match virtual_cursor_y when not wrapping
            self.cursor.y = @min(self.virtual_cursor_y, self.height - 1);
        }
    }

    // Cursor Management
    /// The cursor's viewport-relative position. Note this is where the *next*
    /// character lands, which after filling a row may be one column past the
    /// last one written (delayed wrap) — `cursorAt` compares against exactly
    /// this value.
    pub fn getCursor(self: VTerm) Position {
        return self.cursor;
    }

    /// Move the cursor to viewport row `y`, column `x`, clamped to the grid.
    /// Models CSI CUP; the write position follows, so output after a move lands
    /// on the row the viewport shows even once the buffer has scrolled (#504).
    pub fn moveCursor(self: *VTerm, x: u16, y: u16) void {
        // Clamp to valid bounds
        self.cursor.x = @min(x, self.width - 1);
        self.cursor.y = @min(y, self.height - 1);
        // Map the viewport-relative row to the absolute logical line the write
        // path addresses, so output after repositioning lands on the row the
        // viewport shows even once the buffer has scrolled (#504).
        self.virtual_cursor_y = self.viewportToLogicalLine(self.cursor.y);
    }

    // Screen Operations
    /// Blank every cell — the whole ring, not just the viewport — and home the
    /// cursor. Scrollback does not survive this, so it is a harder reset than
    /// the `ESC[2J` a program would send.
    pub fn clear(self: *VTerm) void {
        @memset(self.cells, Cell.empty());
        self.cursor = Position.init(0, 0);
        // Keep the write position (virtual_cursor_y) in sync with the reset
        // cursor, as CUP/moveCursor does — otherwise post-clear writes key off a
        // stale virtual_cursor_y and land on the pre-clear bottom line (#571).
        self.virtual_cursor_y = self.viewportToLogicalLine(self.cursor.y);
    }

    // Resize Support
    /// Change the terminal's dimensions, keeping every retained line. Content is
    /// **not** reflowed: a line longer than the new width is truncated, and
    /// narrowing then widening does not restore it — matching what a terminal
    /// without reflow does, and keeping the absolute line→ring-row mapping
    /// intact across the resize. Use it to model SIGWINCH.
    pub fn resize(self: *VTerm, new_width: u16, new_height: u16) !void {
        // The cell buffer holds the whole scrollback (scrollback_lines ×
        // width), not just the viewport — the new buffer must too, or every
        // `line % scrollback_lines` lookup past the new viewport indexes off
        // the end of the allocation.
        const new_total = @as(usize, self.scrollback_lines) * @as(usize, new_width);
        const new_cells = try self.allocator.alloc(Cell, new_total);
        @memset(new_cells, Cell.empty());

        // Copy every retained logical line (not just the viewport). Each line
        // keeps its ring row (`line % scrollback_lines`), so the absolute
        // line→row mapping survives the resize unchanged.
        const copy_width = @min(self.width, new_width);
        const retained: u32 = @min(self.total_lines_written, self.scrollback_lines);
        var logical: u32 = self.total_lines_written - retained;
        while (logical < self.total_lines_written) : (logical += 1) {
            const row = @as(usize, self.bufferLineIndex(logical));
            const old_start = row * self.width;
            const new_start = row * new_width;
            @memcpy(new_cells[new_start .. new_start + copy_width], self.cells[old_start .. old_start + copy_width]);
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.width = new_width;
        self.height = new_height;

        // Clamp cursor to new bounds
        self.cursor.x = @min(self.cursor.x, new_width - 1);
        self.cursor.y = @min(self.cursor.y, new_height - 1);
    }

    // ===== Parser Implementation =====

    // Main parsing interface
    /// Feed the terminal the bytes a program wrote: text is laid into cells,
    /// escape sequences update cursor/attributes/modes. **The** entry point —
    /// everything else here reads the state this produces.
    ///
    /// Chunk boundaries don't matter. Parser state (and a UTF-8 sequence split
    /// across the boundary) carries between calls, so `write("\x1b[")` then
    /// `write("31mred")` is identical to one call — which is what makes it safe
    /// to feed whatever a pipe or PTY happened to hand you.
    ///
    /// Never fails: an unknown or malformed sequence is consumed and dropped,
    /// as a real terminal does. It has no back channel, so a program's queries
    /// (cursor-position reports, DA) are parsed and silently discarded rather
    /// than answered.
    pub fn write(self: *VTerm, bytes: []const u8) void {
        // Auto-scroll to bottom when writing new content
        if (self.viewport_offset != 0) {
            self.scrollToBottom();
        }

        var i: usize = 0;
        while (i < bytes.len) {
            const byte = bytes[i];

            switch (self.parser_state) {
                .ground => {
                    // Check if this is a UTF-8 multi-byte character
                    if (byte >= 0x80) {
                        if (self.utf8_partial_expected > 0) {
                            // Continuation of a sequence split across write() calls.
                            self.utf8_partial[self.utf8_partial_have] = byte;
                            self.utf8_partial_have += 1;
                            i += 1;
                            if (self.utf8_partial_have == self.utf8_partial_expected) {
                                const seq = self.utf8_partial[0..self.utf8_partial_expected];
                                self.utf8_partial_expected = 0;
                                self.utf8_partial_have = 0;
                                const char = std.unicode.utf8Decode(seq) catch continue;
                                self.putChar(char);
                            }
                            continue;
                        }

                        // This is part of a UTF-8 sequence
                        const utf8_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                            i += 1;
                            continue;
                        };

                        if (i + utf8_len <= bytes.len) {
                            // Decode the UTF-8 character
                            const char = std.unicode.utf8Decode(bytes[i .. i + utf8_len]) catch {
                                i += 1;
                                continue;
                            };
                            self.putChar(char);
                            i += utf8_len;
                        } else {
                            // The sequence's tail lies beyond this write();
                            // stash what we have and finish on the next call.
                            const avail = bytes.len - i;
                            @memcpy(self.utf8_partial[0..avail], bytes[i..]);
                            self.utf8_partial_have = @intCast(avail);
                            self.utf8_partial_expected = @intCast(utf8_len);
                            i = bytes.len;
                        }
                    } else {
                        // An ASCII byte aborts any pending partial sequence —
                        // the stream was invalid; drop the fragment.
                        self.utf8_partial_expected = 0;
                        self.utf8_partial_have = 0;
                        self.handleGround(byte);
                        i += 1;
                    }
                },
                .escape => {
                    self.handleEscape(byte);
                    i += 1;
                },
                .csi => {
                    self.handleCSI(byte);
                    i += 1;
                },
                .osc => {
                    self.handleOsc(byte);
                    i += 1;
                },
                .osc_escape => {
                    self.handleOscEscape(byte);
                    i += 1;
                },
            }
        }
    }

    fn handleGround(self: *VTerm, byte: u8) void {
        switch (byte) {
            0x1B => self.parser_state = .escape, // ESC
            '\r' => self.cursor.x = 0, // Carriage return
            '\n' => { // Line feed
                self.cursor.x = 0; // Move to start of next line
                self.virtual_cursor_y += 1;
                self.cursor.y = @min(self.virtual_cursor_y, self.height - 1);
                // Each newline moves us to a new line
                // total_lines_written tracks how many lines we have content for
                self.openLine(self.virtual_cursor_y);
            },
            '\t' => { // Tab (move to next 8-column boundary)
                const next_tab = ((self.cursor.x / 8) + 1) * 8;
                self.cursor.x = @min(next_tab, self.width - 1);
            },
            0x08 => { // Backspace
                if (self.cursor.x > 0) {
                    self.cursor.x -= 1;
                }
            },
            else => {
                // Regular character
                if (byte >= 0x20 and byte < 0x7F) {
                    // Printable ASCII characters
                    self.putChar(@as(u21, byte));
                }
                // Control characters 1-26 are ignored (not printed) - normal terminal behavior
            },
        }
    }

    fn handleEscape(self: *VTerm, byte: u8) void {
        switch (byte) {
            '[' => {
                // Start CSI sequence
                self.parser_state = .csi;
                // Reset parameters
                self.params = [_]u16{0} ** 16;
                self.param_count = 0;
                self.private_sequence = false;
            },
            ']' => {
                // Start OSC (Operating System Command) sequence: consume and
                // discard the payload rather than leaking it as printed text.
                self.parser_state = .osc;
            },
            // String sequences that carry an arbitrary payload terminated by
            // ST (ESC \): DCS (`ESC P`, e.g. tmux passthrough, Sixel, terminfo
            // replies), SOS (`ESC X`), PM (`ESC ^`), APC (`ESC _`). vterm has
            // no use for their contents, but must consume the payload instead
            // of dropping it to ground where it prints as literal cells. Reuse
            // the OSC consume-until-ST machinery.
            'P', 'X', '^', '_' => {
                self.parser_state = .osc;
            },
            else => {
                // Invalid character, abort sequence
                self.parser_state = .ground;
            },
        }
    }

    // OSC payloads are terminated by BEL (0x07) or ST (ESC \). Both are
    // consumed and discarded — vterm has no use for window-title / clipboard
    // / hyperlink OSC content, but it must not fall through to `handleGround`
    // and print the raw bytes as literal cells.
    fn handleOsc(self: *VTerm, byte: u8) void {
        switch (byte) {
            0x07 => self.parser_state = .ground, // BEL terminator
            0x1B => self.parser_state = .osc_escape, // Maybe start of ST (ESC \)
            else => {}, // Discard payload byte
        }
    }

    fn handleOscEscape(self: *VTerm, byte: u8) void {
        switch (byte) {
            '\\' => self.parser_state = .ground, // ST terminator (ESC \)
            else => {
                // Not a valid ST. Per the spec, the ESC terminates the OSC and
                // introduces a new escape sequence. Terminate the OSC and feed
                // this byte back through the escape state machine so a genuine
                // `ESC [`/`ESC ]` inside an unterminated OSC is re-parsed
                // (e.g. an unterminated OSC followed by `ESC[2J` must still
                // clear the screen) rather than being swallowed as payload.
                self.parser_state = .escape;
                self.handleEscape(byte);
            },
        }
    }

    fn handleCSI(self: *VTerm, byte: u8) void {
        switch (byte) {
            '0'...'9' => {
                // Collect digit
                self.collectDigit(byte - '0');
            },
            ';' => {
                // Next parameter
                self.nextParameter();
            },
            '?' => {
                // Private sequence marker (must come before parameters)
                if (self.param_count == 0 and self.params[0] == 0) {
                    self.private_sequence = true;
                }
            },
            // Colon sub-parameter separator (e.g. `ESC[38:2:255:0:0m` colon
            // truecolor). vterm does not distinguish sub-parameters from
            // parameters, so treat a colon like a semicolon: start a new
            // parameter slot. This lets colon-form extended colors reach
            // handleSGR as separate params (`38`, `2`, `255`, …) and be
            // consumed the same way as the semicolon form (#505).
            ':' => {
                self.nextParameter();
            },
            // Other parameter bytes 0x3C-0x3F (`<=>?`). Consume and discard;
            // remain in the CSI state so the final byte is not leaked.
            '<'...'>' => {
                // Consume and discard; remain in the CSI state.
            },
            // Intermediate bytes: 0x20-0x2F (space, `!"#$%&'()*+,-./`). These
            // appear before the final byte in sequences like `ESC[1 q`
            // (DECSCUSR) or `ESC[!p` (DECSTR). Consume them so the final byte
            // terminates the sequence cleanly instead of leaking.
            0x20...0x2F => {
                // Consume and discard; remain in the CSI state.
            },
            // CSI final bytes: 0x40-0x7E (@A-Z[\]^_`a-z{|}~)
            // All bytes in this range are valid CSI final bytes per ANSI spec
            0x40...0x7E => {
                // Final character - execute command if supported, otherwise ignore
                self.executeCSI(byte);
                self.parser_state = .ground;
            },
            else => {
                // Truly invalid character (control char, etc), abort sequence.
                // Only C0 control bytes below the parameter range reach here
                // now that intermediates (0x20-0x2F) and parameter bytes
                // (0x30-0x3F) are consumed above.
                self.parser_state = .ground;
                self.handleGround(byte);
            },
        }
    }

    // Parameter collection helpers
    fn collectDigit(self: *VTerm, digit: u8) void {
        if (self.param_count < self.params.len) {
            const current = self.params[self.param_count];
            // Prevent overflow by capping at max reasonable terminal size (9999)
            // This prevents u16 overflow while allowing reasonable cursor positions
            if (current <= 999) { // 999 * 10 + 9 = 9999, safely under u16 max
                self.params[self.param_count] = current * 10 + digit;
            }
            // If current > 999, ignore additional digits to prevent overflow
        }
    }

    fn nextParameter(self: *VTerm) void {
        if (self.param_count < self.params.len - 1) {
            self.param_count += 1;
        }
    }

    fn getParam(self: *VTerm, index: usize, default: u16) u16 {
        if (index > self.param_count) return default;
        const val = self.params[index];
        return if (val == 0) default else val;
    }

    // CSI command execution
    fn executeCSI(self: *VTerm, command: u8) void {
        switch (command) {
            // Cursor Movement
            'A' => { // CUU - Cursor Up
                const n = self.getParam(0, 1);
                self.cursor.y = if (n > self.cursor.y) 0 else self.cursor.y - @as(u16, @intCast(n));
                // Keep the write position (virtual_cursor_y) in sync, as CUP does,
                // so text written after moving up overwrites the right rows.
                // Convert the viewport row to an absolute logical line (#504).
                self.virtual_cursor_y = self.viewportToLogicalLine(self.cursor.y);
            },
            'B' => { // CUD - Cursor Down
                const n = self.getParam(0, 1);
                self.cursor.y = @min(self.cursor.y + @as(u16, @intCast(n)), self.height - 1);
                // Convert the viewport row to an absolute logical line (#504).
                self.virtual_cursor_y = self.viewportToLogicalLine(self.cursor.y);
            },
            'C' => { // CUF - Cursor Forward
                const n = self.getParam(0, 1);
                self.cursor.x = @min(self.cursor.x + @as(u16, @intCast(n)), self.width - 1);
            },
            'D' => { // CUB - Cursor Back
                const n = self.getParam(0, 1);
                self.cursor.x = if (n > self.cursor.x) 0 else self.cursor.x - @as(u16, @intCast(n));
            },
            'H', 'f' => { // CUP - Cursor Position
                const row = self.getParam(0, 1);
                const col = self.getParam(1, 1);
                self.moveCursor(@min(col - 1, self.width - 1), @min(row - 1, self.height - 1));
            },

            // Erase Commands
            'J' => { // ED - Erase in Display
                const n = self.getParam(0, 0);
                switch (n) {
                    0 => self.eraseFromCursor(), // Cursor to end
                    1 => self.eraseToCursor(), // Start to cursor
                    2 => self.clear(), // Entire screen
                    else => {},
                }
            },
            'K' => { // EL - Erase in Line
                const n = self.getParam(0, 0);
                switch (n) {
                    0 => self.eraseLineFromCursor(),
                    1 => self.eraseLineToCursor(),
                    2 => self.clearLine(self.cursor.y),
                    else => {},
                }
            },

            // SGR - Select Graphic Rendition
            'm' => self.handleSGR(),

            // Private sequences (DEC) - handle h/l for mode setting
            'h' => {
                if (self.private_sequence) {
                    self.handlePrivateMode(true);
                }
            },
            'l' => {
                if (self.private_sequence) {
                    self.handlePrivateMode(false);
                }
            },

            else => {
                // Unknown command, ignore
            },
        }
    }

    // SGR (Select Graphic Rendition) handler
    fn handleSGR(self: *VTerm) void {
        if (self.param_count == 0 and self.params[0] == 0) {
            // No parameters means reset (SGR 0)
            self.current_fg = 7;
            self.current_bg = 0;
            self.current_bold = false;
            self.current_italic = false;
            self.current_underline = false;
            return;
        }

        // Process each parameter
        var i: usize = 0;
        while (i <= self.param_count) : (i += 1) {
            const param = self.params[i];
            switch (param) {
                0 => { // Reset
                    self.current_fg = 7;
                    self.current_bg = 0;
                    self.current_bold = false;
                    self.current_italic = false;
                    self.current_underline = false;
                },
                1 => self.current_bold = true,
                3 => self.current_italic = true,
                4 => self.current_underline = true,
                22 => self.current_bold = false,
                23 => self.current_italic = false,
                24 => self.current_underline = false,

                // Foreground colors
                30...37 => self.current_fg = @as(u8, @intCast(param - 30)),
                39 => self.current_fg = 7, // Default foreground

                // Background colors
                40...47 => self.current_bg = @as(u8, @intCast(param - 40)),
                49 => self.current_bg = 0, // Default background

                // Bright foreground colors
                90...97 => self.current_fg = @as(u8, @intCast(param - 90 + 8)),

                // Bright background colors
                100...107 => self.current_bg = @as(u8, @intCast(param - 100 + 8)),

                // Extended foreground / background color. The following
                // sub-params form a single logical value: `5;n` (256-color
                // palette index) or `2;r;g;b` (truecolor). Consume them as a
                // unit so they are never interpreted as independent SGR codes
                // (which would corrupt bold/italic/etc). Advance `i` past the
                // consumed sub-params (#505).
                38 => i += self.applyExtendedColor(i, true),
                48 => i += self.applyExtendedColor(i, false),

                else => {}, // Ignore unsupported SGR codes
            }
        }
    }

    /// Apply an extended-color SGR (`38`/`48`) whose selector is at index
    /// `start`, and return how many *additional* params were consumed so the
    /// caller can advance past them. `is_fg` selects foreground vs background.
    ///
    /// `5;n`   → 256-color palette index; modeled directly (fits u8).
    /// `2;r;g;b` → truecolor; the u8 cell color cannot hold RGB, so the value
    ///             is consumed and discarded (color left unchanged) rather than
    ///             corrupting other attributes.
    fn applyExtendedColor(self: *VTerm, start: usize, is_fg: bool) usize {
        const count: usize = self.param_count;
        // Need at least the color-space selector after 38/48.
        if (start + 1 > count) return 0;
        switch (self.params[start + 1]) {
            5 => {
                // 256-color: one index param.
                if (start + 2 > count) return 1;
                const idx: u8 = @truncate(self.params[start + 2]);
                if (is_fg) self.current_fg = idx else self.current_bg = idx;
                return 2;
            },
            2 => {
                // Truecolor: r;g;b (3 params). Consume up to 4 (selector + rgb),
                // clamped to what is actually present. Discarded — see doc.
                return @min(@as(usize, 4), count - start);
            },
            // Unknown color space; consume just the selector.
            else => return 1,
        }
    }

    // Private mode handling (DEC sequences)
    fn handlePrivateMode(self: *VTerm, enable: bool) void {
        // A combined sequence like `CSI ? 7;25;1049 h` carries multiple
        // modes in one escape; apply every param, not just the first
        // (mirrors the loop in handleSGR).
        var i: usize = 0;
        while (i <= self.param_count) : (i += 1) {
            const mode = self.params[i];
            switch (mode) {
                7 => self.autowrap = enable, // DECAWM auto-wrap
                25 => self.cursor_visible = enable, // Cursor visibility
                1049 => self.alt_screen = enable, // Alternate screen buffer
                else => {}, // Ignore other modes
            }
        }
    }

    // Erase helper functions
    fn eraseFromCursor(self: *VTerm) void {
        // Erase from the cursor to the end of the SCREEN (viewport rows only,
        // not the rest of the scrollback allocation). setCell/clearLine
        // translate viewport rows to buffer lines; cursor.y is a viewport y
        // and must never be used as a buffer index directly.
        self.eraseLineFromCursor();
        var y: u16 = self.cursor.y + 1;
        while (y < self.height) : (y += 1) {
            self.clearLine(y);
        }
    }

    fn eraseToCursor(self: *VTerm) void {
        // Erase from the start of the screen to the cursor, inclusive.
        var y: u16 = 0;
        while (y < self.cursor.y) : (y += 1) {
            self.clearLine(y);
        }
        self.eraseLineToCursor();
    }

    fn eraseLineFromCursor(self: *VTerm) void {
        // Erase from cursor to end of line
        var x = self.cursor.x;
        while (x < self.width) : (x += 1) {
            self.setCell(x, self.cursor.y, Cell.empty());
        }
    }

    fn eraseLineToCursor(self: *VTerm) void {
        // Erase from start of line to cursor
        var x: u16 = 0;
        while (x <= self.cursor.x) : (x += 1) {
            self.setCell(x, self.cursor.y, Cell.empty());
        }
    }

    fn clearLine(self: *VTerm, y: u16) void {
        // Clear entire line
        var x: u16 = 0;
        while (x < self.width) : (x += 1) {
            self.setCell(x, y, Cell.empty());
        }
    }

    // ===== Input Generation =====

    /// The bytes a real terminal emits for `key` — send these to the program
    /// under test. Lets an interactive test say `.arrow_up` rather than hardcode
    /// `"\x1b[A"`, so it does not depend on which of several legal encodings
    /// this harness picked.
    ///
    /// The returned slice points at a static per-key buffer, not the caller's
    /// memory: it stays valid, but a later call with the *same* key overwrites
    /// it. Copy it if two keystrokes must be held at once. An out-of-range
    /// function key (outside 1-12) or control char (outside 1-26) yields an
    /// empty slice rather than an error.
    pub fn inputKey(self: *VTerm, key: Key) []const u8 {
        _ = self; // VTerm not needed for key generation, kept for API consistency

        return switch (key) {
            // ASCII characters only
            .char => |c| {
                // Use a static buffer array indexed by character to avoid collision
                const char_static = struct {
                    var char_bufs: [256][1]u8 = [_][1]u8{[_]u8{0}} ** 256;
                };
                char_static.char_bufs[c][0] = c;
                return char_static.char_bufs[c][0..1];
            },

            // Arrow keys
            .arrow_up => "\x1b[A",
            .arrow_down => "\x1b[B",
            .arrow_right => "\x1b[C",
            .arrow_left => "\x1b[D",

            // Special keys
            .enter => "\r",
            .escape => "\x1b",

            // Function keys
            .function => |n| switch (n) {
                1 => "\x1b[11~", // F1
                2 => "\x1b[12~", // F2
                3 => "\x1b[13~", // F3
                4 => "\x1b[14~", // F4
                5 => "\x1b[15~", // F5
                6 => "\x1b[17~", // F6
                7 => "\x1b[18~", // F7
                8 => "\x1b[19~", // F8
                9 => "\x1b[20~", // F9
                10 => "\x1b[21~", // F10
                11 => "\x1b[23~", // F11
                12 => "\x1b[24~", // F12
                else => "", // Invalid function key
            },

            // Control characters
            .ctrl_char => |c| {
                if (c >= 1 and c <= 26) {
                    // Use a static buffer array indexed by character code to avoid collision
                    const ctrl_static = struct {
                        var ctrl_bufs: [27][1]u8 = [_][1]u8{[_]u8{0}} ** 27;
                    };
                    ctrl_static.ctrl_bufs[c][0] = c;
                    return ctrl_static.ctrl_bufs[c][0..1];
                } else {
                    return "";
                }
            },
        };
    }

    // ===== Testing API =====

    /// Snapshot the screen (text, cursor, dimensions) so a later state can be
    /// compared against it — the "before" half of a before/after assertion when
    /// keeping two live terminals around for `diff` would be overkill. Caller
    /// owns the result; call `TerminalState.deinit`.
    pub fn captureState(self: *VTerm, allocator: Allocator) !TerminalState {
        const content = try self.getAllText(allocator);
        return TerminalState{
            .content = content,
            .cursor = self.cursor,
            .dimensions = .{ .width = self.width, .height = self.height },
        };
    }

    /// Is `text` visible anywhere on screen? The workhorse assertion, and
    /// deliberately forgiving: the match walks the grid cell-by-cell and
    /// continues onto the next row at the right edge, so a string that wrapped
    /// mid-word is still found. That is usually what you want — a test about
    /// *what* was printed should not fail because the terminal was narrow.
    ///
    /// Consequences to know: it compares bytes to codepoints, so it only finds
    /// ASCII; it is allocation-free; and because it crosses row boundaries it
    /// can match two unrelated rows that happen to abut. When exact placement is
    /// the point, use `getLine` or `getRegion` instead.
    pub fn containsText(self: *VTerm, text: []const u8) bool {
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                if (self.matchesTextAt(text, @intCast(x), @intCast(y))) {
                    return true;
                }
            }
        }
        return false;
    }

    fn matchesTextAt(self: *VTerm, text: []const u8, start_x: u16, start_y: u16) bool {
        var current_x = start_x;
        var current_y = start_y;

        for (text) |expected_char| {
            // Check bounds
            if (current_y >= self.height) return false;
            if (current_x >= self.width) {
                // Wrap to next line
                current_x = 0;
                current_y += 1;
                if (current_y >= self.height) return false;
            }

            const cell = self.getCell(current_x, current_y);
            if (cell.char != expected_char) return false;

            current_x += 1;
        }
        return true;
    }

    /// Is the cursor exactly at viewport `(x, y)`? Remember it sits where the
    /// *next* character goes, so after writing `n` characters on an empty row
    /// the cursor is at column `n`, not `n - 1`.
    pub fn cursorAt(self: *VTerm, x: u16, y: u16) bool {
        return self.cursor.x == x and self.cursor.y == y;
    }

    /// The whole viewport as one flat `width * height` run of UTF-8 with **no
    /// row breaks** — empty cells become spaces, wide-glyph continuation cells
    /// contribute nothing. Row boundaries are implicit at multiples of `width`,
    /// which is what makes it the right substrate for substring search
    /// (`containsPattern`, `findPattern`) and the wrong one for reading output
    /// back: use `getAllLines` for that. Caller owns the result.
    pub fn getAllText(self: *VTerm, allocator: Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const cell = self.getCell(@intCast(x), @intCast(y));
                if (cell.wide_continuation) {
                    // Skip continuation cells, the wide character was already processed
                    continue;
                } else if (cell.char == 0) {
                    try result.append(allocator, ' ');
                } else if (cell.char < 128) {
                    // ASCII character
                    try result.append(allocator, @intCast(cell.char));
                } else {
                    // UTF-8 encode the character
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cell.char, &buf) catch {
                        try result.append(allocator, '?');
                        continue;
                    };
                    try result.appendSlice(allocator, buf[0..len]);
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// The full screen as text: each row's visible content (trailing spaces
    /// trimmed) joined by '\n', with all `height` rows present so trailing
    /// blank rows preserve the frame geometry. Unlike `getAllText`, which emits
    /// a flat width*height run with no row breaks, this reports the grid's real
    /// row structure — callers rendering or snapshotting a frame use it directly
    /// instead of re-deriving row breaks from geometry.
    pub fn getAllLines(self: *VTerm, allocator: Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        for (0..self.height) |y| {
            if (y > 0) try result.append(allocator, '\n');
            const line = try self.getLine(allocator, @intCast(y));
            defer allocator.free(line);
            try result.appendSlice(allocator, line);
        }

        return result.toOwnedSlice(allocator);
    }

    /// One viewport row as UTF-8, with trailing spaces trimmed — the exact-
    /// placement counterpart to `containsText`. A row past the bottom yields an
    /// empty slice rather than an error, so iterating `0..height` is always
    /// safe. Caller owns the result.
    pub fn getLine(self: *VTerm, allocator: Allocator, line_y: u16) ![]u8 {
        if (line_y >= self.height) return allocator.alloc(u8, 0);

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        for (0..self.width) |x| {
            const cell = self.getCell(@intCast(x), line_y);
            if (cell.wide_continuation) {
                // Skip continuation cells, the wide character was already processed
                continue;
            } else if (cell.char == 0) {
                try result.append(allocator, ' ');
            } else if (cell.char < 128) {
                // ASCII character
                try result.append(allocator, @intCast(cell.char));
            } else {
                // UTF-8 encode the character
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.char, &buf) catch {
                    try result.append(allocator, '?');
                    continue;
                };
                try result.appendSlice(allocator, buf[0..len]);
            }
        }

        // Get the content
        const final_content = try result.toOwnedSlice(allocator);

        // Trim trailing spaces by finding actual end
        var actual_len = final_content.len;
        while (actual_len > 0 and final_content[actual_len - 1] == ' ') {
            actual_len -= 1;
        }

        // Resize to actual content length
        const trimmed_result = try allocator.realloc(final_content, actual_len);
        return trimmed_result;
    }

    // Pattern matching methods
    /// Substring search with a few wildcards, for output whose exact text is
    /// not stable — a duration, a temp path, a generated id.
    ///
    /// Not a regex engine; the supported forms are checked in this order and do
    /// not compose:
    ///   - `.*`  — the parts either side must appear, in order (`"Error.*retry"`)
    ///   - `?`   — matches any single character
    ///   - `*`   — same as `.*`
    ///   - `^…`  — the pattern starts some row
    ///   - `…$`  — the pattern ends some row, ignoring trailing spaces
    ///   - otherwise, a plain substring
    ///
    /// The anchored forms work per row; every other form searches `getAllText`'s
    /// flat run, so a match may straddle a row boundary. Non-ASCII cells become
    /// `?` under the anchored forms. Allocates internally from the terminal's own
    /// allocator and cleans up; an allocation failure reports "no match".
    pub fn containsPattern(self: *VTerm, pattern: []const u8) bool {
        // Simplified pattern matching - supports * wildcard and basic patterns
        // For now, we'll do simple substring matching with * wildcard support

        // For testing purposes, use a temporary allocator
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const text = self.getAllText(allocator) catch return false;

        return simplePatternMatch(self, text, pattern);
    }

    fn simplePatternMatch(self: *VTerm, text: []const u8, pattern: []const u8) bool {
        // Handle different pattern types

        // Check for regex-like patterns with .* (matches any characters)
        if (std.mem.indexOf(u8, pattern, ".*")) |_| {
            // Split pattern by .* and check if all parts exist in order
            var parts = std.mem.tokenizeSequence(u8, pattern, ".*");
            var search_pos: usize = 0;
            while (parts.next()) |part| {
                // Skip number range patterns like [0-9]+ for now - just check if the rest matches
                if (std.mem.indexOf(u8, part, "[0-9]")) |_| {
                    // For now, skip the number pattern part
                    continue;
                }

                if (std.mem.indexOf(u8, text[search_pos..], part)) |pos| {
                    search_pos += pos + part.len;
                } else {
                    return false;
                }
            }
            return true;
        }

        // Handle ? wildcard patterns (simpler approach)
        if (std.mem.indexOf(u8, pattern, "?")) |_| {
            // Try to find a match anywhere in the text
            var text_idx: usize = 0;
            while (text_idx < text.len) {
                var t_i = text_idx;
                var p_i: usize = 0;
                var matches = true;

                while (p_i < pattern.len and t_i < text.len and matches) {
                    if (pattern[p_i] == '?') {
                        // Skip any single character
                        t_i += 1;
                        p_i += 1;
                    } else if (pattern[p_i] == text[t_i]) {
                        t_i += 1;
                        p_i += 1;
                    } else {
                        matches = false;
                    }
                }

                if (matches and p_i == pattern.len) {
                    return true;
                }

                text_idx += 1;
            }
            return false;
        }

        // Handle * wildcard patterns (simple approach)
        if (std.mem.indexOf(u8, pattern, "*")) |_| {
            var parts = std.mem.tokenizeScalar(u8, pattern, '*');
            var search_pos: usize = 0;
            while (parts.next()) |part| {
                if (std.mem.indexOf(u8, text[search_pos..], part)) |pos| {
                    search_pos += pos + part.len;
                } else {
                    return false;
                }
            }
            return true;
        }

        // Handle line anchors
        if (std.mem.startsWith(u8, pattern, "^")) {
            // Line start anchor - check if pattern starts any terminal row
            const pat = pattern[1..];

            // Check each terminal row
            for (0..self.height) |row| {
                // Get the row as a string
                var line_buf: std.ArrayList(u8) = .empty;
                defer line_buf.deinit(self.allocator);

                for (0..self.width) |col| {
                    const cell = self.getCell(@intCast(col), @intCast(row));
                    if (cell.char == 0) {
                        line_buf.append(self.allocator, ' ') catch break;
                    } else if (cell.char < 128) {
                        line_buf.append(self.allocator, @intCast(cell.char)) catch break;
                    } else {
                        // UTF-8 character - for simplicity, skip in pattern matching
                        line_buf.append(self.allocator, '?') catch break;
                    }
                }

                const line = line_buf.toOwnedSlice(self.allocator) catch continue;
                defer self.allocator.free(line);

                if (std.mem.startsWith(u8, line, pat)) {
                    return true;
                }
            }
            return false;
        }
        if (std.mem.endsWith(u8, pattern, "$")) {
            // Line end anchor - check if pattern is at end of any terminal row
            const pat = pattern[0 .. pattern.len - 1];

            // Check each terminal row (since \n moves cursor but doesn't store \n in cells)
            for (0..self.height) |row| {
                // Get the row as a string and trim trailing spaces
                var line_buf: std.ArrayList(u8) = .empty;
                defer line_buf.deinit(self.allocator);

                for (0..self.width) |col| {
                    const cell = self.getCell(@intCast(col), @intCast(row));
                    if (cell.char == 0) {
                        line_buf.append(self.allocator, ' ') catch break;
                    } else if (cell.char < 128) {
                        line_buf.append(self.allocator, @intCast(cell.char)) catch break;
                    } else {
                        // UTF-8 character - for simplicity, skip in pattern matching
                        line_buf.append(self.allocator, '?') catch break;
                    }
                }

                const line = line_buf.toOwnedSlice(self.allocator) catch continue;
                defer self.allocator.free(line);

                // Trim trailing spaces
                var trimmed = line;
                while (trimmed.len > 0 and trimmed[trimmed.len - 1] == ' ') {
                    trimmed = trimmed[0 .. trimmed.len - 1];
                }

                if (std.mem.endsWith(u8, trimmed, pat)) {
                    return true;
                }
            }

            return false;
        }

        // No special pattern - simple substring search
        return std.mem.indexOf(u8, text, pattern) != null;
    }

    /// Where a pattern appears, as grid positions — for asserting *placement*
    /// rather than presence (a label in the right column, a spinner on the last
    /// row).
    ///
    /// Two limits worth knowing before you rely on it: it reports the **first**
    /// occurrence only (the returned slice holds at most one position, despite
    /// the plural), and for a `.*` pattern it searches only the fixed part
    /// *before* the `.*`. Byte offsets are mapped back through the same per-cell
    /// accounting `getAllText` uses, so positions stay cell-accurate for wide
    /// and multibyte content. Caller owns the returned slice.
    pub fn findPattern(self: *VTerm, allocator: Allocator, pattern: []const u8) ![]Position {
        // Simplified implementation - find first occurrence
        var positions: std.ArrayList(Position) = .empty;
        errdefer positions.deinit(allocator);

        const text = try self.getAllText(allocator);
        defer allocator.free(text);

        // For regex patterns with .*, extract the fixed parts and search for them
        var search_pattern = pattern;
        if (std.mem.indexOf(u8, pattern, ".*")) |_| {
            // For "Error.*[0-9]+", just search for "Error" as a simple approach
            if (std.mem.indexOf(u8, pattern, ".*")) |pos| {
                search_pattern = pattern[0..pos];
            }
        }

        if (std.mem.indexOf(u8, text, search_pattern)) |index| {
            // `index` is a byte offset into getAllText()'s output, which UTF-8
            // encodes multibyte glyphs and skips wide-continuation cells. Walk
            // the grid the same way to map the byte offset back to a cell.
            try positions.append(allocator, self.byteOffsetToPosition(index));
        }

        return positions.toOwnedSlice(allocator);
    }

    /// Map a byte offset in getAllText()'s output back to the terminal cell
    /// that produced it. Mirrors getAllText()'s per-cell byte accounting so
    /// positions stay cell-accurate for wide (CJK/emoji) and multibyte content.
    fn byteOffsetToPosition(self: *VTerm, target: usize) Position {
        var offset: usize = 0;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const cell = self.getCell(@intCast(x), @intCast(y));
                if (cell.wide_continuation) {
                    // Skipped by getAllText — consumes no bytes.
                    continue;
                }
                const byte_len: usize = if (cell.char == 0 or cell.char < 128)
                    1
                else
                    std.unicode.utf8CodepointSequenceLength(cell.char) catch 1;

                if (target < offset + byte_len) {
                    return Position{ .x = @intCast(x), .y = @intCast(y) };
                }
                offset += byte_len;
            }
        }
        // Offset past the end: report the last cell.
        return Position{
            .x = if (self.width > 0) self.width - 1 else 0,
            .y = if (self.height > 0) self.height - 1 else 0,
        };
    }

    /// `containsText` with ASCII case folding — for text whose capitalization is
    /// not the thing under test (an "Error:"/"error:" prefix, a theme that
    /// upcases headings). Unlike `containsText` this searches the flat text run,
    /// so it also matches across a wrap. Non-ASCII case is not folded.
    pub fn containsTextIgnoreCase(self: *VTerm, text: []const u8) bool {
        // For testing purposes, use a temporary allocator
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const content = self.getAllText(allocator) catch return false;

        // Simple case-insensitive search
        return containsIgnoreCase(content, text);
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;

        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            var matches = true;
            for (needle, 0..) |char, j| {
                const h_char = std.ascii.toLower(haystack[i + j]);
                const n_char = std.ascii.toLower(char);
                if (h_char != n_char) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    // Region testing methods
    /// Assert a rectangle of the screen renders exactly `expected` (rows joined
    /// by `\n`, as `getRegion` produces). Fails through
    /// `std.testing.expectEqualStrings`, so a mismatch prints a character-level
    /// diff — which is why this beats comparing `getRegion`'s output yourself.
    pub fn expectRegionEquals(self: *VTerm, x: u16, y: u16, width: u16, height: u16, expected: []const u8) !void {
        const testing = std.testing;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const actual = try self.getRegion(allocator, x, y, width, height);
        defer allocator.free(actual);

        try testing.expectEqualStrings(expected, actual);
    }

    /// A `width` x `height` rectangle anchored at viewport `(x, y)`, rows joined
    /// by `\n`. The natural unit for a boxed widget or a panel: assert the box
    /// and ignore whatever else shares the screen.
    ///
    /// Rows keep their full width — trailing spaces are **not** trimmed here (a
    /// region's shape is the point), which is the difference from `getLine`.
    /// Cells outside the grid render as spaces, so a region may safely overhang.
    /// Caller owns the result.
    pub fn getRegion(self: *VTerm, allocator: Allocator, x: u16, y: u16, width: u16, height: u16) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        for (0..height) |row| {
            if (row > 0) {
                try result.append(allocator, '\n');
            }
            for (0..width) |col| {
                const cell_x = x + @as(u16, @intCast(col));
                const cell_y = y + @as(u16, @intCast(row));

                if (self.isValidPos(cell_x, cell_y)) {
                    const cell = self.getCell(cell_x, cell_y);
                    if (cell.char == 0) {
                        try result.append(allocator, ' ');
                    } else if (cell.char < 128) {
                        // ASCII character
                        try result.append(allocator, @intCast(cell.char));
                    } else {
                        // UTF-8 encode the character
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cell.char, &buf) catch {
                            try result.append(allocator, '?');
                            continue;
                        };
                        try result.appendSlice(allocator, buf[0..len]);
                    }
                } else {
                    try result.append(allocator, ' ');
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// `containsText` scoped to a rectangle — "the error is in the status bar",
    /// not merely "somewhere on screen".
    ///
    /// One sharp edge: only the match's *start* is constrained to the region.
    /// The match itself runs on across the full grid (and onto following rows),
    /// so a long string beginning inside the box still matches. Use
    /// `expectRegionEquals` when the region must contain it entirely.
    pub fn containsTextInRegion(self: *VTerm, text: []const u8, x: u16, y: u16, width: u16, height: u16) bool {
        for (0..height) |row| {
            for (0..width) |col| {
                const start_x = x + @as(u16, @intCast(col));
                const start_y = y + @as(u16, @intCast(row));

                // Check if text matches starting at this position
                if (self.matchesTextAt(text, start_x, start_y)) {
                    return true;
                }
            }
        }
        return false;
    }

    // Terminal comparison
    /// The result of `diff`: which viewport rows differ, in ascending order.
    /// Row granularity, not cell — the question it answers is "did the renderer
    /// repaint more than it had to", and rows are the unit a diffing renderer
    /// works in. Owns `changedLines`; call `deinit`.
    pub const TerminalDiff = struct {
        changedLines: []u16,
        allocator: Allocator,

        /// Frees `changedLines`. Takes the allocator as a parameter and ignores
        /// the `allocator` field, so pass the same one `diff` was given.
        pub fn deinit(self: *TerminalDiff, allocator: Allocator) void {
            allocator.free(self.changedLines);
        }

        /// Did any row change? False here means the two frames render the same
        /// *text* — `diff` does not compare color or attributes.
        pub fn hasDifferences(self: *const TerminalDiff) bool {
            return self.changedLines.len > 0;
        }
    };

    /// Which viewport rows differ between two terminals of the same size.
    /// Written for the layout engine's diffed live region (ADR-0013): render a
    /// frame into each, and this says whether an update touched only the rows it
    /// claimed to.
    ///
    /// Compares **codepoints only** — two rows differing solely in color or
    /// bold are reported as identical. Assert styling with `hasAttribute` /
    /// `getTextColor`. Mismatched dimensions return `error.DifferentDimensions`.
    /// Caller owns the result.
    pub fn diff(self: *VTerm, other: *VTerm, allocator: Allocator) !TerminalDiff {
        if (self.width != other.width or self.height != other.height) {
            return error.DifferentDimensions;
        }

        var changed: std.ArrayList(u16) = .empty;
        errdefer changed.deinit(allocator);

        for (0..self.height) |y| {
            var line_differs = false;
            for (0..self.width) |x| {
                const cell1 = self.getCell(@intCast(x), @intCast(y));
                const cell2 = other.getCell(@intCast(x), @intCast(y));

                if (cell1.char != cell2.char) {
                    line_differs = true;
                    break;
                }
            }

            if (line_differs) {
                try changed.append(allocator, @intCast(y));
            }
        }

        return TerminalDiff{
            .changedLines = try changed.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    // Attribute testing methods
    /// Does the cell at viewport `(x, y)` carry `attr`? The way to assert
    /// *styling* without asserting on SGR bytes — `hasAttribute(0, 0, .bold)`
    /// holds whether the renderer emitted `\x1b[1m` or `\x1b[0;1m`. Out of
    /// bounds is false, not an error.
    pub fn hasAttribute(self: *VTerm, x: u16, y: u16, attr: TextAttribute) bool {
        if (!self.isValidPos(x, y)) return false;
        const cell = self.getCell(x, y);

        return switch (attr) {
            .bold => cell.bold,
            .italic => cell.italic,
            .underline => cell.underline,
        };
    }

    /// The foreground color of the cell at viewport `(x, y)`; `.default` out of
    /// bounds. An explicitly-white foreground also reports `.default`, because 7
    /// *is* the default — see `Color`.
    pub fn getTextColor(self: *VTerm, x: u16, y: u16) Color {
        if (!self.isValidPos(x, y)) return .default;
        const cell = self.getCell(x, y);

        // Convert fg color value to Color enum
        // Note: colors are stored as 0-7 in cells, not 30-37
        // Default foreground is 7 (white)
        return switch (cell.fg) {
            0 => .black,
            1 => .red,
            2 => .green,
            3 => .yellow,
            4 => .blue,
            5 => .magenta,
            6 => .cyan,
            7 => .default, // 7 is the default foreground (white)
            else => .default,
        };
    }

    /// The background color of the cell at viewport `(x, y)`; `.default` out of
    /// bounds. An explicitly-black background also reports `.default`, because 0
    /// *is* the default — the mirror of `getTextColor`'s white, see `Color`.
    pub fn getBackgroundColor(self: *VTerm, x: u16, y: u16) Color {
        if (!self.isValidPos(x, y)) return .default;
        const cell = self.getCell(x, y);

        // Convert bg color value to Color enum
        // Note: colors are stored as 0-7 in cells, not 40-47
        // Default background is 0 (black)
        return switch (cell.bg) {
            0 => .default, // 0 is the default background (black)
            1 => .red,
            2 => .green,
            3 => .yellow,
            4 => .blue,
            5 => .magenta,
            6 => .cyan,
            7 => .white,
            else => .default,
        };
    }

    // Test helper functions
    /// One-liner for the common parser assertion: write `input` into a fresh
    /// 80x24 terminal and expect the whole screen to read `expected`. Because
    /// that is `getAllText`, `expected` must be the full flat 80*24 run —
    /// padding and all — so this suits short sequences whose *entire* effect is
    /// under test. Anything longer wants `getLine` or `expectRegionEquals`.
    /// Uses `std.testing.allocator`, so it also catches a leak in the path.
    pub fn expectOutput(input: []const u8, expected: []const u8) !void {
        const testing = std.testing;
        var term = try VTerm.init(testing.allocator, 80, 24);
        defer term.deinit();
        term.write(input);
        const actual = try term.getAllText(testing.allocator);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }
};
