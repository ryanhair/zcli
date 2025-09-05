const std = @import("std");

/// Add "update-snapshots" command for your existing test step
/// Cleans the snapshots directory and re-runs tests in update mode
pub fn setup(
    b: *std.Build,
    test_step: *std.Build.Step.Compile,
) void {
    const update_step = b.step("update-snapshots", "Update all test snapshots");

    // Clean existing snapshots first
    const cleanup = b.addRemoveDirTree(b.path("tests/snapshots"));
    update_step.dependOn(&cleanup.step);

    // Run tests in update mode after cleanup
    const update_run = b.addRunArtifact(test_step);
    update_run.setEnvironmentVariable("UPDATE_SNAPSHOTS", "1");
    update_run.step.dependOn(&cleanup.step);
    update_step.dependOn(&update_run.step);
}
