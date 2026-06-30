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

    // Native filesystem watcher, used by the `dev` command. Exposed to command
    // modules via shared_modules below (only `dev` references it).
    const nightwatch_dep = b.dependency("nightwatch", .{
        .target = target,
        .optimize = optimize,
    });
    const nightwatch_module = nightwatch_dep.module("nightwatch");

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
        .plugins = &.{
            zcli.builtin(.help, .{}),
            zcli.builtin(.version, .{}),
            zcli.builtin(.not_found, .{}),
            zcli.builtin(.github_upgrade, .{
                .repo = "ryanhair/zcli",
                .command_name = "upgrade",
                .inform_out_of_date = false,
            }),
            zcli.builtin(.completions, .{}),
        },
        .app_name = "zcli",
        .app_description = "Build beautiful CLIs with zcli - scaffold projects, add commands, and more",
        .shared_modules = &[_]zcli.SharedModule{
            .{ .name = "nightwatch", .module = nightwatch_module },
        },
    });

    exe.root_module.addImport("command_registry", cmd_registry);

    zcli.generateDocs(b, cmd_registry, zcli_dep, zcli_module, .{
        .formats = &.{ "markdown", "man", "html" },
    });

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

    // Command modules with their own unit tests.
    const command_registry_stub = b.addModule("command_registry_stub", .{
        .root_source_file = b.path("test/stubs/command_registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    const command_test_files = [_][]const u8{
        "src/commands/tree.zig",
        "src/commands/dev.zig",
        "src/commands/add/command.zig",
    };
    for (command_test_files) |path| {
        const mod = b.addModule(b.fmt("test-{s}", .{path}), .{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("zcli", zcli_module);
        mod.addImport("nightwatch", nightwatch_module);
        mod.addImport("command_registry", command_registry_stub);
        const cmd_tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(cmd_tests).step);
    }

    // End-to-end tests: run the built binary against temp projects. Kept out of
    // the `test` step because the build-and-run tier compiles zcli from source
    // and is slow. See test/e2e.zig and .context/e2e-test-plan.md.
    const e2e_options = b.addOptions();
    e2e_options.addOption([]const u8, "zcli_exe", b.getInstallPath(.bin, "zcli"));
    e2e_options.addOption([]const u8, "repo_root", b.path("../..").getPath(b));
    e2e_options.addOption([]const u8, "fixtures_dir", b.path("test/fixtures").getPath(b));

    const e2e_mod = b.addModule("zcli-e2e", .{
        .root_source_file = b.path("test/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addOptions("build_options", e2e_options);
    // PTY harness for interactive (TTY) regression tests.
    e2e_mod.addImport("testing_e2e", zcli_dep.module("testing_e2e"));

    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e = b.addRunArtifact(e2e_tests);
    run_e2e.has_side_effects = true; // touches fs/git; always re-run
    run_e2e.step.dependOn(b.getInstallStep()); // binary must exist before tests run

    const e2e_step = b.step("e2e", "Run end-to-end tests (builds scaffolded projects; slow)");
    e2e_step.dependOn(&run_e2e.step);
}
