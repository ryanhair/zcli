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

    // Create showcase tests
    const showcase_tests = b.addTest(.{
        .root_source_file = b.path("tests/showcase.zig"),
        .target = target,
        .optimize = optimize,
    });
    showcase_tests.root_module.addImport("snapshot", snapshot_dep.module("snapshot"));
    showcase_tests.step.dependOn(&install_exe_step.step);

    const run_tests = b.addRunArtifact(showcase_tests);

    const test_step = b.step("test", "Run snapshot showcase tests");
    test_step.dependOn(&run_tests.step);
    
    // Update snapshots command with cleanup
    const update_snapshots_step = b.step("update-snapshots", "Update all test snapshots");
    const cleanup_snapshots = b.addRemoveDirTree(b.path("tests/snapshots"));
    update_snapshots_step.dependOn(&cleanup_snapshots.step);
    
    const update_run_tests = b.addRunArtifact(showcase_tests);
    update_run_tests.setEnvironmentVariable("UPDATE_SNAPSHOTS", "1");
    update_run_tests.step.dependOn(&cleanup_snapshots.step);
    update_snapshots_step.dependOn(&update_run_tests.step);

    // Demo executable run step
    const run_demo = b.addRunArtifact(example_exe);
    if (b.args) |args| {
        run_demo.addArgs(args);
    }

    const run_step = b.step("run", "Run the snapshot demo");
    run_step.dependOn(&run_demo.step);
}