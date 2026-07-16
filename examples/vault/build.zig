const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_module = zcli_dep.module("zcli");

    // The name-index kept alongside the OS-keychain-backed secrets (see
    // src/store.zig): the secrets plugin can set/get/delete an opaque value by
    // name, but has no "list all names" operation, so the index is what makes
    // `vault list` and the `<name>` completion possible.
    const store_module = b.createModule(.{
        .root_source_file = b.path("src/store.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "vault",
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
            // Static shell completion (bash/zsh/fish) for command/flag names,
            // plus the substrate the per-arg `.complete` hooks in
            // src/commands/get.zig and remove.zig plug into (ADR-0026).
            zcli.builtin(.completions, .{}),
            // Transparent config-file defaults — see .vault.config.json.
            zcli.builtin(.config, .{}),
            // Opt in to OS-keychain-backed credential storage (ADR-0003):
            // makes `context.plugins.zcli_secrets` available.
            zcli.builtin(.secrets, .{}),
        },
        .shared_modules = &[_]zcli.SharedModule{
            .{ .name = "store", .module = store_module },
        },
        .app_name = "vault",
        .app_description = "A secrets-backed CLI combining config, completions, and prompts",
    });
    exe.root_module.addImport("command_registry", cmd_registry);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
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
