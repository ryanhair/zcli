const std = @import("std");
const build_utils = @import("src/build_utils.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main zcli module that will be exposed to users
    _ = b.addModule("zcli", .{
        .root_source_file = b.path("src/zcli.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests
    const test_step = b.step("test", "Run unit tests");

    // Test each module with tests
    const test_files = [_][]const u8{
        "src/zcli.zig",
        "src/args.zig",
        "src/options.zig",
        "src/help.zig",
        "src/errors.zig",
        "src/build_utils.zig",
        "src/build_integration_test.zig", // Integration tests for build system
    };

    for (test_files) |test_file| {
        const tests = b.addTest(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });

        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }
}

// Re-export the generateCommandRegistry function for backwards compatibility
pub const generateCommandRegistry = build_utils.generateCommandRegistry;
