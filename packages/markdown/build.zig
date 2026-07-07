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

    // Example/demo
    const demo = b.addExecutable(.{
        .name = "markdown-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    demo.root_module.addImport("markdown", markdown_mod);

    const demo_step = b.step("demo", "Run comprehensive markdown demo");
    const run_demo = b.addRunArtifact(demo);
    demo_step.dependOn(&run_demo.step);

    b.installArtifact(demo);
}
