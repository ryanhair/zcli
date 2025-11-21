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
        .name = "swapi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("zcli", zcli_module);

    // Generate command registry using the plugin-aware build system
    const zcli = @import("zcli");

    const cmd_registry = zcli.generate(b, exe, zcli_dep, zcli_module, .{
        .commands_dir = "src/commands",
        .plugins = &[_]zcli.PluginConfig{ .{
            .name = "zcli_help",
            .path = "packages/core/src/plugins/zcli_help",
        }, .{
            .name = "zcli_version",
            .path = "packages/core/src/plugins/zcli_version",
        }, .{
            .name = "zcli_not_found",
            .path = "packages/core/src/plugins/zcli_not_found",
        }, .{
            .name = "zcli_completions",
            .path = "packages/core/src/plugins/zcli_completions",
        } },
        .app_name = "swapi",
        .app_version = "0.1.0",
        .app_description = "A Star Wars API CLI tool built with zcli",
    });

    exe.root_module.addImport("command_registry", cmd_registry);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
