const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get theme dependency
    const theme_dep = b.dependency("theme", .{
        .target = target,
        .optimize = optimize,
    });
    const theme_module = theme_dep.module("theme");

    // Create the markdown module
    const markdown_mod = b.addModule("markdown", .{
        .root_source_file = b.path("src/main.zig"),
    });
    markdown_mod.addImport("theme", theme_module);

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("theme", theme_module);
    const main_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Runnable examples — one per topic. `zig build examples` builds them all;
    // `zig build run-<name>` runs one (they print styled ANSI, so a real
    // terminal shows color — piping still works). Each is also compiled by
    // `test` so the examples can't bitrot against the API.
    const example_names = [_][]const u8{
        "elements", "semantic",     "interpolation",
        "palette",  "capabilities", "build_report",
    };
    const examples_step = b.step("examples", "Build all markdown examples");
    for (example_names) |name| {
        const exe = b.addExecutable(.{
            .name = b.fmt("markdown-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("markdown", markdown_mod);

        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        test_step.dependOn(&exe.step); // compile-check in CI without running

        const run = b.addRunArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name}));
        run_step.dependOn(&run.step);
    }
}
