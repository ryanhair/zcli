const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});

    // Define the project directories that have tests
    const ProjectInfo = struct {
        name: []const u8,
        path: []const u8,
    };

    const test_projects = [_]ProjectInfo{
        .{ .name = "core", .path = "packages/core" },
        // .{ .name = "ztheme", .path = "packages/ztheme" },
        .{ .name = "interactive", .path = "packages/interactive" },
        .{ .name = "zcli-testing", .path = "packages/zcli-testing" },
        .{ .name = "zcli-help-plugin", .path = "packages/core/plugins/zcli-help" },
        .{ .name = "zcli-not-found-plugin", .path = "packages/core/plugins/zcli-not-found" },
    };

    const example_projects = [_]ProjectInfo{
        .{ .name = "basic-example", .path = "packages/examples/basic" },
        .{ .name = "advanced-example", .path = "packages/examples/advanced" },
        .{ .name = "swapi-example", .path = "packages/examples/swapi" },
        .{ .name = "ztheme-demo-example", .path = "packages/examples/ztheme-demo" },
    };

    // Create main test step that runs all tests
    const test_step = b.step("test", "Run all tests across all subprojects");

    // Add tests for each project that has them
    for (test_projects) |project| {
        // Create individual test step for this project
        const project_test_step = b.step(b.fmt("test-{s}", .{project.name}), b.fmt("Run tests for {s}", .{project.name}));

        // Run the test step from the subproject directory
        const project_test_run = b.addSystemCommand(&.{"zig"});
        project_test_run.addArgs(&.{ "build", "test" });
        project_test_run.setCwd(b.path(project.path));

        project_test_step.dependOn(&project_test_run.step);
        test_step.dependOn(&project_test_run.step);
    }

    // Create build step for examples
    const build_examples_step = b.step("build-examples", "Build all example projects");

    for (example_projects) |example| {
        // Create individual build step for this example
        const example_build_step = b.step(b.fmt("build-{s}", .{example.name}), b.fmt("Build {s} example", .{example.name}));

        // Run the build for this example
        const example_build_run = b.addSystemCommand(&.{"zig"});
        example_build_run.addArgs(&.{"build"});
        example_build_run.setCwd(b.path(example.path));

        example_build_step.dependOn(&example_build_run.step);
        build_examples_step.dependOn(&example_build_run.step);
    }

    // Create a comprehensive build step that builds and tests everything
    const build_all_step = b.step("build-all", "Build and test all subprojects");
    build_all_step.dependOn(test_step);
    build_all_step.dependOn(build_examples_step);
}
