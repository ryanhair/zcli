const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Add update-snapshots option
    const update_snapshots = b.option(bool, "update-snapshots", "Update test snapshots") orelse false;

    // Get dependencies
    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    const snapshot_dep = b.dependency("snapshot", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the zcli-testing module
    const zcli_testing_module = b.addModule("zcli-testing", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "zcli",
                .module = zcli_dep.module("zcli"),
            },
            .{
                .name = "snapshot",
                .module = snapshot_dep.module("snapshot"),
            },
        },
    });

    // Tests for the testing framework itself
    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_tests.root_module.addImport("zcli", zcli_dep.module("zcli"));
    lib_tests.root_module.addImport("snapshot", snapshot_dep.module("snapshot"));
    
    const lib_test_options = b.addOptions();
    lib_test_options.addOption(bool, "update_snapshots", update_snapshots);
    lib_tests.root_module.addOptions("build_options", lib_test_options);

    const run_lib_tests = b.addRunArtifact(lib_tests);
    
    // Integration tests that need to run separately
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("tests/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.root_module.addImport("zcli", zcli_dep.module("zcli"));
    integration_tests.root_module.addImport("zcli_testing", zcli_testing_module);
    
    const integration_test_options = b.addOptions();
    integration_test_options.addOption(bool, "update_snapshots", update_snapshots);
    integration_tests.root_module.addOptions("build_options", integration_test_options);
    
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run zcli-testing library tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}