const std = @import("std");

pub const interactive = @import("interactive.zig");

// Re-export the main types for convenience
pub const InteractiveScript = interactive.InteractiveScript;
pub const InteractiveConfig = interactive.InteractiveConfig;
pub const InteractiveResult = interactive.InteractiveResult;
pub const runInteractive = interactive.runInteractive;
pub const runInteractiveDualMode = interactive.runInteractiveDualMode;
pub const ControlSequence = interactive.ControlSequence;
pub const Signal = interactive.Signal;
pub const TerminalMode = interactive.TerminalMode;

// Test references to ensure all tests are discovered
test {
    std.testing.refAllDecls(@This());
}
