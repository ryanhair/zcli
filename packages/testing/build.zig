const std = @import("std");
const build_utils = @import("src/build_utils.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const capabilities_dep = b.dependency("capabilities", .{
        .target = target,
        .optimize = optimize,
    });
    const capabilities_module = capabilities_dep.module("capabilities");

    // Create the testing module
    const testing_mod = b.addModule("testing", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    testing_mod.addImport("capabilities", capabilities_module);

    // Create tests
    const test_mod = b.addModule("test-testing", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("capabilities", capabilities_module);
    const main_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_main_tests.step);

    // Install the module (for use by other packages)
    b.installArtifact(main_tests);
}

// Re-export build utilities for use in other build.zig files
pub const setup = build_utils.setup;
