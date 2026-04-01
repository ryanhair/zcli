const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get ztheme dependency
    const ztheme_dep = b.dependency("ztheme", .{
        .target = target,
        .optimize = optimize,
    });
    const ztheme_module = ztheme_dep.module("ztheme");

    // Main zprogress module
    const zprogress_mod = b.addModule("zprogress", .{
        .root_source_file = b.path("src/zprogress.zig"),
        .target = target,
        .optimize = optimize,
    });
    zprogress_mod.addImport("ztheme", ztheme_module);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const test_mod = b.addModule("test-zprogress", .{
        .root_source_file = b.path("src/zprogress.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("ztheme", ztheme_module);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
