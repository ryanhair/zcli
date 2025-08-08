// Main options module - re-exports all functionality from submodules
const types = @import("options/types.zig");
const utils = @import("options/utils.zig");
const array_utils = @import("options/array_utils.zig");
const parser = @import("options/parser.zig");

// Re-export all public types
pub const OptionParseError = types.OptionParseError;
pub const ParseResult = types.ParseResult;
pub const OptionsResult = types.OptionsResult;

// Re-export core parsing functions
pub const parseOptions = parser.parseOptions;
pub const parseOptionsWithMeta = parser.parseOptionsWithMeta;
pub const cleanupOptions = parser.cleanupOptions;

// Re-export utility functions
pub const isNegativeNumber = utils.isNegativeNumber;

// Re-export internal functions for testing (these could be made private later)
pub const isBooleanType = utils.isBooleanType;
pub const isArrayType = utils.isArrayType;
pub const parseOptionValue = utils.parseOptionValue;
pub const dashesToUnderscores = utils.dashesToUnderscores;

// Re-export array utilities (internal use)
pub const ArrayListUnion = array_utils.ArrayListUnion;
pub const createArrayListUnion = array_utils.createArrayListUnion;
pub const appendToArrayListUnion = array_utils.appendToArrayListUnion;
pub const appendToArrayListUnionShort = array_utils.appendToArrayListUnionShort;
pub const arrayListUnionToOwnedSlice = array_utils.arrayListUnionToOwnedSlice;