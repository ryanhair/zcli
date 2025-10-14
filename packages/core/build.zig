const std = @import("std");
const types = @import("src/build_utils/types.zig");
const main = @import("src/build_utils/main.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main zcli module that will be exposed to users
    _ = b.addModule("zcli", .{
        .root_source_file = b.path("src/zcli.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build utilities module for build.zig files
    _ = b.addModule("build_utils", .{
        .root_source_file = b.path("src/build_utils.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests
    const test_step = b.step("test", "Run unit tests");
    const test_core_step = b.step("test-core", "Run core tests only");
    const test_plugins_step = b.step("test-plugins", "Run plugin tests only");
    const test_security_step = b.step("test-security", "Run security tests only");
    const test_sequential_step = b.step("test-seq", "Run tests sequentially (avoids conflicts)");
    const test_debug_step = b.step("test-debug", "Debug test hanging issue");

    // Core test files - zcli.zig imports everything else through the dependency chain
    const core_test_files = [_][]const u8{
        "src/zcli.zig", // Main entry point - imports args, options, errors, execution, etc.
        "src/build_utils.zig", // Standalone utility (has its own tests)
    };

    // Plugin test files
    const plugin_test_files = [_][]const u8{
        "src/plugin_global_options_test.zig",
        "src/plugin_system_test.zig",
        "src/plugin_integration_test.zig",
        "src/plugin_test.zig",
        "src/plugin_transformation_test.zig",
    };

    // Integration and edge case tests
    const integration_test_files = [_][]const u8{
        "src/system_validation_test.zig",
        "src/build_integration_test.zig",
    };

    // Security and fuzzing test files (separate category due to different requirements)
    const security_test_files = [_][]const u8{
        "src/security_test.zig",
        "src/fuzz_test.zig",
    };

    // Add core tests
    for (core_test_files) |test_file| {
        const test_mod = b.addModule(b.fmt("test-{s}", .{test_file}), .{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        const tests = b.addTest(.{
            .root_module = test_mod,
        });
        const run_tests = b.addRunArtifact(tests);
        test_core_step.dependOn(&run_tests.step);
        test_step.dependOn(&run_tests.step);
    }

    // Plugin tests - deadlock issue resolved by using stderr for output
    for (plugin_test_files) |test_file| {
        const test_mod = b.addModule(b.fmt("test-{s}", .{test_file}), .{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        const tests = b.addTest(.{
            .root_module = test_mod,
        });
        const run_tests = b.addRunArtifact(tests);
        test_plugins_step.dependOn(&run_tests.step);
    }

    // Add integration tests (parallel execution)
    for (integration_test_files) |test_file| {
        const test_mod = b.addModule(b.fmt("test-{s}", .{test_file}), .{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        const tests = b.addTest(.{
            .root_module = test_mod,
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    // Add security tests (parallel execution)
    for (security_test_files) |test_file| {
        const test_mod = b.addModule(b.fmt("test-{s}", .{test_file}), .{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        const tests = b.addTest(.{
            .root_module = test_mod,
        });
        const run_tests = b.addRunArtifact(tests);
        test_security_step.dependOn(&run_tests.step);
        test_step.dependOn(&run_tests.step);
    }

    // Sequential test execution (separate from parallel execution above)
    // This creates a completely separate dependency chain for sequential execution
    const all_test_files = core_test_files ++ plugin_test_files ++ integration_test_files ++ security_test_files;
    var previous_step: ?*std.Build.Step = null;

    for (all_test_files) |test_file| {
        const test_mod = b.addModule(b.fmt("seq-test-{s}", .{test_file}), .{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        const sequential_tests = b.addTest(.{
            .root_module = test_mod,
        });
        const sequential_run_tests = b.addRunArtifact(sequential_tests);

        if (previous_step) |prev| {
            sequential_run_tests.step.dependOn(prev);
        }
        previous_step = &sequential_run_tests.step;
    }

    if (previous_step) |final_step| {
        test_sequential_step.dependOn(final_step);
    }

    // Debug step - test just one potentially problematic file
    const debug_mod = b.addModule("debug-test", .{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    const debug_test = b.addTest(.{
        .root_module = debug_mod,
    });
    const run_debug_test = b.addRunArtifact(debug_test);
    test_debug_step.dependOn(&run_debug_test.step);

    // Benchmark step
    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark_runner.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Always optimize benchmarks
        }),
    });

    const run_benchmark = b.addRunArtifact(benchmark_exe);
    const benchmark_step = b.step("benchmark", "Run performance benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);

    // Regression test step
    const regression_exe = b.addExecutable(.{
        .name = "regression",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark_runner.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const run_regression = b.addRunArtifact(regression_exe);
    run_regression.addArg("--regression");
    const regression_step = b.step("regression", "Run performance regression tests");
    regression_step.dependOn(&run_regression.step);
}

// Re-export build utilities for both backwards compatibility and new plugin features
pub const BuildConfig = types.BuildConfig;
pub const PluginConfig = types.PluginConfig;
pub const ExternalPluginBuildConfig = types.ExternalPluginBuildConfig;
pub const generate = main.generate;
