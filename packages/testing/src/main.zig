//! zcli Testing Framework
//!
//! Provides three tiers of CLI testing:
//!
//! - **Unit testing** (`zcli.test_utils`): In-process command execution — test a single
//!   command's logic without compiling a binary. Lives in core, not here.
//!
//! - **Integration testing** (`runner`, `assertions`, `snapshot`): Subprocess execution —
//!   compile your CLI, run it with args, assert on stdout/stderr/exit code. Snapshot
//!   testing for golden file comparisons.
//!
//! - **E2E testing** (`e2e`): PTY-based interactive testing — test commands that require
//!   real terminal interaction (password prompts, signal handling, window resizing).
//!
//! ## Quick Start
//!
//! ```zig
//! const testing = @import("zcli-testing");
//!
//! // Integration test
//! test "help flag" {
//!     const result = try testing.integration.runSubprocess(allocator, "./myapp", &.{"--help"});
//!     try testing.expectExitCode(result, 0);
//!     try testing.expectContains(result.stdout, "USAGE:");
//! }
//!
//! // E2E test
//! test "login flow" {
//!     var script = testing.e2e.InteractiveScript.init(allocator);
//!     _ = script.expect("Password:").sendHidden("secret");
//!     const result = try testing.e2e.runInteractive(allocator, &.{"./myapp", "login"}, script, .{});
//!     try std.testing.expect(result.success);
//! }
//! ```

const std = @import("std");

// ============================================================================
// Integration Testing — subprocess-based CLI testing
// ============================================================================

pub const integration = @import("runner.zig");

// ============================================================================
// Assertions — shared assertion helpers for all tiers
// ============================================================================

pub const assertions = @import("assertions.zig");

// ============================================================================
// Snapshot Testing — golden file comparisons
// ============================================================================

const snapshot = @import("snapshot.zig");
pub const expectSnapshot = snapshot.expectSnapshot;
pub const SnapshotOptions = snapshot.SnapshotOptions;
pub const maskDynamicContent = snapshot.maskDynamicContent;
pub const stripAnsi = snapshot.stripAnsi;
pub const expectSnapshotWithData = snapshot.expectSnapshotWithData;

// ============================================================================
// E2E Testing — PTY-based interactive testing
// ============================================================================

pub const e2e = @import("e2e.zig");

// ============================================================================
// Build Utilities
// ============================================================================

pub const build_utils = @import("build_utils.zig");

// ============================================================================
// Convenience re-exports (most commonly used)
// ============================================================================

pub const Result = integration.Result;
pub const runSubprocess = integration.runSubprocess;

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
