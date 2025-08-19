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

    // Tests for the plugin
    const plugin_tests = b.addTest(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests for the levenshtein module
    const levenshtein_tests = b.addTest(.{
        .root_source_file = b.path("src/levenshtein.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_plugin_tests = b.addRunArtifact(plugin_tests);
    const run_levenshtein_tests = b.addRunArtifact(levenshtein_tests);
    
    const test_step = b.step("test", "Run plugin tests");
    test_step.dependOn(&run_plugin_tests.step);
    test_step.dependOn(&run_levenshtein_tests.step);

    // Export the plugin module (it will be available as a dependency)
    _ = plugin_module;
}