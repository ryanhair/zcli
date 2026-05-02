const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_module = zcli_dep.module("zcli");

    // Shared store module for JSON persistence
    const store_module = b.createModule(.{
        .root_source_file = b.path("src/store.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "tasks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zcli", zcli_module);
    exe.root_module.addImport("store", store_module);

    const zcli = @import("zcli");

    const cmd_registry = zcli.generate(b, exe, zcli_dep, zcli_module, .{
        .commands_dir = "src/commands",
        .plugins = &[_]zcli.PluginConfig{
            .{ .name = "zcli_help", .path = "packages/core/src/plugins/zcli_help" },
            .{ .name = "zcli_version", .path = "packages/core/src/plugins/zcli_version" },
            .{ .name = "zcli_not_found", .path = "packages/core/src/plugins/zcli_not_found" },
            .{ .name = "zcli_completions", .path = "packages/core/src/plugins/zcli_completions" },
            .{ .name = "zcli_output", .path = "packages/core/src/plugins/zcli_output" },
            .{ .name = "zcli_config", .path = "packages/core/src/plugins/zcli_config" },
        },
        .shared_modules = &[_]zcli.SharedModule{
            .{ .name = "store", .module = store_module },
        },
        .app_name = "tasks",
        .app_description = "A task tracker CLI built with zcli",
    });

    exe.root_module.addImport("command_registry", cmd_registry);

    zcli.generateDocs(b, cmd_registry, zcli_dep, zcli_module, .{
        .formats = &.{ "markdown", "html" },
        .output_dir = "docs",
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
