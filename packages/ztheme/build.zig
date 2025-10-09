const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the ztheme module
    _ = b.addModule("ztheme", .{
        .root_source_file = b.path("src/ztheme.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests for the ztheme library - run all tests through main module
    const ztheme_tests = b.addTest(.{
        .root_source_file = b.path("src/ztheme.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_ztheme_tests = b.addRunArtifact(ztheme_tests);

    const test_step = b.step("test", "Run ztheme library tests");
    test_step.dependOn(&run_ztheme_tests.step);
}
