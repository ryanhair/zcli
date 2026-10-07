// Main options module - exports public API for option parsing
const types = @import("options/types.zig");
const utils = @import("options/utils.zig");
const array_utils = @import("options/array_utils.zig");
const parser = @import("options/parser.zig");

// ============================================================================
// PUBLIC API - These functions and types are intended for end users
// ============================================================================

// Core types
pub const OptionsResult = types.OptionsResult;
pub const optionFieldCount = types.optionFieldCount;

// Main parsing functions
pub const parseOptions = parser.parseOptions;
pub const parseOptionsWithMeta = parser.parseOptionsWithMeta;
pub const cleanupOptions = parser.cleanupOptions;
pub const resolveStdin = @import("options/stdin.zig").resolveStdin;

// Utility functions that users might need (currently none - all utilities are internal)

// ============================================================================
// INTERNAL API - These are implementation details, not intended for end users
// Use @import("options/module_name.zig") directly if you need access to these
// ============================================================================

// Internal type checking utilities (used by parsing logic)
const isBooleanType = utils.isBooleanType;
const isArrayType = utils.isArrayType;
const isNegativeNumber = utils.isNegativeNumber;
const parseOptionValue = utils.parseOptionValue;
const dashesToUnderscores = utils.dashesToUnderscores;

// Import tests from sub-modules to include them in the test suite
test {
    // Import all tests from sub-modules
    _ = parser;
    _ = array_utils;
    _ = utils;
    _ = @import("options/stdin.zig");
    _ = @import("options/tokenizer.zig");
}
