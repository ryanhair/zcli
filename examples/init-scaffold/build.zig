const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Debug info dominates binary size (roughly 10x on a static build).
    // Release builds pass -Dstrip=true (the generated release workflow
    // does); local builds keep debug info for stack traces.
    const strip = b.option(bool, "strip", "Omit debug info from the binary") orelse false;

    // Get zcli dependency
    const zcli_dep = b.dependency("zcli", .{
        .target = target,
        .optimize = optimize,
    });
    const zcli_module = zcli_dep.module("zcli");

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    exe.root_module.addImport("zcli", zcli_module);

    const zcli = @import("zcli");

    // Shared modules: helper code (e.g. a `store.zig`) imported by more
    // than one command. Create it with `b.createModule(...)`, then add an
    // entry here — this one list is wired into your commands AND their
    // tests below, so you never register it twice. Editing this build
    // config by hand is expected; `zcli add`/`rm`/`mv` manage command
    // *structure*, not build wiring.
    const shared_modules = [_]zcli.SharedModule{
        // .{ .name = "store", .module = store_module },
    };

    // Generate command registry with built-in plugins
    const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        // Local plugins in src/plugins/ are auto-discovered (add with
        // `zcli add plugin <name>`). Harmless when the directory is absent.
        .plugins_dir = "src/plugins",
        .plugins = &.{
            //<zcli:plugins>
            zcli.builtin(.help, .{}),
            zcli.builtin(.version, .{}),
            zcli.builtin(.not_found, .{}),
            //</zcli:plugins>
        },
        .shared_modules = &shared_modules,
        .app_name = "myapp",
        .app_description = "A CLI application built with zcli",
    });

    exe.root_module.addImport("command_registry", cmd_registry);
    b.installArtifact(exe);

    // Add run step for convenience
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — unit-test each command in-process. Command test
    // blocks use `zcli-testing`'s runCommand (bundled with the zcli
    // dependency, so no extra dependency is needed). `zcli add command`
    // scaffolds a starting test alongside each new command.
    _ = zcli.addCommandTests(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .target = target,
        .optimize = optimize,
        .plugins_dir = "src/plugins",
        .shared_modules = &shared_modules,
    });
}
