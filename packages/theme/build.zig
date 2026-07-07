const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the theme module
    _ = b.addModule("theme", .{
        .root_source_file = b.path("src/theme.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests for the theme library - run all tests through main module
    const test_mod = b.addModule("test-theme", .{
        .root_source_file = b.path("src/theme.zig"),
        .target = target,
        .optimize = optimize,
    });
    const theme_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_theme_tests = b.addRunArtifact(theme_tests);

    const test_step = b.step("test", "Run theme library tests");
    test_step.dependOn(&run_theme_tests.step);
}
