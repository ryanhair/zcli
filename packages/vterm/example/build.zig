const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import vterm module
    const vterm_mod = b.createModule(.{
        .root_source_file = b.path("../src/vterm.zig"),
    });

    // Build the example CLI application
    const exe = b.addExecutable(.{
        .name = "demo-cli",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
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
        .root_source_file = b.path("tests/cli_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_exe.root_module.addImport("vterm", vterm_mod);

    const test_cmd = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_cmd.step);
}
