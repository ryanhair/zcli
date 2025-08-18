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
        .name = "example-cli",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zcli", zcli_module);

    // Generate command registry using the plugin-aware build system
    const zcli_build = @import("zcli");

    const cmd_registry = zcli_build.buildWithExternalPlugins(b, exe, zcli_module, .{
        .commands_dir = "src/commands",
        .plugins = &[_]zcli_build.PluginConfig{
            .{
                .name = "zcli-help",
                .path = "../../plugins/zcli-help", // Path relative to this build.zig
            },
            .{
                .name = "zcli-suggestions",
                .path = "../../plugins/zcli-suggestions", // Path relative to this build.zig
            },
        },
        .app_name = "example-cli",
        .app_version = "1.0.0",
        .app_description = "A demonstration CLI built with zcli",
    });

    exe.root_module.addImport("command_registry", cmd_registry);

    b.installArtifact(exe);
}
