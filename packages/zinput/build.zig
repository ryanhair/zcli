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
}
