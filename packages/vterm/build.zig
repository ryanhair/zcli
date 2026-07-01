const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{ .target = target, .optimize = optimize });

    // Create the vterm module
    const mod = b.addModule("vterm", .{
        .root_source_file = b.path("src/vterm.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("DisplayWidth", zg.module("DisplayWidth"));

    // Tests for the vterm library
    const test_mod = b.addModule("test-vterm", .{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("DisplayWidth", zg.module("DisplayWidth"));
    const vterm_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_vterm_tests = b.addRunArtifact(vterm_tests);

    const test_step = b.step("test", "Run vterm library tests");
    test_step.dependOn(&run_vterm_tests.step);
}
