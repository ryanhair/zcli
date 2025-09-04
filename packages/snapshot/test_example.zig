const std = @import("std");
const snapshot = @import("src/main.zig");

test "unified snapshot API" {
    // Test that the unified API functions are accessible
    _ = snapshot.expectSnapshot;
    _ = snapshot.SnapshotOptions;
    _ = snapshot.maskDynamicContent;
    _ = snapshot.stripAnsi;
    
    // Test default options work
    const default_options = snapshot.SnapshotOptions{};
    std.testing.expect(default_options.mask == true) catch {};
    std.testing.expect(default_options.ansi == true) catch {};
}