const std = @import("std");
const build_utils = @import("src/build_utils.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the snapshot module
    _ = b.addModule("snapshot", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create tests
    const snapshot_tests = b.addTest(.{
        .root_source_file = b.path("src/snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_snapshot_tests = b.addRunArtifact(snapshot_tests);

    const test_step = b.step("test", "Run snapshot tests");
    test_step.dependOn(&run_snapshot_tests.step);

    // Install the module (for use by other packages)
    b.installArtifact(snapshot_tests);
}

// Re-export build utilities for use in other build.zig files
pub const setup = build_utils.setup;
