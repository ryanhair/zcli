const std = @import("std");
const types = @import("src/build_utils/types.zig");
const main = @import("src/build_utils/main.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const theme_dep = b.dependency("theme", .{
        .target = target,
        .optimize = optimize,
    });
    const markdown_dep = b.dependency("markdown", .{
        .target = target,
        .optimize = optimize,
    });
    const progress_dep = b.dependency("progress", .{
        .target = target,
        .optimize = optimize,
    });
    const ui_dep = b.dependency("ui", .{
        .target = target,
        .optimize = optimize,
    });
    const prompts_dep = b.dependency("prompts", .{
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
        .{ .name = "theme", .module = theme_dep.module("theme") },
        .{ .name = "markdown", .module = markdown_dep.module("markdown") },
        .{ .name = "progress", .module = progress_dep.module("progress") },
        .{ .name = "prompts", .module = prompts_dep.module("prompts") },
        .{ .name = "ui", .module = ui_dep.module("ui") },
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
    const fuzz_smoke_step = b.step("fuzz-smoke", "Run deterministic parser fuzz corpora");
    const fuzz_step = b.step("fuzz", "Run parser fuzz targets (add --fuzz[=iterations] for coverage-guided fuzzing)");
    const test_sequential_step = b.step("test-seq", "Run tests sequentially (avoids conflicts)");
    const test_secrets_step = b.step("test-secrets", "Run zcli_secrets tests (plugin surface + host backend compile/link)");
    const test_secrets_live_step = b.step("test-secrets-live", "Round-trip the host's native secrets backend against the real OS keychain (CI)");

    // Core test files - zcli.zig imports everything else through the dependency chain
    const core_test_files = [_][]const u8{
        "src/zcli.zig", // Main entry point - imports args, options, errors, execution, etc.
        "src/build_utils.zig", // Standalone utility (has its own tests)
        "src/plugins/zcli_docs/doc_escape.zig", // Doc-generator escaping rules (std-only, unit-tested here)
        "src/usage.zig", // Shared usage/synopsis conventions (std-only, unit-tested here)
        // The perf harness. Listed here purely so it is COMPILED by `zig build
        // test`: reachable only from benchmark_runner.zig, it sat outside every
        // aggregator and both `benchmark` and `regression` silently stopped
        // building at the 0.16 migration without a single check going red
        // (#738). Its own test block runs 10 iterations — negligible cost, and
        // it is the tripwire that keeps the two perf steps honest.
        "src/benchmark.zig",
    };

    // Real-socket http.Client tests live in their own binary, built ReleaseSafe.
    // Two reasons: (1) isolated here, the loopback round-trips run once instead
    // of riding into every zcli-importing test binary; (2) on Windows the
    // loopback connect intermittently loses a concurrent dial and the OS returns
    // STATUS_CONNECTION_REFUSED, which std 0.16 fails to map in
    // netConnectIpWindows and dumps as a noisy "unexpected NTSTATUS" stack trace.
    // That tracing is gated on `std.options.unexpected_error_tracing`, whose
    // default is `mode == .Debug` — and a test binary's root is the test runner
    // (so a `std_options` override in the test file is ignored). Building this
    // one binary ReleaseSafe flips the default off while keeping safety checks,
    // silencing the false positive without hiding it in any other binary.
    {
        const run_tests = addTestRun(b, "test-", "src/http_loopback_test.zig", target, .ReleaseSafe, &dep_imports);
        test_step.dependOn(&run_tests.step);
    }

    // Real-socket integration tests for the github-upgrade download→verify→
    // install pipeline, driven against a loopback fake-GitHub. Isolated and
    // built ReleaseSafe for the same reasons as http_loopback_test above; it
    // imports plugin.zig so it needs the "zcli" module.
    {
        const upgrade_integration_imports = [_]TestDep{.{ .name = "zcli", .module = zcli_module }} ++ dep_imports;
        const run_tests = addTestRun(b, "test-", "src/plugin_github_upgrade_integration_test.zig", target, .ReleaseSafe, &upgrade_integration_imports);
        test_plugins_step.dependOn(&run_tests.step);
        test_step.dependOn(&run_tests.step);
    }

    // Subprocess-runner integration tests. They need a real child, so a small
    // helper executable is compiled once here and its path handed to the test
    // binary through a build-options module — faster and more portable than
    // shelling out to the compiler from inside each test, and it works
    // identically on Windows.
    {
        const fixture = b.addExecutable(.{
            .name = "process-fixture",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/process_fixture.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        const fixture_options = b.addOptions();
        fixture_options.addOptionPath("exe_path", fixture.getEmittedBin());

        const process_imports = [_]TestDep{
            .{ .name = "fixture", .module = fixture_options.createModule() },
        } ++ dep_imports;
        const run_tests = addTestRun(b, "test-", "src/process_integration_test.zig", target, optimize, &process_imports);
        test_step.dependOn(&run_tests.step);
    }

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
        "src/plugins/zcli_help/plugin.zig",
        "src/plugins/zcli_config/plugin.zig",
        "src/plugin_config_integration_test.zig",
    };
    const plugin_test_imports = [_]TestDep{.{ .name = "zcli", .module = zcli_module }} ++ dep_imports;
    for (feature_plugin_test_files) |test_file| {
        const run_tests = addTestRun(b, "test-", test_file, target, optimize, &plugin_test_imports);
        test_plugins_step.dependOn(&run_tests.step);
        test_step.dependOn(&run_tests.step);
    }

    // Parser-focused fuzz tests use only stable public seams (`zcli`
    // parseCommandLine and response_file.expandArgs). In an ordinary build,
    // the fixed argv and response-file Smith corpora are deterministic,
    // bounded, and cheap enough for every OS in the default suite. Selecting
    // `fuzz` with Zig's build-runner `--fuzz[=N]` coverage-guides the in-memory
    // argv properties; response-file filesystem I/O remains smoke-only because
    // it does not terminate reliably inside Zig 0.16's hosted Linux/x86_64
    // multi-instance fuzzer.
    {
        const fuzz_mod = b.addModule("test-parser-fuzz", .{
            .root_source_file = b.path("src/parser_fuzz_test.zig"),
            .target = target,
            .optimize = optimize,
            // Zig 0.16.0's bundled compiler/test_runner.zig passes
            // builtin.StackTrace to debug.writeStackTrace, which now expects
            // debug.StackTrace. That dead error-reporting branch is analyzed
            // only when error-return tracing is enabled, making every -ffuzz
            // build fail in the toolchain itself. Disable it on this one
            // artifact until upstream's runner is corrected. Safety checks,
            // panic traces, leak checks, and normal-test error traces remain.
            .error_tracing = false,
        });
        for (plugin_test_imports) |dep| fuzz_mod.addImport(dep.name, dep.module);
        const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
        const run_tests = b.addRunArtifact(fuzz_tests);
        fuzz_smoke_step.dependOn(&run_tests.step);
        fuzz_step.dependOn(&run_tests.step);
        test_security_step.dependOn(&run_tests.step);
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
        // The Linux backends shell out through `zcli.process` (ADR-0034), so the
        // secrets modules need the framework module by name. A consuming app's
        // plugin module already gets it (`module_creation.zig`); these are the
        // repo-local ones, whose roots sit below `src/` and so cannot reach
        // `src/process.zig` by relative path. No cycle: `zcli.zig` does not
        // import the secrets plugin.
        plugin_mod.addImport("zcli", zcli_module);
        const plugin_tests = b.addTest(.{ .root_module = plugin_mod });
        const run_plugin_tests = b.addRunArtifact(plugin_tests);
        for ([_]*std.Build.Step{ test_plugins_step, test_secrets_step, test_step }) |s| {
            s.dependOn(&run_plugin_tests.step);
        }

        // The native backend source file for the host OS (null → no backend to
        // test here, i.e. an unsupported OS where registering the plugin is a
        // compile error). The Linux backend shells out rather than linking, so
        // it builds for gnu and musl alike — no musl carve-out needed (ADR-0010).
        const native_backend_file: ?[]const u8 = switch (target.result.os.tag) {
            .macos => "src/plugins/zcli_secrets/keychain_macos.zig",
            .linux => "src/plugins/zcli_secrets/linux.zig",
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
            backend_mod.addImport("zcli", zcli_module);
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
            live_mod.addImport("zcli", zcli_module);
            main.linkSecretsBackend(live_mod, target.result);
            // The live test reads the real process environment via libc's
            // `std.c.environ` to build a context for the shell-out backend (0.16
            // otherwise exposes it only through `std.process.Init`). This links
            // libc into the CI-only *test* binary, not the plugin — the shipped
            // Linux backend stays libc-free.
            live_mod.link_libc = true;
            const live_tests = b.addTest(.{ .root_module = live_mod });
            const run_live_tests = b.addRunArtifact(live_tests);
            test_secrets_live_step.dependOn(&run_live_tests.step);
        }
    }

    // The zcli_docs generator (`zig build docs`). Its tool.zig imports two
    // modules that normally only exist inside a CONSUMING project's build —
    // `command_registry` (emitted by zcli.generate) and `tool_config`
    // (emitted by wireToolStep) — which is why 704 lines of shipped,
    // README-advertised feature code was neither compiled nor tested by CI
    // (#739). Both are just modules with a handful of public decls, so hand
    // written fixtures stand in for them here and the generator's real output
    // gets asserted in-process. The `docs` CI step still runs the tool for
    // real against examples/tasks; this is the fast half that catches format
    // regressions, not only compile breaks.
    {
        const fixture_registry = b.addModule("test-docs-registry", .{
            .root_source_file = b.path("src/plugins/zcli_docs/test_registry.zig"),
            .target = target,
            .optimize = optimize,
        });
        fixture_registry.addImport("zcli", zcli_module);

        const fixture_config = b.addModule("test-docs-tool-config", .{
            .root_source_file = b.path("src/plugins/zcli_docs/test_tool_config.zig"),
            .target = target,
            .optimize = optimize,
        });

        const docs_tool_imports = [_]TestDep{
            .{ .name = "zcli", .module = zcli_module },
            .{ .name = "command_registry", .module = fixture_registry },
            .{ .name = "tool_config", .module = fixture_config },
        } ++ dep_imports;

        const run_tests = addTestRun(b, "test-", "src/plugins/zcli_docs/tool.zig", target, optimize, &docs_tool_imports);
        test_plugins_step.dependOn(&run_tests.step);
        test_step.dependOn(&run_tests.step);
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

    // Benchmark + regression steps. Both run the same executable
    // (benchmark_runner.zig); `--regression` picks the gating mode. Its module
    // needs `dep_imports` because benchmark.zig reaches command_parser.zig,
    // which sits in the same dependency web as the rest of core — omitting them
    // is half of why these two steps had not compiled since the 0.16 migration
    // (#738).
    const perf_module_imports = dep_imports;

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark_runner.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Always optimize benchmarks
        }),
    });
    for (perf_module_imports) |dep| benchmark_exe.root_module.addImport(dep.name, dep.module);

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
    for (perf_module_imports) |dep| regression_exe.root_module.addImport(dep.name, dep.module);

    const run_regression = b.addRunArtifact(regression_exe);
    run_regression.addArg("--regression");
    // Timing measurements are the point, so never serve a cached "success".
    run_regression.has_side_effects = true;
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
pub const CommandTestsConfig = types.CommandTestsConfig;
pub const PluginConfig = types.PluginConfig;
pub const ToolConfig = types.ToolConfig;
pub const Builtin = types.Builtin;
pub const builtin = types.builtin;
pub const config = types.config;
pub const SharedModule = types.SharedModule;
pub const CommandConfig = types.CommandConfig;
pub const CommandModule = types.CommandModule;
pub const CommandModuleConfig = types.CommandModuleConfig;
pub const GenerateError = main.GenerateError;
pub const generate = main.generate;
pub const addCommandTests = @import("src/build_utils/command_tests.zig").addCommandTests;
