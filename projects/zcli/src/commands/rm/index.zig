const std = @import("std");

pub const meta = .{
    .description = "Remove args and options from an existing command",
};

test "meta.description names what this group removes" {
    try std.testing.expect(meta.description.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, meta.description, "Remove"));
    try std.testing.expect(std.mem.indexOf(u8, meta.description, "args") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta.description, "options") != null);
}
