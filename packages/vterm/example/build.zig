const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // vterm as a proper dependency (see build.zig.zon), so its own module
    // wiring (the zg DisplayWidth data) comes along instead of being
    // hand-rolled here and drifting.
    const vterm_dep = b.dependency("vterm", .{ .target = target, .optimize = optimize });
    const vterm_mod = vterm_dep.module("vterm");

    // Build the example CLI application
    const exe = b.addExecutable(.{
        .name = "demo-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("vterm", vterm_mod);
    b.installArtifact(exe);

    // Create run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the demo CLI");
    run_step.dependOn(&run_cmd.step);

    // Create test executable
    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_exe.root_module.addImport("vterm", vterm_mod);

    const test_cmd = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_cmd.step);
}
