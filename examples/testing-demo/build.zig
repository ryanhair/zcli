const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_module = zcli_dep.module("zcli");

    const exe = b.addExecutable(.{
        .name = "greeter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zcli", zcli_module);

    const zcli = @import("zcli");

    const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .plugins = &.{
            zcli.builtin(.help, .{}),
            zcli.builtin(.version, .{}),
            zcli.builtin(.not_found, .{}),
        },
        .app_name = "greeter",
        .app_description = "A minimal CLI whose tests exercise the zcli-testing harness directly",
    });
    exe.root_module.addImport("command_registry", cmd_registry);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    // Per-command unit tests (the scaffolded-project idiom): compiles each
    // command file as its own test root, with `zcli-testing` (the unit tier,
    // `runCommand`) wired in — see `src/commands/greet.zig`'s own `test`
    // blocks. Returns the `test` step so more tiers can attach to it below.
    const test_step = zcli.addCommandTests(b, zcli_dep, .{
        .commands_dir = "src/commands",
        .target = target,
        .optimize = optimize,
    });

    // Integration/snapshot tier (`zcli_testing`'s `runSubprocess` +
    // `expectSnapshot`), against the actual compiled binary — see
    // `src/integration_test.zig`. Its Run step depends on the install step so
    // `./zig-out/bin/greeter` exists before any test in it runs.
    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_test_mod.addImport("zcli-testing", zcli_dep.module("zcli_testing"));

    const integration_tests = b.addTest(.{ .root_module = integration_test_mod });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_integration_tests.step);
}
