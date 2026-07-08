const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const terminal_dep = b.dependency("terminal", .{ .target = target, .optimize = optimize });
    const theme_dep = b.dependency("theme", .{ .target = target, .optimize = optimize });
    const ui_dep = b.dependency("ui", .{ .target = target, .optimize = optimize });

    const prompts_mod = b.addModule("prompts", .{
        .root_source_file = b.path("src/Prompts.zig"),
        .target = target,
        .optimize = optimize,
    });
    prompts_mod.addImport("terminal", terminal_dep.module("terminal"));
    prompts_mod.addImport("theme", theme_dep.module("theme"));
    prompts_mod.addImport("ui", ui_dep.module("ui"));

    const test_step = b.step("test", "Run prompts tests");
    const test_mod = b.addModule("test-prompts", .{
        .root_source_file = b.path("src/Prompts.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("terminal", terminal_dep.module("terminal"));
    test_mod.addImport("theme", theme_dep.module("theme"));
    test_mod.addImport("ui", ui_dep.module("ui"));
    const tests = b.addTest(.{ .root_module = test_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Cross-platform render tests: replay prompt output through the vterm
    // emulator. vterm is a *test-only* dependency — the shipped `prompts` module
    // above never imports it. Part of `test` so it runs everywhere `test-prompts`
    // does, including Windows CI (where the POSIX PTY harness can't).
    const vterm_dep = b.dependency("vterm", .{ .target = target, .optimize = optimize });
    const render_e2e_mod = b.addModule("render-e2e", .{
        .root_source_file = b.path("test/render_e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_e2e_mod.addImport("prompts", prompts_mod);
    render_e2e_mod.addImport("vterm", vterm_dep.module("vterm"));
    render_e2e_mod.addImport("ui", ui_dep.module("ui"));
    const render_e2e_tests = b.addTest(.{ .root_module = render_e2e_mod });
    test_step.dependOn(&b.addRunArtifact(render_e2e_tests).step);

    // Runnable examples — one per input type. `zig build examples` builds them
    // all; `zig build run-<name>` runs one (they're interactive, so they need a
    // real terminal). Each is also compiled by `test` so they can't bitrot.
    const example_names = [_][]const u8{
        "text",     "confirm", "select", "multi_select",
        "password", "search",  "number", "editor",
    };
    const examples_step = b.step("examples", "Build all interactive prompt examples");
    for (example_names) |name| {
        const exe = b.addExecutable(.{
            .name = b.fmt("prompts-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("prompts", prompts_mod);

        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        test_step.dependOn(&exe.step); // compile-check in CI without running

        const run = b.addRunArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} prompt example", .{name}));
        run_step.dependOn(&run.step);
    }
}
