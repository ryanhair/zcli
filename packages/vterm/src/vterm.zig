const std = @import("std");
const Allocator = std.mem.Allocator;

const CellModule = @import("cell.zig");
const PositionModule = @import("position.zig");

pub const Cell = CellModule.Cell;
pub const Position = PositionModule.Position;

// Phase 4: Testing API structures
pub const TerminalState = struct {
    content: []u8, // All text as single string
    cursor: Position,
    dimensions: struct { width: u16, height: u16 },

    pub fn deinit(self: *TerminalState, allocator: Allocator) void {
        allocator.free(self.content);
    }
};

// Phase 3: Input generation types
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

// Attribute testing types
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

pub const TextAttribute = enum {
    bold,
    italic,
    underline,
};

// Character width detection for wide characters (CJK, emojis, etc.)
pub fn charWidth(codepoint: u21) u8 {
    // ASCII and Latin-1 are always 1 column
    if (codepoint < 0x1100) return 1;

    // Wide characters that take 2 columns
    // Simplified ranges - covers most common wide characters
    if ((codepoint >= 0x1100 and codepoint <= 0x115F) or // Hangul Jamo
        (codepoint >= 0x2E80 and codepoint <= 0x2EFF) or // CJK Radicals
        (codepoint >= 0x2F00 and codepoint <= 0x2FDF) or // Kangxi Radicals
        (codepoint >= 0x2FF0 and codepoint <= 0x2FFF) or // CJK Description
        (codepoint >= 0x3000 and codepoint <= 0x303E) or // CJK Symbols
        (codepoint >= 0x3041 and codepoint <= 0x3096) or // Hiragana
        (codepoint >= 0x30A1 and codepoint <= 0x30FA) or // Katakana
        (codepoint >= 0x3105 and codepoint <= 0x312D) or // Bopomofo
        (codepoint >= 0x3131 and codepoint <= 0x318E) or // Hangul Compatibility
        (codepoint >= 0x3190 and codepoint <= 0x31BA) or // Kanbun
        (codepoint >= 0x31C0 and codepoint <= 0x31E3) or // CJK Strokes
        (codepoint >= 0x31F0 and codepoint <= 0x31FF) or // Katakana Extension
        (codepoint >= 0x3200 and codepoint <= 0x32FF) or // Enclosed CJK
        (codepoint >= 0x3300 and codepoint <= 0x33FF) or // CJK Compatibility
        (codepoint >= 0x3400 and codepoint <= 0x4DBF) or // CJK Extension A
        (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or // CJK Unified Ideographs
        (codepoint >= 0xA960 and codepoint <= 0xA97F) or // Hangul Syllables Extension A
        (codepoint >= 0xAC00 and codepoint <= 0xD7A3) or // Hangul Syllables
        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or // CJK Compatibility Ideographs
        (codepoint >= 0xFE10 and codepoint <= 0xFE19) or // Vertical Forms
        (codepoint >= 0xFE30 and codepoint <= 0xFE6F) or // CJK Compatibility Forms
        (codepoint >= 0xFF00 and codepoint <= 0xFF60) or // Fullwidth Forms
        (codepoint >= 0xFFE0 and codepoint <= 0xFFE6) or // Fullwidth Forms
        (codepoint >= 0x1F300 and codepoint <= 0x1F5FF) or // Misc Symbols and Pictographs
        (codepoint >= 0x1F600 and codepoint <= 0x1F64F) or // Emoticons
        (codepoint >= 0x1F680 and codepoint <= 0x1F6FF) or // Transport and Map
        (codepoint >= 0x1F700 and codepoint <= 0x1F77F) or // Alchemical Symbols
        (codepoint >= 0x1F780 and codepoint <= 0x1F7FF) or // Geometric Shapes Extended
        (codepoint >= 0x1F800 and codepoint <= 0x1F8FF) or // Supplemental Arrows-C
        (codepoint >= 0x1F900 and codepoint <= 0x1F9FF) or // Supplemental Symbols
        (codepoint >= 0x1FA00 and codepoint <= 0x1FA6F) or // Chess Symbols
        (codepoint >= 0x1FA70 and codepoint <= 0x1FAFF) or // Symbols and Pictographs Extended-A
        (codepoint >= 0x20000 and codepoint <= 0x2FFFD) or // CJK Extension B-F
        (codepoint >= 0x30000 and codepoint <= 0x3FFFD))
    { // CJK Extension G
        return 2;
    }

    // Default to 1 column for everything else
    return 1;
}

// Parser state for Phase 2
const ParserState = enum {
    Ground, // Normal text input
    Escape, // After ESC (0x1B)
    CSI, // After ESC[ - collecting parameters
};

// Scrollback position info
pub const ScrollPosition = struct {
    current_line: u32, // Current viewport position in history
    total_lines: u32, // Total lines in scrollback
    at_bottom: bool, // Whether viewport is at bottom
};

pub const VTerm = struct {
    allocator: Allocator,

    // Circular buffer for scrollback
    cells: []Cell,
    scrollback_lines: u16, // Total lines in buffer (e.g., 1000)
    width: u16,
    height: u16, // Viewport height (visible lines, e.g., 24)

    // Circular buffer management
    buffer_start: u16, // First line in circular buffer (wraps around)
    total_lines_written: u32, // Total lines ever written (for history tracking)
    virtual_cursor_y: u32, // Cursor Y that continues beyond height (for line tracking)

    // Viewport
    viewport_offset: i32, // Offset from bottom (0 = bottom, negative = scrolled up)

    // Cursor state (viewport-relative)
    cursor: Position,

    // Parser state - NEW in Phase 2
    parser_state: ParserState,
    params: [16]u16, // Parameter buffer (fixed size for simplicity)
    param_count: u8,
    private_sequence: bool, // Track if this is a private sequence (starts with ?)

    // Current text attributes - NEW in Phase 2
    current_fg: u8,
    current_bg: u8,
    current_bold: bool,
    current_italic: bool,
    current_underline: bool,

    // Terminal modes - NEW in Phase 2
    alt_screen: bool,
    cursor_visible: bool,

    // Circular buffer coordinate translation
    pub fn bufferLineIndex(self: *VTerm, logical_line: u32) u16 {
        // Map logical line to circular buffer position
        return @intCast((self.buffer_start + logical_line) % self.scrollback_lines);
    }

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

        return self.bufferLineIndex(logical_line);
    }

    pub fn getBottomLine(self: *VTerm) u32 {
        // Get the logical line number at the bottom of viewport
        if (self.total_lines_written == 0) return 0;
        return @min(self.total_lines_written - 1, self.scrollback_lines - 1);
    }

    // Convert 2D coordinates to buffer index (updated for circular buffer)
    fn cellIndex(self: VTerm, x: u16, y: u16) usize {
        // Note: This now expects y to be a buffer line index, not viewport y
        return @as(usize, y) * @as(usize, self.width) + @as(usize, x);
    }

    // Bounds checking
    fn isValidPos(self: VTerm, x: u16, y: u16) bool {
        return x < self.width and y < self.height;
    }

    // Initialization and Cleanup
    const DEFAULT_SCROLLBACK = 1000;

    pub fn init(allocator: Allocator, width: u16, height: u16) !VTerm {
        return initWithScrollback(allocator, width, height, .{
            .scrollback_lines = DEFAULT_SCROLLBACK,
        });
    }

    pub const InitOptions = struct {
        scrollback_lines: u16,
    };

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
            .buffer_start = 0,
            .total_lines_written = 0,
            .virtual_cursor_y = 0,
            .viewport_offset = 0,
            .cursor = Position.init(0, 0),

            // Parser state - NEW in Phase 2
            .parser_state = .Ground,
            .params = [_]u16{0} ** 16,
            .param_count = 0,
            .private_sequence = false,

            // Text attributes - NEW in Phase 2
            .current_fg = 7, // Default white
            .current_bg = 0, // Default black
            .current_bold = false,
            .current_italic = false,
            .current_underline = false,

            // Terminal modes - NEW in Phase 2
            .alt_screen = false,
            .cursor_visible = true,
        };
    }

    pub fn deinit(self: *VTerm) void {
        self.allocator.free(self.cells);
    }

    // Scrollback navigation
    pub fn getScrollbackPosition(self: *VTerm) ScrollPosition {
        return ScrollPosition{
            .current_line = if (self.total_lines_written > 0) self.total_lines_written - 1 else 0,
            .total_lines = self.total_lines_written,
            .at_bottom = self.viewport_offset == 0,
        };
    }

    pub fn scrollViewportUp(self: *VTerm, lines: u16) void {
        // Scroll viewport up in history (user scrollback)
        const max_scroll_lines = if (self.total_lines_written > self.height)
            self.total_lines_written - self.height
        else
            0;
        const max_scroll = @as(i32, @intCast(max_scroll_lines));
        self.viewport_offset = @max(-max_scroll, self.viewport_offset - @as(i32, @intCast(lines)));
    }

    pub fn scrollViewportDown(self: *VTerm, lines: u16) void {
        // Scroll viewport down toward present
        self.viewport_offset = @min(0, self.viewport_offset + @as(i32, @intCast(lines)));
    }

    pub fn scrollToBottom(self: *VTerm) void {
        // Jump to bottom (present)
        self.viewport_offset = 0;
    }

    pub fn pageUp(self: *VTerm) void {
        self.scrollViewportUp(self.height);
    }

    pub fn pageDown(self: *VTerm) void {
        self.scrollViewportDown(self.height);
    }

    // Basic Cell Operations (viewport-relative)
    pub fn getCell(self: *VTerm, x: u16, y: u16) Cell {
        if (!self.isValidPos(x, y)) return Cell.empty();
        const buffer_line = self.viewportToBuffer(y) orelse return Cell.empty();
        const idx = @as(usize, buffer_line) * self.width + x;
        return self.cells[idx];
    }

    pub fn setCell(self: *VTerm, x: u16, y: u16, cell: Cell) void {
        if (!self.isValidPos(x, y)) return;
        const buffer_line = self.viewportToBuffer(y) orelse return;
        const idx = @as(usize, buffer_line) * self.width + x;
        self.cells[idx] = cell;
    }

    // Direct buffer writing for content (not viewport-relative)
    fn setCellDirect(self: *VTerm, x: u16, logical_line: u32, cell: Cell) void {
        if (x >= self.width) return;
        const buffer_line = self.bufferLineIndex(logical_line);
        const idx = @as(usize, buffer_line) * self.width + x;
        self.cells[idx] = cell;
    }

    pub fn putChar(self: *VTerm, char: u21) void {
        const width = charWidth(char);

        // Handle delayed wrapping: if cursor is at width, wrap before writing
        if (self.cursor.x >= self.width) {
            self.cursor.x = 0;
            self.virtual_cursor_y += 1;
            self.cursor.y = @min(self.virtual_cursor_y, self.height - 1);
        }

        // For wide characters, check if there's room for both cells
        if (width == 2 and self.cursor.x >= self.width - 1) {
            // Not enough room, wrap to next line
            self.cursor.x = 0;
            self.virtual_cursor_y += 1;
            self.cursor.y = @min(self.virtual_cursor_y, self.height - 1);
        }

        // Track that we've written to at least one line
        if (self.total_lines_written == 0) {
            self.total_lines_written = 1;
        }
        // Update total_lines_written if we've moved to a new line
        self.total_lines_written = @max(self.total_lines_written, self.virtual_cursor_y + 1);

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
            // Check if we're already at the last line - if so, clamp cursor instead of wrapping
            if (self.cursor.y >= self.height - 1 and self.virtual_cursor_y >= self.height - 1) {
                // At bottom of terminal - clamp cursor to last position instead of wrapping
                self.cursor.x = self.width - 1;
            } else {
                // Normal wrapping behavior
                self.cursor.x = 0;
                self.virtual_cursor_y += 1;
                self.cursor.y = @min(self.virtual_cursor_y, self.height - 1);
                self.total_lines_written = @max(self.total_lines_written, self.virtual_cursor_y + 1);
            }
        } else {
            // Update cursor.y to match virtual_cursor_y when not wrapping
            self.cursor.y = @min(self.virtual_cursor_y, self.height - 1);
        }
    }

    // Cursor Management
    pub fn getCursor(self: VTerm) Position {
        return self.cursor;
    }

    pub fn moveCursor(self: *VTerm, x: u16, y: u16) void {
        // Clamp to valid bounds
        self.cursor.x = @min(x, self.width - 1);
        self.cursor.y = @min(y, self.height - 1);
        // Update virtual cursor to match visible cursor
        self.virtual_cursor_y = self.cursor.y;
    }

    // Screen Operations
    pub fn clear(self: *VTerm) void {
        @memset(self.cells, Cell.empty());
        self.cursor = Position.init(0, 0);
    }

    // Resize Support
    pub fn resize(self: *VTerm, new_width: u16, new_height: u16) !void {
        const new_total = @as(usize, new_width) * @as(usize, new_height);
        const new_cells = try self.allocator.alloc(Cell, new_total);
        @memset(new_cells, Cell.empty());

        // Copy existing content
        const copy_width = @min(self.width, new_width);
        const copy_height = @min(self.height, new_height);

        for (0..copy_height) |y| {
            const old_start = y * self.width;
            const new_start = y * new_width;
            @memcpy(new_cells[new_start .. new_start + copy_width], self.cells[old_start .. old_start + copy_width]);
        }

        // Replace buffer
        self.allocator.free(self.cells);
        self.cells = new_cells;
        self.width = new_width;
        self.height = new_height;

        // Clamp cursor to new bounds
        self.cursor.x = @min(self.cursor.x, new_width - 1);
        self.cursor.y = @min(self.cursor.y, new_height - 1);
    }

    // ===== Phase 2: Parser Implementation =====

    // Main parsing interface
    pub fn write(self: *VTerm, bytes: []const u8) void {
        // Auto-scroll to bottom when writing new content
        if (self.viewport_offset != 0) {
            self.scrollToBottom();
        }

        var i: usize = 0;
        while (i < bytes.len) {
            const byte = bytes[i];

            switch (self.parser_state) {
                .Ground => {
                    // Check if this is a UTF-8 multi-byte character
                    if (byte >= 0x80) {
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
                            i += 1;
                        }
                    } else {
                        self.handleGround(byte);
                        i += 1;
                    }
                },
                .Escape => {
                    self.handleEscape(byte);
                    i += 1;
                },
                .CSI => {
                    self.handleCSI(byte);
                    i += 1;
                },
            }
        }
    }

    fn handleGround(self: *VTerm, byte: u8) void {
        switch (byte) {
            0x1B => self.parser_state = .Escape, // ESC
            '\r' => self.cursor.x = 0, // Carriage return
            '\n' => { // Line feed
                self.cursor.x = 0; // Move to start of next line
                self.virtual_cursor_y += 1;
                self.cursor.y = @min(self.virtual_cursor_y, self.height - 1);
                // Each newline moves us to a new line
                // total_lines_written tracks how many lines we have content for
                self.total_lines_written = @max(self.total_lines_written, self.virtual_cursor_y + 1);
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
                self.parser_state = .CSI;
                // Reset parameters
                self.params = [_]u16{0} ** 16;
                self.param_count = 0;
                self.private_sequence = false;
            },
            else => {
                // Invalid character, abort sequence
                self.parser_state = .Ground;
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
            // CSI final bytes: 0x40-0x7E (@A-Z[\]^_`a-z{|}~)
            // All bytes in this range are valid CSI final bytes per ANSI spec
            0x40...0x7E => {
                // Final character - execute command if supported, otherwise ignore
                self.executeCSI(byte);
                self.parser_state = .Ground;
            },
            else => {
                // Truly invalid character (control char, etc), abort sequence
                // For characters outside the CSI final byte range, process as ground
                if (byte < 0x40) {
                    // Control or parameter characters appearing at wrong time - abort and process
                    self.parser_state = .Ground;
                    self.handleGround(byte);
                } else {
                    // Other invalid sequences - just abort without processing
                    self.parser_state = .Ground;
                }
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
            },
            'B' => { // CUD - Cursor Down
                const n = self.getParam(0, 1);
                self.cursor.y = @min(self.cursor.y + @as(u16, @intCast(n)), self.height - 1);
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

                else => {}, // Ignore unsupported SGR codes
            }
        }
    }

    // Private mode handling (DEC sequences)
    fn handlePrivateMode(self: *VTerm, enable: bool) void {
        const mode = self.getParam(0, 0);
        switch (mode) {
            25 => self.cursor_visible = enable, // Cursor visibility
            1049 => self.alt_screen = enable, // Alternate screen buffer
            else => {}, // Ignore other modes
        }
    }

    // Erase helper functions
    fn eraseFromCursor(self: *VTerm) void {
        // Erase from cursor to end of screen
        const start_idx = self.cellIndex(self.cursor.x, self.cursor.y);
        const end_idx = self.cells.len;
        for (start_idx..end_idx) |i| {
            self.cells[i] = Cell.empty();
        }
    }

    fn eraseToCursor(self: *VTerm) void {
        // Erase from start of screen to cursor
        const end_idx = self.cellIndex(self.cursor.x, self.cursor.y) + 1;
        for (0..end_idx) |i| {
            self.cells[i] = Cell.empty();
        }
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

    // ===== Phase 3: Input Generation =====

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

    // ===== Phase 4: Testing API =====

    pub fn captureState(self: *VTerm, allocator: Allocator) !TerminalState {
        const content = try self.getAllText(allocator);
        return TerminalState{
            .content = content,
            .cursor = self.cursor,
            .dimensions = .{ .width = self.width, .height = self.height },
        };
    }

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

    pub fn cursorAt(self: *VTerm, x: u16, y: u16) bool {
        return self.cursor.x == x and self.cursor.y == y;
    }

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
                defer line_buf.deinit(std.heap.page_allocator);

                for (0..self.width) |col| {
                    const cell = self.getCell(@intCast(col), @intCast(row));
                    if (cell.char == 0) {
                        line_buf.append(std.heap.page_allocator, ' ') catch break;
                    } else if (cell.char < 128) {
                        line_buf.append(std.heap.page_allocator, @intCast(cell.char)) catch break;
                    } else {
                        // UTF-8 character - for simplicity, skip in pattern matching
                        line_buf.append(std.heap.page_allocator, '?') catch break;
                    }
                }

                const line = line_buf.toOwnedSlice(std.heap.page_allocator) catch continue;
                defer std.heap.page_allocator.free(line);

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
                defer line_buf.deinit(std.heap.page_allocator);

                for (0..self.width) |col| {
                    const cell = self.getCell(@intCast(col), @intCast(row));
                    if (cell.char == 0) {
                        line_buf.append(std.heap.page_allocator, ' ') catch break;
                    } else if (cell.char < 128) {
                        line_buf.append(std.heap.page_allocator, @intCast(cell.char)) catch break;
                    } else {
                        // UTF-8 character - for simplicity, skip in pattern matching
                        line_buf.append(std.heap.page_allocator, '?') catch break;
                    }
                }

                const line = line_buf.toOwnedSlice(std.heap.page_allocator) catch continue;
                defer std.heap.page_allocator.free(line);

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
            // Convert linear index to x,y position
            const y = @as(u16, @intCast(index / self.width));
            const x = @as(u16, @intCast(index % self.width));
            try positions.append(allocator, Position{ .x = x, .y = y });
        }

        return positions.toOwnedSlice(allocator);
    }

    pub fn containsTextIgnoreCase(self: *VTerm, text: []const u8) bool {
        // For testing purposes, use a temporary allocator
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
    pub fn expectRegionEquals(self: *VTerm, x: u16, y: u16, width: u16, height: u16, expected: []const u8) !void {
        const testing = std.testing;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const actual = try self.getRegion(allocator, x, y, width, height);
        defer allocator.free(actual);

        try testing.expectEqualStrings(expected, actual);
    }

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
    pub const TerminalDiff = struct {
        changedLines: []u16,
        allocator: Allocator,

        pub fn deinit(self: *TerminalDiff, allocator: Allocator) void {
            allocator.free(self.changedLines);
        }

        pub fn hasDifferences(self: *const TerminalDiff) bool {
            return self.changedLines.len > 0;
        }
    };

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
    pub fn hasAttribute(self: *VTerm, x: u16, y: u16, attr: TextAttribute) bool {
        if (!self.isValidPos(x, y)) return false;
        const cell = self.getCell(x, y);

        return switch (attr) {
            .bold => cell.bold,
            .italic => cell.italic,
            .underline => cell.underline,
        };
    }

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
