const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get capabilities dependency
    const capabilities = b.dependency("capabilities", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the interactive module
    const interactive_mod = b.addModule("interactive", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    interactive_mod.addImport("capabilities", capabilities.module("capabilities"));

    // Tests for the interactive framework
    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_tests.root_module.addImport("capabilities", capabilities.module("capabilities"));

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run interactive library tests");
    test_step.dependOn(&run_lib_tests.step);
}
