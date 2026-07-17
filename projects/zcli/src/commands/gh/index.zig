const std = @import("std");

pub const meta = .{
    .description = "Add GitHub-related features and workflows",
};

test "meta.description names what this group covers" {
    try std.testing.expect(meta.description.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, meta.description, "GitHub") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta.description, "workflows") != null);
}
