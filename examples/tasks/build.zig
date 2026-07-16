const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_module = zcli_dep.module("zcli");
    const theme_module = zcli_dep.module("theme");

    // Shared store module for JSON persistence
    const store_module = b.createModule(.{
        .root_source_file = b.path("src/store.zig"),
        .target = target,
        .optimize = optimize,
    });
    store_module.addImport("theme", theme_module);

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

    const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .plugins = &.{
            zcli.builtin(.help, .{}),
            zcli.builtin(.version, .{}),
            zcli.builtin(.not_found, .{}),
            zcli.builtin(.completions, .{}),
            zcli.builtin(.config, .{}),
        },
        .shared_modules = &[_]zcli.SharedModule{
            .{ .name = "store", .module = store_module },
        },
        .app_name = "tasks",
        .app_description = "A task tracker CLI built with zcli",
    });

    exe.root_module.addImport("command_registry", cmd_registry);

    zcli.generateDocs(b, cmd_registry, zcli_dep, .{
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

    // Per-command unit tests (the scaffolded-project idiom): compiles each
    // command file as its own test root so its `test` blocks run.
    _ = zcli.addCommandTests(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .target = target,
        .optimize = optimize,
        .shared_modules = &[_]zcli.SharedModule{
            .{ .name = "store", .module = store_module },
        },
    });
}
