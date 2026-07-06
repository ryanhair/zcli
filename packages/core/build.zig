const std = @import("std");
const types = @import("src/build_utils/types.zig");
const main = @import("src/build_utils/main.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const ztheme_dep = b.dependency("ztheme", .{
        .target = target,
        .optimize = optimize,
    });
    const markdown_fmt_dep = b.dependency("markdown_fmt", .{
        .target = target,
        .optimize = optimize,
    });
    const zprogress_dep = b.dependency("zprogress", .{
        .target = target,
        .optimize = optimize,
    });
    const zinput_dep = b.dependency("zinput", .{
        .target = target,
        .optimize = optimize,
    });
    const serde_dep = b.dependency("serde", .{
        .target = target,
        .optimize = optimize,
    });

    // The dependency imports every zcli-sourced module needs — the main module
    // and each test module below get exactly this set.
    const dep_imports = [_]TestDep{
        .{ .name = "ztheme", .module = ztheme_dep.module("ztheme") },
        .{ .name = "markdown_fmt", .module = markdown_fmt_dep.module("markdown_fmt") },
        .{ .name = "zprogress", .module = zprogress_dep.module("zprogress") },
        .{ .name = "zinput", .module = zinput_dep.module("zinput") },
        .{ .name = "serde", .module = serde_dep.module("serde") },
    };

    // Main zcli module that will be exposed to users
    const zcli_module = b.addModule("zcli", .{
        .root_source_file = b.path("src/zcli.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (dep_imports) |dep| zcli_module.addImport(dep.name, dep.module);

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
    const test_secrets_step = b.step("test-secrets", "Run zcli_secrets tests (plugin surface + host backend compile/link)");
    const test_secrets_live_step = b.step("test-secrets-live", "Round-trip the host's native secrets backend against the real OS keychain (CI)");

    // Core test files - zcli.zig imports everything else through the dependency chain
    const core_test_files = [_][]const u8{
        "src/zcli.zig", // Main entry point - imports args, options, errors, execution, etc.
        "src/build_utils.zig", // Standalone utility (has its own tests)
    };

    // NOTE: A previous `plugin_test_files` list referenced five src/plugin_*_test.zig
    // files that were dropped in the monorepo refactor (commit 0aa79f7) and never
    // re-added. They targeted a since-replaced plugin/context API, so they were
    // removed rather than restored as-is. Plugin behavior is exercised by the
    // feature-plugin tests below and the inline tests in registry.zig/zcli.zig;
    // the pipeline-level coverage is being rebuilt in plugin_pipeline_test.zig.

    // Integration and edge case tests
    const integration_test_files = [_][]const u8{
        "src/system_validation_test.zig",
        "src/build_integration_test.zig",
    };

    // Security and randomized-property test files (separate category due to different requirements)
    const security_test_files = [_][]const u8{
        "src/security_test.zig",
        "src/property_test.zig",
    };

    // Add core tests
    for (core_test_files) |test_file| {
        const run_tests = addTestRun(b, "test-", test_file, target, optimize, &dep_imports);
        test_core_step.dependOn(&run_tests.step);
        test_step.dependOn(&run_tests.step);
    }

    // Add integration tests (parallel execution)
    for (integration_test_files) |test_file| {
        const run_tests = addTestRun(b, "test-", test_file, target, optimize, &dep_imports);
        test_step.dependOn(&run_tests.step);
    }

    // Add security tests (parallel execution)
    for (security_test_files) |test_file| {
        const run_tests = addTestRun(b, "test-", test_file, target, optimize, &dep_imports);
        test_security_step.dependOn(&run_tests.step);
        test_step.dependOn(&run_tests.step);
    }

    // Feature-plugin tests that import plugin source directly and therefore need
    // the "zcli" module. These run as part of the default `test` step.
    const feature_plugin_test_files = [_][]const u8{
        "src/plugin_completions_test.zig",
        "src/plugin_github_upgrade_test.zig",
        "src/plugin_pipeline_test.zig",
        "src/plugins/zcli_config/plugin.zig",
    };
    const plugin_test_imports = [_]TestDep{.{ .name = "zcli", .module = zcli_module }} ++ dep_imports;
    for (feature_plugin_test_files) |test_file| {
        const run_tests = addTestRun(b, "test-", test_file, target, optimize, &plugin_test_imports);
        test_plugins_step.dependOn(&run_tests.step);
        test_step.dependOn(&run_tests.step);
    }

    // Secrets plugin tests. The plugin-surface test is pure Zig and runs on
    // every supported OS. The host's native backend gets a compile+link test
    // (the link-time half of ADR-0003's opt-in guarantee) plus a CI-only live
    // round-trip against the real OS keychain. Native linking is applied exactly
    // as a registered app gets it, via `main.linkSecretsBackend`.
    {
        const plugin_mod = b.addModule("test-secrets-plugin", .{
            .root_source_file = b.path("src/plugins/zcli_secrets/plugin.zig"),
            .target = target,
            .optimize = optimize,
        });
        const plugin_tests = b.addTest(.{ .root_module = plugin_mod });
        const run_plugin_tests = b.addRunArtifact(plugin_tests);
        for ([_]*std.Build.Step{ test_plugins_step, test_secrets_step, test_step }) |s| {
            s.dependOn(&run_plugin_tests.step);
        }

        // The native backend source file for the host OS (null → no backend to
        // test here). Two cases yield null: an unsupported OS, where registering
        // the plugin is a compile error; and a musl-linux target, where the Linux
        // backend links libsecret (glibc) and `linkSecretsBackend` would panic.
        // The panic must not fire here — this test wiring runs during build-graph
        // construction for EVERY target, so leaving the musl case in would break
        // any `zig build` of a downstream musl binary (e.g. the CLI's own
        // static-musl release build), even one that never registers the plugin.
        const native_backend_file: ?[]const u8 = switch (target.result.os.tag) {
            .macos => "src/plugins/zcli_secrets/keychain_macos.zig",
            .linux => if (target.result.abi.isMusl()) null else "src/plugins/zcli_secrets/secret_service_linux.zig",
            .windows => "src/plugins/zcli_secrets/credential_manager_windows.zig",
            else => null,
        };

        if (native_backend_file) |backend_file| {
            // Compile + link the native backend (does not touch the real store).
            // Only in `test-secrets`, never the default `test`: it pulls in a
            // native lib (libsecret on Linux), and keeping the plain `zig build
            // test` lib-free avoids friction for devs without those dev packages.
            const backend_mod = b.addModule("test-secrets-backend", .{
                .root_source_file = b.path(backend_file),
                .target = target,
                .optimize = optimize,
            });
            main.linkSecretsBackend(backend_mod, target.result);
            const backend_tests = b.addTest(.{ .root_module = backend_mod });
            const run_backend_tests = b.addRunArtifact(backend_tests);
            test_secrets_step.dependOn(&run_backend_tests.step);

            // Live round-trip against the real OS keychain — CI-only, so it is
            // wired ONLY into the dedicated `test-secrets-live` step.
            const live_mod = b.addModule("test-secrets-live", .{
                .root_source_file = b.path("src/plugins/zcli_secrets/secrets_live_test.zig"),
                .target = target,
                .optimize = optimize,
            });
            main.linkSecretsBackend(live_mod, target.result);
            const live_tests = b.addTest(.{ .root_module = live_mod });
            const run_live_tests = b.addRunArtifact(live_tests);
            test_secrets_live_step.dependOn(&run_live_tests.step);
        }
    }

    // Sequential test execution (separate from parallel execution above)
    // This creates a completely separate dependency chain for sequential execution
    const all_test_files = core_test_files ++ integration_test_files ++ security_test_files;
    var previous_step: ?*std.Build.Step = null;

    for (all_test_files) |test_file| {
        const sequential_run_tests = addTestRun(b, "seq-test-", test_file, target, optimize, &dep_imports);
        if (previous_step) |prev| {
            sequential_run_tests.step.dependOn(prev);
        }
        previous_step = &sequential_run_tests.step;
    }

    if (previous_step) |final_step| {
        test_sequential_step.dependOn(final_step);
    }

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

/// A named module import shared by the test modules below.
const TestDep = struct { name: []const u8, module: *std.Build.Module };

/// Create a test module for `test_file` with the given imports, compile it,
/// and return its run step for the caller to wire into steps.
fn addTestRun(
    b: *std.Build,
    name_prefix: []const u8,
    test_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: []const TestDep,
) *std.Build.Step.Run {
    const test_mod = b.addModule(b.fmt("{s}{s}", .{ name_prefix, test_file }), .{
        .root_source_file = b.path(test_file),
        .target = target,
        .optimize = optimize,
    });
    for (deps) |dep| test_mod.addImport(dep.name, dep.module);
    const tests = b.addTest(.{ .root_module = test_mod });
    return b.addRunArtifact(tests);
}

// Re-export the build utilities that make up the consumer-facing build API
pub const BuildConfig = types.BuildConfig;
pub const GenerateConfig = types.GenerateConfig;
pub const DocsConfig = types.DocsConfig;
pub const CommandTestsConfig = types.CommandTestsConfig;
pub const PluginConfig = types.PluginConfig;
pub const Builtin = types.Builtin;
pub const builtin = types.builtin;
pub const SharedModule = types.SharedModule;
pub const CommandConfig = types.CommandConfig;
pub const CommandModule = types.CommandModule;
pub const CommandModuleConfig = types.CommandModuleConfig;
pub const GenerateError = main.GenerateError;
pub const generate = main.generate;
pub const generateDocs = main.generateDocs;
pub const addCommandTests = @import("src/build_utils/command_tests.zig").addCommandTests;
