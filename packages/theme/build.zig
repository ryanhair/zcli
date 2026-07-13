const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the theme module
    const theme_mod = b.addModule("theme", .{
        .root_source_file = b.path("src/theme.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests for the theme library - run all tests through main module
    const test_mod = b.addModule("test-theme", .{
        .root_source_file = b.path("src/theme.zig"),
        .target = target,
        .optimize = optimize,
    });
    const theme_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_theme_tests = b.addRunArtifact(theme_tests);

    const test_step = b.step("test", "Run theme library tests");
    test_step.dependOn(&run_theme_tests.step);

    // Runnable examples — `zig build examples` builds them all; `zig build
    // run-<name>` runs one. They print to stdout and are non-interactive, so
    // they work piped too (which itself demonstrates capability detection).
    // Each is also compiled by `test` so it can't bitrot.
    const example_names = [_][]const u8{ "showcase", "degradation", "custom_theme", "detect" };
    const examples_step = b.step("examples", "Build all theme examples");
    for (example_names) |name| {
        const exe = b.addExecutable(.{
            .name = b.fmt("theme-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("theme", theme_mod);

        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        test_step.dependOn(&exe.step); // compile-check in CI without running

        // Steps use dashes, so `custom_theme` runs as `run-custom-theme`.
        const run_name = b.fmt("run-{s}", .{name});
        for (run_name) |*c| {
            if (c.* == '_') c.* = '-';
        }
        const run = b.addRunArtifact(exe);
        const run_step = b.step(run_name, b.fmt("Run the {s} example", .{name}));
        run_step.dependOn(&run.step);
    }
}
