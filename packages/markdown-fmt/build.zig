const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the markdown-fmt module
    _ = b.addModule("markdown-fmt", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Example/demo
    const demo = b.addExecutable(.{
        .name = "markdown-fmt-demo",
        .root_source_file = b.path("examples/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    const markdown_fmt_mod = b.addModule("markdown-fmt", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo.root_module.addImport("markdown-fmt", markdown_fmt_mod);

    const demo_step = b.step("demo", "Run comprehensive markdown-fmt demo");
    const run_demo = b.addRunArtifact(demo);
    demo_step.dependOn(&run_demo.step);

    b.installArtifact(demo);
}
