const std = @import("std");

pub const meta = .{
    .description = "Add commands and plugins to your zcli project",
};

test "meta.description names what this group adds" {
    try std.testing.expect(meta.description.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, meta.description, "Add"));
    try std.testing.expect(std.mem.indexOf(u8, meta.description, "commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta.description, "plugins") != null);
}
