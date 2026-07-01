const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zg = b.dependency("zg", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("terminal", .{
        .root_source_file = b.path("src/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("Graphemes", zg.module("Graphemes"));

    const test_step = b.step("test", "Run terminal tests");
    const test_mod = b.addModule("test-terminal", .{
        .root_source_file = b.path("src/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("Graphemes", zg.module("Graphemes"));
    const tests = b.addTest(.{ .root_module = test_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
