const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_module = zcli_dep.module("zcli");

    const exe = b.addExecutable(.{
        .name = "upgrade-demo",
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
            // Self-upgrade (ADR-0023): adds an `upgrade` command that checks
            // GitHub Releases for `{repo}`'s latest `upgrade-demo-v*` tag,
            // downloads the matching release asset, verifies it, and replaces
            // the running binary.
            //
            // `repo` is a placeholder — point it at your own GitHub repo
            // publishing releases named `{cli_name}-v{version}` (see
            // `projects/zcli/build.zig` for the real thing zcli upgrades
            // itself with, including a pinned minisign key).
            zcli.builtin(.github_upgrade, .{
                .repo = "your-org/your-cli",
                .command_name = "upgrade",
                // A real release pipeline should sign checksums.txt with
                // minisign and pin the public key here instead:
                //   .verification = .{ .minisign = "<base64 public key>" },
                // (docs/RELEASE-SIGNING.md documents key generation and
                // rotation.) This example has no real release to sign, so it
                // opts explicitly into checksum-only trust — the plugin prints
                // a one-line warning on every upgrade run when this variant is
                // selected, precisely so it's never silently insecure.
                .verification = .checksum_only,
            }),
        },
        .app_name = "upgrade-demo",
        .app_description = "A minimal CLI wiring the github_upgrade plugin's self-upgrade flow",
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
    });
}
