// Main options module - exports public API for option parsing
const types = @import("options/types.zig");
const utils = @import("options/utils.zig");
const array_utils = @import("options/array_utils.zig");
const parser = @import("options/parser.zig");

// ============================================================================
// PUBLIC API - These functions and types are intended for end users
// ============================================================================

// Core error types
pub const OptionParseError = types.OptionParseError;
pub const ParseResult = types.ParseResult;
pub const OptionsResult = types.OptionsResult;

// Main parsing functions
pub const parseOptions = parser.parseOptions;
pub const parseOptionsWithMeta = parser.parseOptionsWithMeta;
pub const cleanupOptions = parser.cleanupOptions;

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

// Internal array utilities (used by parsing logic)
const ArrayListUnion = array_utils.ArrayListUnion;
const createArrayListUnion = array_utils.createArrayListUnion;
const appendToArrayListUnion = array_utils.appendToArrayListUnion;
const appendToArrayListUnionShort = array_utils.appendToArrayListUnionShort;
const arrayListUnionToOwnedSlice = array_utils.arrayListUnionToOwnedSlice;
