const std = @import("std");
const build_utils = @import("src/build_utils.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies — only the unit-testing tier (in-process command execution)
    // needs the zcli core module (Stdio, TestContext) and vterm (rendered-output
    // assertions). The subprocess/snapshot and PTY tiers are std-only.
    const zcli_dep = b.dependency("zcli_core", .{ .target = target, .optimize = optimize });
    const vterm_dep = b.dependency("vterm", .{ .target = target, .optimize = optimize });

    // The subprocess/snapshot testing tier (main.zig): std-only, so importing it
    // does NOT drag zcli/vterm/serde into a consumer's test build. The root
    // package re-exports this as `zcli_testing`.
    const testing_mod = b.addModule("testing", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The in-process unit-testing tier (unit.zig): `runCommand` executes a
    // command's execute() without a subprocess, so it needs zcli (Stdio,
    // TestContext) and vterm (rendered-output assertions). Split into its own
    // module so subprocess/PTY-only consumers don't pay for those deps. The root
    // package re-exports this as `zcli_testing_unit`, and `addCommandTests` wires
    // it into scaffolded command tests under the import name `zcli-testing`.
    const unit_mod = b.addModule("unit", .{
        .root_source_file = b.path("src/unit.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_mod.addImport("zcli", zcli_dep.module("zcli"));
    unit_mod.addImport("vterm", vterm_dep.module("vterm"));

    // Expose the PTY-based interactive harness (e2e.zig) as its own module.
    // It is std-only — no zcli/vterm — so CLI projects can drive a real TTY in
    // their e2e tests without pulling in the rest of the testing tier. The
    // root package re-exports this as `testing_e2e`.
    const e2e_mod = b.addModule("e2e", .{
        .root_source_file = b.path("src/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all tests");

    // Tests for the std-only tier (main.zig re-exports subprocess/snapshot/e2e).
    const testing_test_mod = b.addModule("test-testing", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const testing_tests = b.addTest(.{ .root_module = testing_test_mod });
    test_step.dependOn(&b.addRunArtifact(testing_tests).step);

    // Tests for the unit tier (needs zcli/vterm).
    const unit_test_mod = b.addModule("test-unit", .{
        .root_source_file = b.path("src/unit.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_test_mod.addImport("zcli", zcli_dep.module("zcli"));
    unit_test_mod.addImport("vterm", vterm_dep.module("vterm"));
    const unit_tests = b.addTest(.{ .root_module = unit_test_mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // ------------------------------------------------------------------------
    // Examples — runnable, commented sample tests, one per tier. `zig build
    // examples` compiles and runs them exactly the way a consumer would, so they
    // double as living documentation that can't silently rot. Each example is
    // its own test root importing only the tier it demonstrates, under the same
    // alias a real project uses (`zcli-testing` / `testing_e2e`).
    const examples_step = b.step("examples", "Run the example tests (one per tier)");

    // Unit tier: `runCommand`. Imports the in-process tier as `zcli-testing`
    // (the scaffolded alias) plus `zcli` for TestContext.
    const unit_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/unit_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_example_mod.addImport("zcli-testing", unit_mod);
    unit_example_mod.addImport("zcli", zcli_dep.module("zcli"));
    const unit_example_tests = b.addTest(.{ .root_module = unit_example_mod });
    examples_step.dependOn(&b.addRunArtifact(unit_example_tests).step);

    // Integration/snapshot tier: `runSubprocess`, `expectSnapshot`. Std-only, so
    // the `zcli-testing` alias here points at the subprocess/snapshot module.
    const snapshot_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/snapshot_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    snapshot_example_mod.addImport("zcli-testing", testing_mod);
    const snapshot_example_tests = b.addTest(.{ .root_module = snapshot_example_mod });
    examples_step.dependOn(&b.addRunArtifact(snapshot_example_tests).step);

    // E2E (PTY) tier: `InteractiveScript` + `runInteractive`. Std-only harness,
    // imported as `testing_e2e`.
    const e2e_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/e2e_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_example_mod.addImport("testing_e2e", e2e_mod);
    const e2e_example_tests = b.addTest(.{ .root_module = e2e_example_mod });
    examples_step.dependOn(&b.addRunArtifact(e2e_example_tests).step);

    // Fold the examples into `zig build test` too, so the samples are verified on
    // every test run and can't drift from the API they document.
    test_step.dependOn(examples_step);
}

// Re-export build utilities for use in other build.zig files
pub const setup = build_utils.setup;
