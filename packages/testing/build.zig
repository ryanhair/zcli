const std = @import("std");
const build_utils = @import("src/build_utils.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies — the unit-testing tier (in-process command execution) needs the
    // zcli core module (Stdio, TestContext) and vterm (rendered-output assertions).
    const zcli_dep = b.dependency("zcli_core", .{ .target = target, .optimize = optimize });
    const vterm_dep = b.dependency("vterm", .{ .target = target, .optimize = optimize });

    // Create the testing module
    const testing_mod = b.addModule("testing", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    testing_mod.addImport("zcli", zcli_dep.module("zcli"));
    testing_mod.addImport("vterm", vterm_dep.module("vterm"));

    // Expose the PTY-based interactive harness (e2e.zig) as its own module.
    // It is std-only — no zcli/vterm — so CLI projects can drive a real TTY in
    // their e2e tests without pulling in the rest of the testing tier. The
    // root package re-exports this as `testing_e2e`.
    _ = b.addModule("e2e", .{
        .root_source_file = b.path("src/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create tests
    const test_mod = b.addModule("test-testing", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zcli", zcli_dep.module("zcli"));
    test_mod.addImport("vterm", vterm_dep.module("vterm"));
    const main_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_main_tests.step);
}

// Re-export build utilities for use in other build.zig files
pub const setup = build_utils.setup;
