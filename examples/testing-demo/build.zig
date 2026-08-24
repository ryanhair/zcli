const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcli_dep = b.dependency("zcli", .{ .target = target, .optimize = optimize });
    const zcli_module = zcli_dep.module("zcli");

    const exe = b.addExecutable(.{
        .name = "greeter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zcli", zcli_module);

    const zcli = @import("zcli");

    // The greeting text, shared by every command (see src/greeting.zig). Listed
    // once here and handed to both call sites below; `addCommandTests` compiles
    // it as a test root, so its own `test` blocks run under `zig build test`.
    //
    // Deliberately created without `.target`/`.optimize`: a module that is only
    // ever imported inherits both from the compilation that pulls it in, and
    // that stays true here — `addCommandTests` roots its test compile on a
    // mirror of this module and completes the pair there, so both the shorter
    // spelling and the inheritance keep working. The assertion after that call
    // is what holds it to that.
    const greeting_module = b.createModule(.{
        .root_source_file = b.path("src/greeting.zig"),
    });
    const shared_modules = [_]zcli.SharedModule{
        .{ .name = "greeting", .module = greeting_module },
    };

    // A piece of list-backed configuration, so the checks after
    // `addCommandTests` below have something to watch. Nothing in this example
    // needs it — it stands in for the include paths, link objects, or C macros
    // a real shared module carries.
    greeting_module.addCMacro("GREETING_EXAMPLE", "1");
    const macros_before_wiring = greeting_module.c_macros.items;

    const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .shared_modules = &shared_modules,
        .plugins = &.{
            zcli.builtin(.help, .{}),
            zcli.builtin(.version, .{}),
            zcli.builtin(.not_found, .{}),
        },
        .app_name = "greeter",
        .app_description = "A minimal CLI whose tests exercise the zcli-testing harness directly",
    });
    exe.root_module.addImport("command_registry", cmd_registry);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    // Per-command unit tests (the scaffolded-project idiom): compiles each
    // command file as its own test root, with `zcli-testing` (the unit tier,
    // `runCommand`) wired in — see `src/commands/greet.zig`'s own `test`
    // blocks. Every shared module is a test root too, so `src/greeting.zig`'s
    // tests run from this same list with no extra wiring. Returns the `test`
    // step so more tiers can attach to it below.
    const test_step = zcli.addCommandTests(b, exe, zcli_dep, .{
        .commands_dir = "src/commands",
        .target = target,
        .optimize = optimize,
        .shared_modules = &shared_modules,
    });

    // Wiring the tests must not reconfigure the project's own module. This one
    // is imported by the executable above and has no target/optimize of its
    // own, precisely so it inherits from whatever compilation pulls it in; if
    // `addCommandTests` ever pinned it to the test configuration instead of
    // mirroring it, every other consumer would silently follow the tests.
    if (greeting_module.resolved_target != null or greeting_module.optimize != null) {
        @panic("addCommandTests must not reconfigure the shared module it was handed");
    }

    // Same for its list-backed configuration: same list, same address, so the
    // call neither appended to it nor moved it. (That the *mirror's* copy is
    // storage of its own — the other half of the isolation — is unit-tested in
    // the framework, at command_tests.zig's `cloneList`/`cloneMap`; nothing
    // out here holds a handle on the mirror to check it from.)
    if (greeting_module.c_macros.items.ptr != macros_before_wiring.ptr or
        greeting_module.c_macros.items.len != macros_before_wiring.len)
    {
        @panic("addCommandTests must not disturb the shared module's own configuration");
    }

    // And this module stays independently configurable afterwards. What the
    // mirror captured is a snapshot taken at the call above, so configuration
    // added here reaches the commands but not the shared module's own tests —
    // add it before `addCommandTests` if the tests need it too.
    greeting_module.addCMacro("GREETING_EXAMPLE_AFTER_WIRING", "1");
    if (greeting_module.c_macros.items.len != macros_before_wiring.len + 1) {
        @panic("the shared module must remain the project's to configure");
    }

    // Integration/snapshot tier (`zcli_testing`'s `runSubprocess` +
    // `expectSnapshot`), against the actual compiled binary — see
    // `src/integration_test.zig`. Its Run step depends on the install step so
    // `./zig-out/bin/greeter` exists before any test in it runs.
    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_test_mod.addImport("zcli-testing", zcli_dep.module("zcli_testing"));

    const integration_tests = b.addTest(.{ .root_module = integration_test_mod });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_integration_tests.step);
}
