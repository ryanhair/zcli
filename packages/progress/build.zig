const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get theme dependency
    const theme_dep = b.dependency("theme", .{
        .target = target,
        .optimize = optimize,
    });
    const theme_module = theme_dep.module("theme");
    const terminal_dep = b.dependency("terminal", .{
        .target = target,
        .optimize = optimize,
    });
    const terminal_module = terminal_dep.module("terminal");

    // Main progress module
    const progress_mod = b.addModule("progress", .{
        .root_source_file = b.path("src/Progress.zig"),
        .target = target,
        .optimize = optimize,
    });
    progress_mod.addImport("theme", theme_module);
    progress_mod.addImport("terminal", terminal_module);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const test_mod = b.addModule("test-progress", .{
        .root_source_file = b.path("src/Progress.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("theme", theme_module);
    test_mod.addImport("terminal", terminal_module);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
