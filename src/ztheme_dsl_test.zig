//! ZTheme DSL test suite
//!
//! This file focuses specifically on testing the DSL parser functionality
//! that was implemented in Phase 1-3 without the broader ZTheme system issues.

const std = @import("std");

// Import DSL modules directly with proper context
test "ZTheme DSL Parser Tests" {
    // Test the DSL modules we just implemented
    std.testing.refAllDecls(@import("ztheme/dsl/ast.zig"));
    std.testing.refAllDecls(@import("ztheme/dsl/tokenizer.zig"));
    std.testing.refAllDecls(@import("ztheme/dsl/parser.zig"));
    std.testing.refAllDecls(@import("ztheme/dsl/markdown.zig"));
}
