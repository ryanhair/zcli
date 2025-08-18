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
        "src/errors.zig",
        "src/build_utils.zig",
        "src/execution.zig", // Base pipeline types
        "src/build_integration_test.zig", // Integration tests for build system
        "src/error_edge_cases_test.zig", // Edge cases and error handling tests
        "src/plugin_test.zig", // Plugin system tests
        "src/plugin_integration_test.zig", // Plugin integration tests
        "src/test_transformer_plugin.zig", // Test transformer plugin
        "src/pipeline_integration_test.zig", // Pipeline integration tests
        "src/benchmark.zig", // Performance benchmarks
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

    // Benchmark step
    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("src/benchmark_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always optimize benchmarks
    });

    const run_benchmark = b.addRunArtifact(benchmark_exe);
    const benchmark_step = b.step("benchmark", "Run performance benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);

    // Regression test step
    const regression_exe = b.addExecutable(.{
        .name = "regression",
        .root_source_file = b.path("src/benchmark_runner.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const run_regression = b.addRunArtifact(regression_exe);
    run_regression.addArg("--regression");
    const regression_step = b.step("regression", "Run performance regression tests");
    regression_step.dependOn(&run_regression.step);
}

// Re-export build utilities for both backwards compatibility and new plugin features
pub const generateCommandRegistry = build_utils.generateCommandRegistry;
pub const BuildConfig = build_utils.BuildConfig;
pub const buildWithPlugins = build_utils.buildWithPlugins;
pub const PluginConfig = build_utils.PluginConfig;
pub const ExternalPluginBuildConfig = build_utils.ExternalPluginBuildConfig;
pub const buildWithExternalPlugins = build_utils.buildWithExternalPlugins;
