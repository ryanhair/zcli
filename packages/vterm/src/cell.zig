pub const Cell = struct {
    char: u21, // Unicode codepoint (0 = empty cell)
    fg: u8, // Foreground color (0-15 for basic colors)
    bg: u8, // Background color (0-15 for basic colors)
    bold: bool,
    italic: bool,
    underline: bool,
    wide_continuation: bool, // True if this cell is the continuation of a wide character

    // Helper functions
    pub fn empty() Cell {
        return .{
            .char = 0,
            .fg = 7, // Default white
            .bg = 0, // Default black
            .bold = false,
            .italic = false,
            .underline = false,
            .wide_continuation = false,
        };
    }

    pub fn isEmpty(self: Cell) bool {
        return self.char == 0;
    }

    pub fn init(char: u21) Cell {
        return .{
            .char = char,
            .fg = 7,
            .bg = 0,
            .bold = false,
            .italic = false,
            .underline = false,
            .wide_continuation = false,
        };
    }

    pub fn withAttributes(char: u21, fg: u8, bg: u8, bold: bool, italic: bool, underline: bool) Cell {
        return .{
            .char = char,
            .fg = fg,
            .bg = bg,
            .bold = bold,
            .italic = italic,
            .underline = underline,
            .wide_continuation = false,
        };
    }

    // Create a continuation cell for wide characters
    pub fn wideContinuation(fg: u8, bg: u8, bold: bool, italic: bool, underline: bool) Cell {
        return .{
            .char = 0, // No character in continuation cell
            .fg = fg,
            .bg = bg,
            .bold = bold,
            .italic = italic,
            .underline = underline,
            .wide_continuation = true,
        };
    }
};
