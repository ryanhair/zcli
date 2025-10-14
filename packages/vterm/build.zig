const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the vterm module
    _ = b.addModule("vterm", .{
        .root_source_file = b.path("src/vterm.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests for the vterm library
    const test_mod = b.addModule("test-vterm", .{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vterm_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_vterm_tests = b.addRunArtifact(vterm_tests);

    const test_step = b.step("test", "Run vterm library tests");
    test_step.dependOn(&run_vterm_tests.step);
}
