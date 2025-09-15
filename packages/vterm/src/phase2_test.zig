const std = @import("std");
const testing = std.testing;
const VTerm = @import("vterm.zig").VTerm;

// Import all Phase 2 test modules
const parser_tests = @import("tests/parser_test.zig");
const sgr_tests = @import("tests/sgr_test.zig");

// Re-export all tests
test {
    testing.refAllDecls(parser_tests);
    testing.refAllDecls(sgr_tests);
}
