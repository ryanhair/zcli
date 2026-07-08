const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const theme_dep = b.dependency("theme", .{ .target = target, .optimize = optimize });
    const theme_module = theme_dep.module("theme");
    const terminal_dep = b.dependency("terminal", .{ .target = target, .optimize = optimize });
    const terminal_module = terminal_dep.module("terminal");
    const ui_dep = b.dependency("ui", .{ .target = target, .optimize = optimize });
    const ui_module = ui_dep.module("ui");

    // Main progress module
    const progress_mod = b.addModule("progress", .{
        .root_source_file = b.path("src/Progress.zig"),
        .target = target,
        .optimize = optimize,
    });
    progress_mod.addImport("theme", theme_module);
    progress_mod.addImport("terminal", terminal_module);
    progress_mod.addImport("ui", ui_module);

    // Tests are rooted at src/test.zig so the vterm golden-frame harness is
    // a test-only import, never a dependency of the shipped module.
    const vterm_dep = b.dependency("vterm", .{ .target = target, .optimize = optimize });

    const test_mod = b.addModule("test-progress", .{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("theme", theme_module);
    test_mod.addImport("terminal", terminal_module);
    test_mod.addImport("ui", ui_module);
    test_mod.addImport("vterm", vterm_dep.module("vterm"));

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
