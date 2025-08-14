const std = @import("std");

pub const ParseResult = struct {
    /// The position where option parsing stopped (first non-option argument)
    next_arg_index: usize,
};

pub fn OptionsResult(comptime OptionsType: type) type {
    return struct { options: OptionsType, result: ParseResult };
}
