const std = @import("std");
const snapshot = @import("src/main.zig");

test "unified API with different options" {
    // Test that the options struct works correctly
    const default_opts = snapshot.SnapshotOptions{};
    try std.testing.expect(default_opts.mask == true);
    try std.testing.expect(default_opts.ansi == true);

    const custom_opts = snapshot.SnapshotOptions{ .mask = false, .ansi = false };
    try std.testing.expect(custom_opts.mask == false);
    try std.testing.expect(custom_opts.ansi == false);
}
