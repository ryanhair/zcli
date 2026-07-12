const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Every package under packages/ is a standalone Zig package that owns its
    // own module wiring; the root is a thin umbrella over them. b.dependency
    // runs each package's build.zig inside this build's graph — one shared
    // cache, and -Dtarget/-Doptimize propagate — and the graph-level dependency
    // cache dedups shared subtrees, so e.g. core's, prompts's and progress's
    // `theme` all resolve to the same module instance, compiled once.
    const core_dep = b.dependency("zcli_core", .{ .target = target, .optimize = optimize });
    const testing_dep = b.dependency("testing", .{ .target = target, .optimize = optimize });
    const vterm_dep = b.dependency("vterm", .{ .target = target, .optimize = optimize });
    const vterm_example_dep = b.dependency("vterm_example", .{ .target = target, .optimize = optimize });
    const markdown_dep = b.dependency("markdown", .{ .target = target, .optimize = optimize });
    const terminal_dep = b.dependency("terminal", .{ .target = target, .optimize = optimize });
    const prompts_dep = b.dependency("prompts", .{ .target = target, .optimize = optimize });
    const progress_dep = b.dependency("progress", .{ .target = target, .optimize = optimize });
    const theme_dep = b.dependency("theme", .{ .target = target, .optimize = optimize });
    const ui_dep = b.dependency("ui", .{ .target = target, .optimize = optimize });

    // The public module surface of the zcli package — what consumers (external
    // projects, the examples, projects/zcli) get from `zcli_dep.module("...")`.
    // Aliased from the owning packages rather than re-declared here, so each
    // module's wiring lives in exactly one place: its package's build.zig.
    expose(b, "zcli", core_dep.module("zcli"));
    expose(b, "theme", theme_dep.module("theme"));
    expose(b, "markdown", markdown_dep.module("markdown"));
    expose(b, "terminal", terminal_dep.module("terminal"));
    expose(b, "progress", progress_dep.module("progress"));
    expose(b, "prompts", prompts_dep.module("prompts"));
    // The terminal-native layout engine (ADR-0013) — the substrate progress
    // and prompts render on, exposed for hybrid CLI/TUI apps.
    expose(b, "ui", ui_dep.module("ui"));
    // The subprocess/snapshot testing tier (std-only): compile the CLI, run it,
    // assert on stdout/stderr/exit code, and snapshot golden output. Lazy — costs
    // nothing unless a consumer imports it, and pulls in no zcli/vterm.
    expose(b, "zcli_testing", testing_dep.module("testing"));
    // The in-process unit-testing tier for scaffolded projects (see
    // `zcli.addCommandTests`): `runCommand` executes a command's execute() with no
    // subprocess, plus vterm-rendered assertions. Split from `zcli_testing` so the
    // subprocess/PTY-only tiers stay free of zcli/vterm.
    expose(b, "zcli_testing_unit", testing_dep.module("unit"));
    // The PTY-based interactive test harness alone (std-only), for CLI projects
    // that drive a real TTY in their e2e tests.
    expose(b, "testing_e2e", testing_dep.module("e2e"));
    // vterm itself is deliberately not exposed: it left the public umbrella
    // surface (scope decision), and consumers reach its assertions through
    // zcli_testing.

    // Create main test step that runs all tests
    const test_step = b.step("test", "Run all tests across all subprojects");

    // The packages test in-process: depend on the `test` step each package's
    // own build.zig defines. (`builder.top_level_steps` is how a parent
    // reaches a dependency's named steps.) The vterm example is included
    // here because it depends on packages/vterm, not on this root package.
    const test_packages = [_]struct {
        name: []const u8,
        dep: *std.Build.Dependency,
    }{
        .{ .name = "core", .dep = core_dep },
        .{ .name = "testing", .dep = testing_dep },
        .{ .name = "vterm", .dep = vterm_dep },
        .{ .name = "markdown", .dep = markdown_dep },
        .{ .name = "progress", .dep = progress_dep },
        .{ .name = "terminal", .dep = terminal_dep },
        .{ .name = "prompts", .dep = prompts_dep },
        .{ .name = "theme", .dep = theme_dep },
        .{ .name = "ui", .dep = ui_dep },
        .{ .name = "vterm_example", .dep = vterm_example_dep },
    };
    for (test_packages) |pkg| {
        const pkg_test = pkg.dep.builder.top_level_steps.get("test") orelse
            std.debug.panic("package '{s}' does not define a 'test' step", .{pkg.name});
        const project_test_step = b.step(b.fmt("test-{s}", .{pkg.name}), b.fmt("Run tests for {s}", .{pkg.name}));
        project_test_step.dependOn(&pkg_test.step);
        test_step.dependOn(&pkg_test.step);
    }

    // Forward core's specialized steps so they run from the repo root too.
    // They are deliberately NOT part of the aggregate `test`: the secrets
    // steps link native libraries / touch the OS keychain (ADR-0003), and the
    // performance runs build ReleaseFast.
    for ([_][]const u8{ "test-secrets", "test-secrets-live", "benchmark", "regression" }) |name| {
        const core_step = core_dep.builder.top_level_steps.get(name) orelse
            std.debug.panic("core package does not define a '{s}' step", .{name});
        b.step(name, core_step.description).dependOn(&core_step.step);
    }

    const ProjectInfo = struct {
        name: []const u8,
        path: []const u8,
    };

    // The example CLIs and projects/zcli depend on this root package itself
    // (`.zcli = .{ .path = "../.." }`), so they cannot be b.dependency'd from
    // here — that would be a package cycle. They build and test as
    // subprocesses instead, which is also what makes them canonical (ADR-0004):
    // they exercise the exact path an external consumer takes through this
    // package, including its manifest and module exports.
    const test_projects = [_]ProjectInfo{
        .{ .name = "zcli", .path = "projects/zcli" },
        .{ .name = "tasks", .path = "examples/tasks" },
        .{ .name = "repostat", .path = "examples/repostat" },
        .{ .name = "ghauth", .path = "examples/ghauth" },
        .{ .name = "oauth-device", .path = "examples/oauth-device" },
        .{ .name = "notes", .path = "examples/notes" },
    };

    // Add tests for each project that has them
    for (test_projects) |project| {
        // Create individual test step for this project
        const project_test_step = b.step(b.fmt("test-{s}", .{project.name}), b.fmt("Run tests for {s}", .{project.name}));

        // Print a message before running tests for this project, since the
        // subprocess output is otherwise unattributed.
        const print_start = b.addSystemCommand(&.{"echo"});
        print_start.addArg(b.fmt("\n==> Running tests for {s} ({s})", .{ project.name, project.path }));

        // Run the test step from the subproject directory. b.graph.zig_exe is
        // the compiler running THIS build — a bare "zig" from PATH can resolve
        // to a different toolchain under version managers like mise.
        const project_test_run = b.addSystemCommand(&.{b.graph.zig_exe});
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

    // Canonical example CLIs (ADR-0004): first-class, CI-compiled artifacts that
    // are simultaneously the examples, the idiom source, and the drift-detector —
    // a breaking framework change breaks `zig build build-examples` (run in CI),
    // forcing the examples (and the context derived from them) back up to date.
    // (The vterm example's demo executable is built here too; only its test
    // suite runs in-process above.)
    const example_projects = [_]ProjectInfo{
        .{ .name = "tasks", .path = "examples/tasks" },
        .{ .name = "repostat", .path = "examples/repostat" },
        .{ .name = "ghauth", .path = "examples/ghauth" },
        .{ .name = "oauth-device", .path = "examples/oauth-device" },
        .{ .name = "notes", .path = "examples/notes" },
        .{ .name = "vterm_example", .path = "packages/vterm/example" },
    };

    // Create build step for examples
    const build_examples_step = b.step("build-examples", "Build all example projects");

    for (example_projects) |example| {
        // Create individual build step for this example
        const example_build_step = b.step(b.fmt("build-{s}", .{example.name}), b.fmt("Build {s} example", .{example.name}));

        // Run the build for this example
        const example_build_run = b.addSystemCommand(&.{b.graph.zig_exe});
        example_build_run.addArgs(&.{"build"});
        example_build_run.setCwd(b.path(example.path));

        example_build_step.dependOn(&example_build_run.step);
        build_examples_step.dependOn(&example_build_run.step);
    }

    const cli_projects = [_]ProjectInfo{
        .{ .name = "zcli", .path = "projects/zcli" },
    };

    // Create build step for CLI projects
    const build_cli_step = b.step("build-cli", "Build all CLI tool projects");

    for (cli_projects) |cli| {
        // Create individual build step for this CLI
        const cli_build_step = b.step(b.fmt("build-{s}", .{cli.name}), b.fmt("Build {s} CLI", .{cli.name}));

        // Run the build for this CLI
        const cli_build_run = b.addSystemCommand(&.{b.graph.zig_exe});
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

/// Re-export a module owned by one of the packages under `name` on this
/// package, so `zcli_dep.module(name)` resolves for consumers. This is what
/// `b.addModule` does minus creating a new module.
fn expose(b: *std.Build, name: []const u8, module: *std.Build.Module) void {
    b.modules.put(b.graph.arena, b.dupe(name), module) catch @panic("OOM");
}

// Re-export build utilities from core package for external projects.
// When external projects do `const zcli = @import("zcli");` in their build.zig,
// they're importing this root build.zig from the tarball/git archive — and this
// file reaches core's build.zig the same way, as the `zcli_core` dependency's
// build module (a source-path @import would clash with core also being a
// package: a file can only belong to one module).
const zcli_core = @import("zcli_core");
pub const generate = zcli_core.generate;
pub const generateDocs = zcli_core.generateDocs;
pub const addCommandTests = zcli_core.addCommandTests;
pub const GenerateError = zcli_core.GenerateError;
pub const GenerateConfig = zcli_core.GenerateConfig;
pub const DocsConfig = zcli_core.DocsConfig;
pub const CommandTestsConfig = zcli_core.CommandTestsConfig;
pub const PluginConfig = zcli_core.PluginConfig;
pub const Builtin = zcli_core.Builtin;
pub const builtin = zcli_core.builtin;
pub const SharedModule = zcli_core.SharedModule;
