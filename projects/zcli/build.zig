const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Debug info dominates binary size (~13 MB unstripped vs ~2 MB stripped
    // for a static musl ReleaseSafe build). Release artifacts pass
    // -Dstrip=true; local builds keep debug info for stack traces.
    const strip = b.option(bool, "strip", "Omit debug info from the binary (release artifacts)") orelse false;

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

    // Shared scaffolding library (arg/option spec model + in-file AST splice),
    // used by the `add command`/`add option`/`add arg` command modules. Exposed
    // to command modules via shared_modules below.
    const scaffold_module = b.addModule("scaffold", .{
        .root_source_file = b.path("src/scaffold.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Canonical example sources embedded into `zcli guide` (ADR-0004/0008). Each
    // anonymous import binds a `@embedFile` name in guide_examples.zig to a real
    // CI-compiled example file — the guide shows compiled truth, and the build
    // grants the cross-package embed a bare relative path can't reach.
    const guide_examples_module = b.addModule("guide_examples", .{
        .root_source_file = b.path("src/guide_examples.zig"),
        .target = target,
        .optimize = optimize,
    });
    guide_examples_module.addAnonymousImport("repostat/repo.zig", .{
        .root_source_file = b.path("../../examples/repostat/src/commands/repo.zig"),
    });
    guide_examples_module.addAnonymousImport("ghauth/login.zig", .{
        .root_source_file = b.path("../../examples/ghauth/src/commands/login.zig"),
    });
    guide_examples_module.addAnonymousImport("ghauth/whoami.zig", .{
        .root_source_file = b.path("../../examples/ghauth/src/commands/whoami.zig"),
    });
    guide_examples_module.addAnonymousImport("notes/store.zig", .{
        .root_source_file = b.path("../../examples/notes/src/store.zig"),
    });
    guide_examples_module.addAnonymousImport("notes/verbose.zig", .{
        .root_source_file = b.path("../../examples/notes/src/plugins/verbose.zig"),
    });

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "zcli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    exe.root_module.addImport("zcli", zcli_module);

    // Generate command registry using the plugin-aware build system
    const zcli = @import("zcli");

    const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .plugins = &.{
            zcli.builtin(.help, .{}),
            zcli.builtin(.version, .{}),
            zcli.builtin(.not_found, .{}),
            zcli.builtin(.github_upgrade, .{
                .repo = "ryanhair/zcli",
                .command_name = "upgrade",
                .inform_out_of_date = false,
                // Release-signature enforcement: `zcli upgrade` verifies
                // checksums.txt.minisig under this pinned key (fail closed)
                // before installing. Key id 1638B69B8EF680FD; full key at
                // docs/zcli-minisign.pub. Rotation: docs/RELEASE-SIGNING.md.
                .verification = .{ .minisign = "RWT9gPaOm7Y4Fm5WFqqlWRpI4FgPTIjD5UhUsaZsdKHrWYuWa9jt8ESC" },
            }),
            zcli.builtin(.completions, .{}),
        },
        .app_name = "zcli",
        .app_description = "Build beautiful CLIs with zcli - scaffold projects, add commands, and more",
        .shared_modules = &[_]zcli.SharedModule{
            .{ .name = "nightwatch", .module = nightwatch_module },
            .{ .name = "scaffold", .module = scaffold_module },
            .{ .name = "guide_examples", .module = guide_examples_module },
        },
    });

    exe.root_module.addImport("command_registry", cmd_registry);

    zcli.generateDocs(b, cmd_registry, zcli_dep, .{
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
        "src/commands/add/_wizard.zig",
        "src/commands/add/_generate.zig",
        "src/commands/add/option.zig",
        "src/commands/add/arg.zig",
        "src/commands/add/group.zig",
        "src/commands/add/plugin.zig",
        "src/commands/rm/option.zig",
        "src/commands/rm/arg.zig",
        "src/commands/rm/command.zig",
        "src/commands/rm/index.zig",
        "src/commands/init.zig",
        "src/commands/release.zig",
        "src/commands/mv.zig",
        "src/commands/guide.zig",
        "src/commands/add/index.zig",
        "src/commands/gh/index.zig",
        "src/commands/gh/add/workflow/release.zig",
    };
    for (command_test_files) |path| {
        const mod = b.addModule(b.fmt("test-{s}", .{path}), .{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("zcli", zcli_module);
        mod.addImport("nightwatch", nightwatch_module);
        mod.addImport("scaffold", scaffold_module);
        mod.addImport("command_registry", command_registry_stub);
        mod.addImport("guide_examples", guide_examples_module);
        const cmd_tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(cmd_tests).step);
    }

    // The scaffold library's own unit tests (spec rendering + AST splice).
    const scaffold_tests = b.addTest(.{ .root_module = scaffold_module });
    test_step.dependOn(&b.addRunArtifact(scaffold_tests).step);

    // End-to-end tests: run the built binary against temp projects. Kept out of
    // the `test` step because the build-and-run tier compiles zcli from source
    // and is slow. See test/e2e.zig.
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

    const e2e_filter = b.option([]const u8, "e2e-filter", "Only run e2e tests whose name contains this substring");
    const e2e_tests = b.addTest(.{
        .root_module = e2e_mod,
        .filters = if (e2e_filter) |f| &.{f} else &.{},
    });
    const run_e2e = b.addRunArtifact(e2e_tests);
    run_e2e.has_side_effects = true; // touches fs/git; always re-run
    run_e2e.step.dependOn(b.getInstallStep()); // binary must exist before tests run

    const e2e_step = b.step("e2e", "Run end-to-end tests (builds scaffolded projects; slow)");
    e2e_step.dependOn(&run_e2e.step);
}
