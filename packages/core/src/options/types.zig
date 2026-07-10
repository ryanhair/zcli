const std = @import("std");

pub const ParseMetadata = struct {
    /// The position where option parsing stopped (first non-option argument)
    next_arg_index: usize,
};

/// Number of fields in an Options struct (0 for a non-struct, e.g. never).
pub fn optionFieldCount(comptime OptionsType: type) usize {
    return switch (@typeInfo(OptionsType)) {
        .@"struct" => |s| s.fields.len,
        else => 0,
    };
}

pub fn OptionsResult(comptime OptionsType: type) type {
    return struct {
        options: OptionsType,
        result: ParseMetadata,
        /// One flag per Options field, true when a value source (env or CLI)
        /// explicitly set it. Lets the required-option check tell "provided the
        /// type's zero value" (an empty string, or an enum's first variant) apart
        /// from "never provided" — a value comparison alone cannot. Config runs
        /// after the parser, so its contribution is detected separately.
        provided: [optionFieldCount(OptionsType)]bool = [_]bool{false} ** optionFieldCount(OptionsType),
    };
}
