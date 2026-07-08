const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{ .target = target, .optimize = optimize });
    const theme_dep = b.dependency("theme", .{ .target = target, .optimize = optimize });
    const terminal_dep = b.dependency("terminal", .{ .target = target, .optimize = optimize });

    // Main ui module
    const mod = b.addModule("ui", .{
        .root_source_file = b.path("src/ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("Graphemes", zg.module("Graphemes"));
    mod.addImport("theme", theme_dep.module("theme"));
    mod.addImport("terminal", terminal_dep.module("terminal"));

    // Tests are rooted at src/test.zig so the vterm golden-frame harness is a
    // test-only import, never a dependency of the shipped module.
    const vterm_dep = b.dependency("vterm", .{ .target = target, .optimize = optimize });

    const test_mod = b.addModule("test-ui", .{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("Graphemes", zg.module("Graphemes"));
    test_mod.addImport("theme", theme_dep.module("theme"));
    test_mod.addImport("terminal", terminal_dep.module("terminal"));
    test_mod.addImport("vterm", vterm_dep.module("vterm"));

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run ui tests");
    test_step.dependOn(&run_tests.step);

    // Runnable demo — `zig build run-demo` (it animates, so it needs a real
    // terminal). Compiled by `test` so it can't bitrot.
    const demo = b.addExecutable(.{
        .name = "ui-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    demo.root_module.addImport("ui", mod);
    demo.root_module.addImport("terminal", terminal_dep.module("terminal"));
    test_step.dependOn(&demo.step);

    const run_demo = b.addRunArtifact(demo);
    const demo_step = b.step("run-demo", "Run the animated ui demo (needs a TTY)");
    demo_step.dependOn(&run_demo.step);
}
