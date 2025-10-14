const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the plugin module
    const plugin_module = b.addModule("plugin", .{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zcli as a dependency when building standalone
    const zcli_module = b.createModule(.{
        .root_source_file = b.path("../../src/zcli.zig"),
        .target = target,
        .optimize = optimize,
    });
    plugin_module.addImport("zcli", zcli_module);

    // Tests for the plugin
    const test_mod = b.addModule("plugin-test", .{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zcli", zcli_module);

    const plugin_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(plugin_tests);
    const test_step = b.step("test", "Run plugin tests");
    test_step.dependOn(&run_tests.step);
}
