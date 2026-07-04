const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create ztheme module
    const ztheme_module = b.addModule("ztheme", .{
        .root_source_file = b.path("packages/ztheme/src/ztheme.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create markdown_fmt module
    const markdown_fmt_module = b.addModule("markdown_fmt", .{
        .root_source_file = b.path("packages/markdown_fmt/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    markdown_fmt_module.addImport("ztheme", ztheme_module);

    // Unicode display-width/grapheme data (used by terminal's wrap.zig).
    const zg_dep = b.dependency("zg", .{ .target = target, .optimize = optimize });

    // Create terminal module
    const terminal_module = b.addModule("terminal", .{
        .root_source_file = b.path("packages/terminal/src/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });
    terminal_module.addImport("Graphemes", zg_dep.module("Graphemes"));

    // Create zprogress module
    const zprogress_module = b.addModule("zprogress", .{
        .root_source_file = b.path("packages/zprogress/src/zprogress.zig"),
        .target = target,
        .optimize = optimize,
    });
    zprogress_module.addImport("ztheme", ztheme_module);
    zprogress_module.addImport("terminal", terminal_module);

    // Create zinput module
    const zinput_module = b.addModule("zinput", .{
        .root_source_file = b.path("packages/zinput/src/zinput.zig"),
        .target = target,
        .optimize = optimize,
    });
    zinput_module.addImport("terminal", terminal_module);
    zinput_module.addImport("ztheme", ztheme_module);

    // Expose the PTY-based interactive test harness (testing/e2e.zig) as a
    // consumable module so CLI projects can write interactive regression tests.
    // Only e2e.zig is exposed (it's std-only); the rest of the testing package
    // pulls in zcli/vterm and isn't needed for driving a TTY.
    _ = b.addModule("testing_e2e", .{
        .root_source_file = b.path("packages/testing/src/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Third-party serialization module
    const serde_dep = b.dependency("serde", .{ .target = target, .optimize = optimize });

    // Export the zcli module from core package for external projects
    const zcli_module = b.addModule("zcli", .{
        .root_source_file = b.path("packages/core/src/zcli.zig"),
        .target = target,
        .optimize = optimize,
    });
    zcli_module.addImport("ztheme", ztheme_module);
    zcli_module.addImport("markdown_fmt", markdown_fmt_module);
    zcli_module.addImport("zprogress", zprogress_module);
    zcli_module.addImport("zinput", zinput_module);
    zcli_module.addImport("serde", serde_dep.module("serde"));

    // Expose the unit-testing tier (packages/testing — `runCommand`, assertions)
    // from the zcli dependency, so scaffolded projects can unit-test their
    // commands with no extra dependency (see `zcli.addCommandTests`). Lazy: costs
    // nothing unless a consumer imports it. Needs zcli + vterm (VTerm assertions).
    const vterm_module = b.addModule("vterm", .{
        .root_source_file = b.path("packages/vterm/src/vterm.zig"),
        .target = target,
        .optimize = optimize,
    });
    vterm_module.addImport("DisplayWidth", zg_dep.module("DisplayWidth"));
    const zcli_testing_module = b.addModule("zcli_testing", .{
        .root_source_file = b.path("packages/testing/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    zcli_testing_module.addImport("zcli", zcli_module);
    zcli_testing_module.addImport("vterm", vterm_module);

    // Define the project directories that have tests
    const ProjectInfo = struct {
        name: []const u8,
        path: []const u8,
    };

    const test_projects = [_]ProjectInfo{
        .{ .name = "core", .path = "packages/core" },
        .{ .name = "testing", .path = "packages/testing" },
        .{ .name = "vterm", .path = "packages/vterm" },
        .{ .name = "markdown_fmt", .path = "packages/markdown_fmt" },
        .{ .name = "zprogress", .path = "packages/zprogress" },
        .{ .name = "terminal", .path = "packages/terminal" },
        .{ .name = "zinput", .path = "packages/zinput" },
        .{ .name = "ztheme", .path = "packages/ztheme" },
        .{ .name = "zcli", .path = "projects/zcli" },
        // The example apps and the vterm demo have test steps of their own
        // (addCommandTests / the demo's vterm-consumer suite); running them
        // here is what keeps them from silently rotting.
        .{ .name = "showcase", .path = "examples/showcase" },
        .{ .name = "repostat", .path = "examples/repostat" },
        .{ .name = "ghauth", .path = "examples/ghauth" },
        .{ .name = "notes", .path = "examples/notes" },
        .{ .name = "vterm_example", .path = "packages/vterm/example" },
    };

    // Canonical example CLIs (ADR-0004): first-class, CI-compiled artifacts that
    // are simultaneously the examples, the idiom source, and the drift-detector —
    // a breaking framework change breaks `zig build build-examples` (run in CI),
    // forcing the examples (and the context derived from them) back up to date.
    const example_projects = [_]ProjectInfo{
        .{ .name = "showcase", .path = "examples/showcase" },
        .{ .name = "repostat", .path = "examples/repostat" },
        .{ .name = "ghauth", .path = "examples/ghauth" },
        .{ .name = "notes", .path = "examples/notes" },
        .{ .name = "vterm_example", .path = "packages/vterm/example" },
    };

    const cli_projects = [_]ProjectInfo{
        .{ .name = "zcli", .path = "projects/zcli" },
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

    // Create build step for CLI projects
    const build_cli_step = b.step("build-cli", "Build all CLI tool projects");

    for (cli_projects) |cli| {
        // Create individual build step for this CLI
        const cli_build_step = b.step(b.fmt("build-{s}", .{cli.name}), b.fmt("Build {s} CLI", .{cli.name}));

        // Run the build for this CLI
        const cli_build_run = b.addSystemCommand(&.{"zig"});
        cli_build_run.addArgs(&.{"build"});
        cli_build_run.setCwd(b.path(cli.path));

        cli_build_step.dependOn(&cli_build_run.step);
        build_cli_step.dependOn(&cli_build_run.step);
    }

    // Create a comprehensive build step that builds and tests everything
    const build_all_step = b.step("build-all", "Build and test all subprojects");
    build_all_step.dependOn(test_step);
    build_all_step.dependOn(build_examples_step);
    build_all_step.dependOn(build_cli_step);

    // Make the default install step build everything important
    const install_step = b.getInstallStep();
    install_step.dependOn(build_cli_step);
    install_step.dependOn(build_examples_step);
}

// Re-export build utilities from core package for external projects
// When external projects do `const zcli = @import("zcli");` in their build.zig,
// they're importing this root build.zig from the tarball/git archive.
pub const generate = @import("packages/core/build.zig").generate;
pub const generateDocs = @import("packages/core/build.zig").generateDocs;
pub const addCommandTests = @import("packages/core/build.zig").addCommandTests;
pub const PluginConfig = @import("packages/core/build.zig").PluginConfig;
pub const Builtin = @import("packages/core/build.zig").Builtin;
pub const builtin = @import("packages/core/build.zig").builtin;
pub const SharedModule = @import("packages/core/build.zig").SharedModule;
