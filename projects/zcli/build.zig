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
        .name = "zcli",
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
        .plugins = &.{ .{
            .name = "zcli_help",
            .path = "plugins/zcli_help",
        }, .{
            .name = "zcli_version",
            .path = "plugins/zcli_version",
        }, .{
            .name = "zcli_not_found",
            .path = "plugins/zcli_not_found",
        }, .{
            .name = "zcli_github_upgrade",
            .path = "plugins/zcli_github_upgrade",
            .config = .{
                .repo = "ryanhair/zcli",
                .command_name = "upgrade",
                .inform_out_of_date = false,
            },
        }, .{
            .name = "zcli_completions",
            .path = "plugins/zcli_completions",
        } },
        .app_name = "zcli",
        .app_description = "Build beautiful CLIs with zcli - scaffold projects, add commands, and more",
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

    // Set up tests
    const test_mod = b.addModule("zcli-test", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zcli", zcli_module);
    test_mod.addImport("command_registry", cmd_registry);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
