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
        .{ .name = "capabilities", .path = "packages/capabilities" },
        .{ .name = "testing", .path = "packages/testing" },
        .{ .name = "vterm", .path = "packages/vterm" },
        .{ .name = "interactive", .path = "packages/interactive" },
        .{ .name = "markdown_fmt", .path = "packages/markdown_fmt" },
        .{ .name = "zcli_help_plugin", .path = "packages/core/plugins/zcli_help" },
        .{ .name = "zcli_not_found_plugin", .path = "packages/core/plugins/zcli_not_found" },
    };

    const example_projects = [_]ProjectInfo{
        .{ .name = "basic_example", .path = "examples/basic" },
        .{ .name = "advanced_example", .path = "examples/advanced" },
        .{ .name = "swapi_example", .path = "examples/swapi" },
        .{ .name = "ztheme_example", .path = "examples/ztheme" },
        .{ .name = "vterm_example", .path = "packages/vterm/example" },
    };

    // Create main test step that runs all tests
    const test_step = b.step("test", "Run all tests across all subprojects");

    // Add tests for each project that has them
    for (test_projects) |project| {
        // Create individual test step for this project
        const project_test_step = b.step(b.fmt("test-{s}", .{project.name}), b.fmt("Run tests for {s}", .{project.name}));

        // Print a message before running tests for this project
        const print_start = b.addSystemCommand(&.{"echo"});
        print_start.addArg(b.fmt("\n==> Running tests for {s} ({s})", .{ project.name, project.path }));

        // Run the test step from the subproject directory
        const project_test_run = b.addSystemCommand(&.{"zig"});
        project_test_run.addArgs(&.{ "build", "test" });
        project_test_run.setCwd(b.path(project.path));
        project_test_run.step.dependOn(&print_start.step);

        // Print success message after tests pass
        const print_success = b.addSystemCommand(&.{"echo"});
        print_success.addArg(b.fmt("    ✓ {s} tests passed", .{project.name}));
        print_success.step.dependOn(&project_test_run.step);

        project_test_step.dependOn(&print_success.step);
        test_step.dependOn(&print_success.step);
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
