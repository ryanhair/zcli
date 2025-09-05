const std = @import("std");
const snapshot = @import("snapshot.zig");
pub const build_utils = @import("build_utils.zig");

// Export main snapshot testing function with options
pub const expectSnapshot = snapshot.expectSnapshot;
pub const SnapshotOptions = snapshot.SnapshotOptions;

// Export utility functions
pub const maskDynamicContent = snapshot.maskDynamicContent;
pub const stripAnsi = snapshot.stripAnsi;

// Export framework testing helper
pub const expectSnapshotWithData = snapshot.expectSnapshotWithData;

// Test references to ensure all tests are discovered
test {
    std.testing.refAllDecls(@This());
}