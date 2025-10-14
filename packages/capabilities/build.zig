const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the capabilities module
    const capabilities_mod = b.addModule("capabilities", .{
        .root_source_file = b.path("src/capabilities.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    const test_mod = b.addModule("test-capabilities", .{
        .root_source_file = b.path("src/capabilities.zig"),
        .target = target,
        .optimize = optimize,
    });
    const main_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Example/demo
    const example = b.addExecutable(.{
        .name = "capabilities-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("capabilities", capabilities_mod);

    const example_step = b.step("example", "Run capabilities demo");
    const run_example = b.addRunArtifact(example);
    example_step.dependOn(&run_example.step);

    // Install demo
    b.installArtifact(example);
}