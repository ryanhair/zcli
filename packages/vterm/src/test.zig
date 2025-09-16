const std = @import("std");
const testing = std.testing;
const VTerm = @import("vterm.zig").VTerm;

// Import all test modules
const basic_tests = @import("tests/basic_test.zig");
const cursor_tests = @import("tests/cursor_test.zig");
const resize_tests = @import("tests/resize_test.zig");
const parser_tests = @import("tests/parser_test.zig");
const sgr_tests = @import("tests/sgr_test.zig");
const input_tests = @import("tests/input_test.zig");
const integration_tests = @import("tests/integration_test.zig");
const input_edge_cases_tests = @import("tests/input_edge_cases_test.zig");
const snapshot_tests = @import("tests/snapshot_test.zig");
const api_tests = @import("tests/api_test.zig");
const attribute_tests = @import("tests/attribute_test.zig");
const pattern_tests = @import("tests/pattern_test.zig");
const region_tests = @import("tests/region_test.zig");
const scrollback_tests = @import("tests/scrollback_test.zig");
const wide_char_tests = @import("tests/wide_char_test.zig");
const param_edge_cases_tests = @import("tests/param_edge_cases_test.zig");

// Re-export all tests
test {
    testing.refAllDecls(basic_tests);
    testing.refAllDecls(cursor_tests);
    testing.refAllDecls(resize_tests);
    testing.refAllDecls(parser_tests);
    testing.refAllDecls(sgr_tests);
    testing.refAllDecls(input_tests);
    testing.refAllDecls(integration_tests);
    testing.refAllDecls(input_edge_cases_tests);
    testing.refAllDecls(snapshot_tests);
    testing.refAllDecls(api_tests);
    testing.refAllDecls(attribute_tests);
    testing.refAllDecls(pattern_tests);
    testing.refAllDecls(region_tests);
    testing.refAllDecls(scrollback_tests);
    testing.refAllDecls(wide_char_tests);
    testing.refAllDecls(param_edge_cases_tests);
}
