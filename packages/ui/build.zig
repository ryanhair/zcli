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

    // Runnable examples — `zig build run-<name>` (they animate, so they need
    // a real terminal). Each is compiled by `test` so it can't bitrot.
    const example_names = [_][]const u8{ "demo", "hybrid", "fullscreen" };
    for (example_names) |name| {
        const exe = b.addExecutable(.{
            .name = b.fmt("ui-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("ui", mod);
        exe.root_module.addImport("terminal", terminal_dep.module("terminal"));
        test_step.dependOn(&exe.step);

        const run = b.addRunArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the animated {s} example (needs a TTY)", .{name}));
        run_step.dependOn(&run.step);
    }
}
