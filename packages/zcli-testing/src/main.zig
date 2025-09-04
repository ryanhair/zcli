const std = @import("std");
const zcli = @import("zcli");

pub const snapshot = @import("snapshot.zig");
pub const runner = @import("runner.zig");
pub const assertions = @import("assertions.zig");

// Export commonly used types
pub const Result = runner.Result;
pub const interactive = @import("interactive.zig");

// Re-export snapshot functions at the top level for convenience
pub const expectSnapshot = snapshot.expectSnapshot;
pub const expectSnapshotWithData = snapshot.expectSnapshotWithData; // For framework testing only
pub const expectSnapshotAnsi = snapshot.expectSnapshotAnsi;
pub const expectSnapshotWithMasking = snapshot.expectSnapshotWithMasking;
pub const maskDynamicContent = snapshot.maskDynamicContent;
pub const stripAnsi = snapshot.stripAnsi;
pub const expectExitCode = assertions.expectExitCode;
pub const expectExitCodeNot = assertions.expectExitCodeNot;
pub const expectContains = assertions.expectContains;
pub const expectNotContains = assertions.expectNotContains;
pub const expectEqualStrings = assertions.expectEqualStrings;
pub const expectValidJson = assertions.expectValidJson;
pub const expectStdoutEmpty = assertions.expectStdoutEmpty;
pub const expectStderrEmpty = assertions.expectStderrEmpty;

// Interactive testing exports
pub const InteractiveScript = interactive.InteractiveScript;
pub const InteractiveConfig = interactive.InteractiveConfig;
pub const InteractiveResult = interactive.InteractiveResult;
pub const runInteractive = interactive.runInteractive;
pub const runInteractiveDualMode = interactive.runInteractiveDualMode;
pub const ControlSequence = interactive.ControlSequence;
pub const Signal = interactive.Signal;
pub const TerminalMode = interactive.TerminalMode;

/// Simple helper to run CLI commands with a generated registry
pub fn runWithRegistry(
    allocator: std.mem.Allocator,
    comptime RegistryType: type,
    args: []const []const u8,
) !runner.Result {
    return runner.runInProcess(allocator, RegistryType, args);
}

// Test references to ensure all tests are discovered
test {
    std.testing.refAllDecls(@This());
}
