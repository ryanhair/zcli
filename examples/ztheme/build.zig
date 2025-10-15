const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get zcli dependency
    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    const zcli_module = zcli_dep.module("zcli");

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "ztheme-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("zcli", zcli_module);

    // Import ztheme module from parent project
    const ztheme_module = b.createModule(.{
        .root_source_file = b.path("../../packages/ztheme/src/ztheme.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("ztheme", ztheme_module);

    // Generate command registry using the plugin-aware build system
    const zcli = @import("zcli");

    const cmd_registry = zcli.generate(b, exe, zcli_module, .{
        .commands_dir = "src/commands",
        .plugins = &[_]zcli.PluginConfig{ .{
            .name = "zcli_help",
            .path = "../../packages/core/plugins/zcli_help",
        }, .{
            .name = "zcli_version",
            .path = "../../packages/core/plugins/zcli_version",
        }, .{
            .name = "zcli_not_found",
            .path = "../../packages/core/plugins/zcli_not_found",
        } },
        .app_name = "ztheme-demo",
        .app_description = "ZTheme Demo - Terminal styling showcase powered by zcli",
    });

    // Make ztheme available to command modules
    const registry_module = cmd_registry;

    // Get the root command module and add ztheme import to it
    const cmd_root = b.modules.get("cmd_root");
    if (cmd_root) |root_module| {
        root_module.addImport("ztheme", ztheme_module);
    }

    exe.root_module.addImport("command_registry", registry_module);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the ZTheme demo application");
    run_step.dependOn(&run_cmd.step);

    // Test step
    const test_cmd = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/commands/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_cmd.root_module.addImport("zcli", zcli_module);
    test_cmd.root_module.addImport("ztheme", ztheme_module);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(test_cmd).step);
}
