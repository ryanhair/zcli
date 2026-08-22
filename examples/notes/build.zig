const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_module = zcli_dep.module("zcli");

    const exe = b.addExecutable(.{
        .name = "notes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zcli", zcli_module);

    const zcli = @import("zcli");

    // The persistence helper, shared by every command (see `zcli guide sharing`
    // and `zcli guide storage`). Registered once here and wired into both the
    // generated commands and their tests.
    const store_module = b.createModule(.{
        .root_source_file = b.path("src/store.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The append-only activity log: the same "commands persist state
    // themselves" idea, but for a file several processes append to at once
    // (locking + one flushed record per append). See `zcli guide storage`.
    const log_module = b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_modules = [_]zcli.SharedModule{
        .{ .name = "store", .module = store_module },
        .{ .name = "log", .module = log_module },
    };

    const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .plugins = &.{
            zcli.builtin(.help, .{}),
            zcli.builtin(.version, .{}),
            zcli.builtin(.not_found, .{}),
        },
        // Local plugins in src/plugins/ are auto-discovered (src/plugins/verbose.zig
        // adds a global --verbose flag). See `zcli guide plugins`.
        .plugins_dir = "src/plugins",
        .shared_modules = &shared_modules,
        .app_name = "notes",
        .app_description = "A tiny note keeper (a JSON-file persistence example)",
    });
    exe.root_module.addImport("command_registry", cmd_registry);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = zcli.addCommandTests(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .target = target,
        .optimize = optimize,
        .shared_modules = &shared_modules,
    });

    // addCommandTests compiles the command files, so a shared module's own
    // `test` blocks need their own artifact — hang it on the step it returns
    // and `zig build test` runs both. log.zig's concurrency and torn-record
    // tests are the whole point of that module, so they must run in CI.
    const log_tests = b.addTest(.{ .root_module = log_module });
    test_step.dependOn(&b.addRunArtifact(log_tests).step);
}
