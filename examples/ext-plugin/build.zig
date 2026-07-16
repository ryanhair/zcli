const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_module = zcli_dep.module("zcli");

    // The external plugin, resolved as an ordinary Zig-package dependency. Its
    // package exposes a module named `plugin`; `generate()` picks it up from
    // this dependency (see the `.dependency = greet_plugin_dep` plugin entry
    // below) and injects the `zcli` import into it.
    const greet_plugin_dep = b.dependency("greet_plugin", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "ext-plugin",
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
            // A third-party plugin shipped as its own Zig package: pass the
            // dependency, not a path. This is the first-class external-plugin
            // extension point (contrast `.plugins_dir` for project-local
            // plugins, and `zcli.builtin(...)` for the shipped ones).
            .{ .name = "greet", .dependency = greet_plugin_dep },
        },
        .app_name = "ext-plugin",
        .app_description = "Registering a plugin shipped as an external Zig package",
    });
    exe.root_module.addImport("command_registry", cmd_registry);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    _ = zcli.addCommandTests(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .target = target,
        .optimize = optimize,
    });
}
