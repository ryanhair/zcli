const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const terminal_dep = b.dependency("terminal", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the interactive module
    const interactive_mod = b.addModule("interactive", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    interactive_mod.addImport("terminal", terminal_dep.module("terminal"));

    // Tests for the interactive framework
    const test_mod = b.addModule("test-interactive", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("terminal", terminal_dep.module("terminal"));
    const lib_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run interactive library tests");
    test_step.dependOn(&run_lib_tests.step);
}
