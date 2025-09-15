const std = @import("std");
const testing = std.testing;
const VTerm = @import("vterm.zig").VTerm;

// Import all Phase 4 test modules
const snapshot_tests = @import("tests/snapshot_test.zig");
const api_tests = @import("tests/api_test.zig");
const attribute_tests = @import("tests/attribute_test.zig");
const pattern_tests = @import("tests/pattern_test.zig");
const region_tests = @import("tests/region_test.zig");
const scrollback_tests = @import("tests/scrollback_test.zig");
const cursor_tests = @import("tests/cursor_test.zig");
const wide_char_tests = @import("tests/wide_char_test.zig");
const param_edge_cases_tests = @import("tests/param_edge_cases_test.zig");

// Re-export all tests
test {
    testing.refAllDecls(snapshot_tests);
    testing.refAllDecls(api_tests);
    testing.refAllDecls(attribute_tests);
    testing.refAllDecls(pattern_tests);
    testing.refAllDecls(region_tests);
    testing.refAllDecls(scrollback_tests);
    testing.refAllDecls(cursor_tests);
    testing.refAllDecls(wide_char_tests);
    testing.refAllDecls(param_edge_cases_tests);
}
