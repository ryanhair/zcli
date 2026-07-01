const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const terminal_dep = b.dependency("terminal", .{ .target = target, .optimize = optimize });
    const ztheme_dep = b.dependency("ztheme", .{ .target = target, .optimize = optimize });

    const zinput_mod = b.addModule("zinput", .{
        .root_source_file = b.path("src/zinput.zig"),
        .target = target,
        .optimize = optimize,
    });
    zinput_mod.addImport("terminal", terminal_dep.module("terminal"));
    zinput_mod.addImport("ztheme", ztheme_dep.module("ztheme"));

    const test_step = b.step("test", "Run zinput tests");
    const test_mod = b.addModule("test-zinput", .{
        .root_source_file = b.path("src/zinput.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("terminal", terminal_dep.module("terminal"));
    test_mod.addImport("ztheme", ztheme_dep.module("ztheme"));
    const tests = b.addTest(.{ .root_module = test_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Cross-platform render tests: replay prompt output through the vterm
    // emulator. vterm is a *test-only* dependency — the shipped `zinput` module
    // above never imports it. Part of `test` so it runs everywhere `test-zinput`
    // does, including Windows CI (where the POSIX PTY harness can't).
    const vterm_dep = b.dependency("vterm", .{ .target = target, .optimize = optimize });
    const render_e2e_mod = b.addModule("render-e2e", .{
        .root_source_file = b.path("test/render_e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_e2e_mod.addImport("zinput", zinput_mod);
    render_e2e_mod.addImport("vterm", vterm_dep.module("vterm"));
    const render_e2e_tests = b.addTest(.{ .root_module = render_e2e_mod });
    test_step.dependOn(&b.addRunArtifact(render_e2e_tests).step);
}
