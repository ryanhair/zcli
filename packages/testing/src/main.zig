const std = @import("std");
const snapshot = @import("snapshot.zig");
pub const build_utils = @import("build_utils.zig");

// Export runner and assertions modules
pub const runner = @import("runner.zig");
pub const assertions = @import("assertions.zig");

// Export main snapshot testing function with options
pub const expectSnapshot = snapshot.expectSnapshot;
pub const SnapshotOptions = snapshot.SnapshotOptions;

// Export utility functions
pub const maskDynamicContent = snapshot.maskDynamicContent;
pub const stripAnsi = snapshot.stripAnsi;

// Export framework testing helper
pub const expectSnapshotWithData = snapshot.expectSnapshotWithData;

// Re-export common types for convenience
pub const Result = runner.Result;

// Re-export common assertions for convenience
pub const expectExitCode = assertions.expectExitCode;
pub const expectExitCodeNot = assertions.expectExitCodeNot;
pub const expectContains = assertions.expectContains;
pub const expectNotContains = assertions.expectNotContains;
pub const expectEqualStrings = assertions.expectEqualStrings;
pub const expectValidJson = assertions.expectValidJson;
pub const expectStdoutEmpty = assertions.expectStdoutEmpty;
pub const expectStderrEmpty = assertions.expectStderrEmpty;

// Test references to ensure all tests are discovered
test {
    std.testing.refAllDecls(@This());
}
