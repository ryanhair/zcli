const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get snapshot dependency
    const snapshot_dep = b.dependency("snapshot", .{
        .target = target,
        .optimize = optimize,
    });

    // Create example executable that generates test data
    const example_exe = b.addExecutable(.{
        .name = "snapshot-demo",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const install_exe_step = b.addInstallArtifact(example_exe, .{});

    // Create test step (standard Zig way)
    const showcase_tests = b.addTest(.{
        .root_source_file = b.path("tests/showcase.zig"),
        .target = target,
        .optimize = optimize,
    });
    showcase_tests.root_module.addImport("snapshot", snapshot_dep.module("snapshot"));
    showcase_tests.step.dependOn(&install_exe_step.step);

    // Standard test command
    const run_tests = b.addRunArtifact(showcase_tests);
    const test_step = b.step("test", "Run snapshot showcase tests");
    test_step.dependOn(&run_tests.step);

    // Add update-snapshots functionality - just one line!
    const snapshot = @import("snapshot");
    snapshot.setup(b, showcase_tests);

    // Demo executable run step
    const run_demo = b.addRunArtifact(example_exe);
    if (b.args) |args| {
        run_demo.addArgs(args);
    }

    const run_step = b.step("run", "Run the snapshot demo");
    run_step.dependOn(&run_demo.step);
}
