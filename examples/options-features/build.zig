const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli = @import("zcli");
    // Optional consumer-owned serde: use the same module for app and framework.
    const share_serde = b.option(bool, "shared-serde", "Use application-owned serde for config parsing") orelse false;
    var app_serde: ?*std.Build.Module = null;
    if (share_serde) {
        const serde_dep = b.dependency("serde", .{ .target = target, .optimize = optimize });
        const supplied = b.createModule(.{
            .root_source_file = b.path("test/serde_override.zig"),
            .target = target,
            .optimize = optimize,
        });
        supplied.addImport("upstream", serde_dep.module("serde"));
        std.debug.assert(supplied != zcli_dep.module("zcli").import_table.get("serde").?);
        zcli.setSerdeModule(zcli_dep, supplied);
        std.debug.assert(zcli_dep.module("zcli").import_table.get("serde").? == supplied);
        app_serde = supplied;
    }
    const deployment_module = b.createModule(.{
        .root_source_file = b.path("src/commands/_deployment.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_modules = &[_]zcli.SharedModule{.{ .name = "deployment", .module = deployment_module }};
    const zcli_module = zcli_dep.module("zcli");

    const exe = b.addExecutable(.{
        .name = "deployctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zcli", zcli_module);

    const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .shared_modules = shared_modules,
        .plugins = &.{
            zcli.builtin(.help, .{}),
            zcli.builtin(.version, .{}),
            zcli.builtin(.not_found, .{}),
            zcli.builtin(.completions, .{}),
            zcli.builtin(.config, .{}),
        },
        .app_name = "deployctl",
        .app_description = "Option-parsing features: required options, validate/parse hooks, exclusive/requires constraints, array options",
    });
    exe.root_module.addImport("command_registry", cmd_registry);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    // Per-command unit tests (the scaffolded-project idiom): compiles each
    // command file as its own test root so its `test` blocks run.
    const test_step = zcli.addCommandTests(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .shared_modules = shared_modules,
        .target = target,
        .optimize = optimize,
    });
    if (app_serde) |serde_module| {
        exe.root_module.addImport("serde", serde_module);
        const sharing_mod = b.createModule(.{
            .root_source_file = b.path("test/serde_sharing.zig"),
            .target = target,
            .optimize = optimize,
        });
        sharing_mod.addImport("zcli", zcli_module);
        sharing_mod.addImport("serde", serde_module);
        const sharing_tests = b.addTest(.{ .root_module = sharing_mod });
        test_step.dependOn(&b.addRunArtifact(sharing_tests).step);
    }
}
