const std = @import("std");
const testing = std.testing;
const VTerm = @import("vterm.zig").VTerm;

// Import all Phase 3 test modules
const input_tests = @import("tests/input_test.zig");
const integration_tests = @import("tests/integration_test.zig");
const input_edge_cases_tests = @import("tests/input_edge_cases_test.zig");

// Re-export all tests
test {
    testing.refAllDecls(input_tests);
    testing.refAllDecls(integration_tests);
    testing.refAllDecls(input_edge_cases_tests);
}
