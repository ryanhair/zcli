const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    const zcli_testing_dep = b.dependency("zcli_testing", .{
        .target = target,
        .optimize = optimize,
    });

    // Create a simple CLI executable for testing
    const exe = b.addExecutable(.{
        .name = "example-cli",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zcli", zcli_dep.module("zcli"));

    // Generate command registry
    const zcli = @import("zcli");
    const cmd_registry = zcli.generate(b, exe, zcli_dep.module("zcli"), .{
        .commands_dir = "src/commands",
        .plugins = &[_]zcli.PluginConfig{
            .{
                .name = "zcli-help",
                .path = "../../plugins/zcli-help",
            },
        },
        .app_name = "example-cli",
        .app_version = "1.0.0",
        .app_description = "Example CLI for testing zcli-testing",
    });
    exe.root_module.addImport("command_registry", cmd_registry);

    const install_exe_step = b.addInstallArtifact(exe, .{});

    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};

    // Create tests using zcli-testing
    const cli_tests = b.addTest(.{
        .root_source_file = b.path("tests/cli_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
    });
    cli_tests.root_module.addImport("zcli", zcli_dep.module("zcli"));
    cli_tests.root_module.addImport("zcli_testing", zcli_testing_dep.module("zcli-testing"));
    cli_tests.root_module.addImport("command_registry", cmd_registry);
    cli_tests.step.dependOn(&install_exe_step.step); // Ensure CLI is built AND installed first

    // Create interactive tests
    const interactive_tests = b.addTest(.{
        .root_source_file = b.path("tests/interactive_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
    });
    interactive_tests.root_module.addImport("zcli_testing", zcli_testing_dep.module("zcli-testing"));
    interactive_tests.step.dependOn(&install_exe_step.step); // Ensure CLI is built first

    // Create terminal feature tests
    const terminal_tests = b.addTest(.{
        .root_source_file = b.path("tests/terminal_test.zig"),
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
    });
    terminal_tests.root_module.addImport("zcli_testing", zcli_testing_dep.module("zcli-testing"));
    terminal_tests.step.dependOn(&install_exe_step.step); // Ensure CLI is built first

    const run_tests = b.addRunArtifact(cli_tests);
    const run_interactive_tests = b.addRunArtifact(interactive_tests);
    const run_terminal_tests = b.addRunArtifact(terminal_tests);

    const test_step = b.step("test", "Run CLI tests");
    test_step.dependOn(&run_tests.step);
    
    // Update snapshots command
    const update_snapshots_step = b.step("update-snapshots", "Update all test snapshots");
    
    // Clean existing snapshots first
    const cleanup_snapshots = b.addRemoveDirTree(b.path("tests/snapshots"));
    update_snapshots_step.dependOn(&cleanup_snapshots.step);
    
    const update_run_tests = b.addRunArtifact(cli_tests);
    update_run_tests.setEnvironmentVariable("UPDATE_SNAPSHOTS", "1");
    update_run_tests.step.dependOn(&cleanup_snapshots.step);
    update_snapshots_step.dependOn(&update_run_tests.step);

    const interactive_test_step = b.step("test-interactive", "Run interactive CLI tests");
    interactive_test_step.dependOn(&run_interactive_tests.step);

    const terminal_test_step = b.step("test-terminal", "Run terminal feature tests");
    terminal_test_step.dependOn(&run_terminal_tests.step);

    const all_test_step = b.step("test-all", "Run all tests");
    all_test_step.dependOn(&run_tests.step);
    all_test_step.dependOn(&run_interactive_tests.step);
    all_test_step.dependOn(&run_terminal_tests.step);

    // Add manual PTY test runner
    const manual_test = b.addExecutable(.{
        .name = "manual_pty_test",
        .root_source_file = b.path("manual_pty_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    manual_test.root_module.addImport("zcli_testing", zcli_testing_dep.module("zcli-testing"));
    manual_test.step.dependOn(&install_exe_step.step); // Ensure CLI is built first

    const run_manual_test = b.addRunArtifact(manual_test);
    const manual_test_step = b.step("test-pty", "Test PTY functionality manually");
    manual_test_step.dependOn(&run_manual_test.step);
}
