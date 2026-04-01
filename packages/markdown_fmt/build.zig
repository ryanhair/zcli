const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get ztheme dependency
    const ztheme_dep = b.dependency("ztheme", .{
        .target = target,
        .optimize = optimize,
    });
    const ztheme_module = ztheme_dep.module("ztheme");

    // Create the markdown_fmt module
    const markdown_fmt_mod = b.addModule("markdown_fmt", .{
        .root_source_file = b.path("src/main.zig"),
    });
    markdown_fmt_mod.addImport("ztheme", ztheme_module);

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("ztheme", ztheme_module);
    const main_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Example/demo
    const demo = b.addExecutable(.{
        .name = "markdown-fmt-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    demo.root_module.addImport("markdown_fmt", markdown_fmt_mod);

    const demo_step = b.step("demo", "Run comprehensive markdown-fmt demo");
    const run_demo = b.addRunArtifact(demo);
    demo_step.dependOn(&run_demo.step);

    b.installArtifact(demo);
}
