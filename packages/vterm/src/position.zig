pub const Position = struct {
    x: u16,
    y: u16,

    pub fn init(x: u16, y: u16) Position {
        return .{ .x = x, .y = y };
    }
};
