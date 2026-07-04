//! Build-time wiring for command unit tests in a scaffolded project.
//!
//! `addCommandTests` discovers every command file under `commands_dir` and
//! compiles each as its own in-process test binary, so `zig build test` runs
//! the `test` blocks a command author writes (e.g. `zcli-testing`'s
//! `runCommand`). This is the generated-project counterpart to the meta-CLI's
//! hand-maintained `command_test_files` loop.

const std = @import("std");
const types = @import("types.zig");
const command_discovery = @import("command_discovery.zig");
const plugin_system = @import("plugin_system.zig");

const DiscoveredCommands = types.DiscoveredCommands;
const CommandInfo = types.CommandInfo;
const SharedModule = types.SharedModule;
const PluginInfo = types.PluginInfo;

/// Create a `test` step that unit-tests every discovered command file.
///
/// Each command file compiles against:
///   - `zcli`             — the framework module.
///   - `command_registry` — a *stub* whose `Context = zcli.TestContext(&.{})`,
///     so a command's `execute(_, _, *Context)` resolves and `runCommand` (which
///     builds the same TestContext) can invoke it. The real generated registry
///     is deliberately not used: a command's tests must not require the whole
///     app to compile.
///   - `zcli-testing`     — the unit-testing tier, exposed by the zcli
///     dependency, so no extra dependency is needed.
///   - any `shared_modules` the commands were generated with.
///
/// Returns the created `test` step so the caller can attach more to it.
pub fn addCommandTests(
    b: *std.Build,
    zcli_dep: *std.Build.Dependency,
    zcli_module: *std.Build.Module,
    config: types.CommandTestsConfig,
) *std.Build.Step {
    const test_step = b.step("test", "Run command unit tests");

    const shared_modules = config.shared_modules;

    // Plugins visible to the command-test stub Context, so a command that reads
    // `context.plugins.<id>` compiles and a runCommand test can drive it via
    // `.plugins`. Two sources:
    //   - the project's local plugins (src/plugins/, discovered);
    //   - an in-memory `zcli_secrets` — so a command that uses secure storage is
    //     unit-testable without touching the OS keychain (or linking a native
    //     backend). The real keychain plugin is what the app links and runs; this
    //     stands in only for `zig build test`.
    const local_plugins: []const PluginInfo =
        if (config.plugins_dir) |dir| plugin_system.scanLocalPlugins(b, dir) catch &.{} else &.{};

    var stub_plugins = std.ArrayList(*std.Build.Module).empty;
    defer stub_plugins.deinit(b.allocator);
    for (local_plugins) |plugin| {
        const pmod = b.addModule(b.fmt("cmdtest_plugin_{s}", .{plugin.name}), .{
            // scanLocalPlugins always sets project_path for the plugins it returns.
            .root_source_file = b.path(plugin.project_path.?),
            .target = config.target,
            .optimize = config.optimize,
        });
        pmod.addImport("zcli", zcli_module);
        for (shared_modules) |sm| pmod.addImport(sm.name, sm.module);
        stub_plugins.append(b.allocator, pmod) catch @panic("OOM");
    }
    stub_plugins.append(b.allocator, b.addModule("cmdtest_secrets_stub", .{
        .root_source_file = zcli_dep.path("packages/core/src/plugins/zcli_secrets/test_backend.zig"),
        .target = config.target,
        .optimize = config.optimize,
    })) catch @panic("OOM");

    // A stub `command_registry` module: commands reference
    // `@import("command_registry").Context`, and a TestContext (over the plugins
    // above) makes their execute() signatures callable from runCommand.
    var stub_aw = std.Io.Writer.Allocating.init(b.allocator);
    defer stub_aw.deinit();
    const w = &stub_aw.writer;
    w.writeAll("const zcli = @import(\"zcli\");\n") catch @panic("OOM");
    for (stub_plugins.items, 0..) |_, i| w.print("const plugin_{d} = @import(\"plugin_{d}\");\n", .{ i, i }) catch @panic("OOM");
    w.writeAll("pub const Context = zcli.TestContext(&.{") catch @panic("OOM");
    for (stub_plugins.items, 0..) |_, i| {
        if (i != 0) w.writeAll(",") catch @panic("OOM");
        w.print(" plugin_{d}", .{i}) catch @panic("OOM");
    }
    w.writeAll(" });\n") catch @panic("OOM");

    const wf = b.addWriteFiles();
    const stub_path = wf.add("command_registry.zig", b.dupe(stub_aw.written()));
    const registry_stub = b.addModule("command_registry_test_stub", .{
        .root_source_file = stub_path,
        .target = config.target,
        .optimize = config.optimize,
    });
    registry_stub.addImport("zcli", zcli_module);
    for (stub_plugins.items, 0..) |pmod, i| registry_stub.addImport(b.fmt("plugin_{d}", .{i}), pmod);

    const ctx = Ctx{
        .b = b,
        .test_step = test_step,
        .commands_dir = config.commands_dir,
        .target = config.target,
        .optimize = config.optimize,
        .zcli_module = zcli_module,
        .registry_stub = registry_stub,
        .testing_module = zcli_dep.module("zcli_testing"),
        .shared_modules = shared_modules,
    };

    // Discovery failures (e.g. no commands dir yet) simply yield an empty step.
    var commands = command_discovery.discoverCommands(b, config.commands_dir) catch return test_step;
    ctx.addMapTests(&commands.root);

    return test_step;
}

const Ctx = struct {
    b: *std.Build,
    test_step: *std.Build.Step,
    commands_dir: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zcli_module: *std.Build.Module,
    registry_stub: *std.Build.Module,
    testing_module: *std.Build.Module,
    shared_modules: []const SharedModule,

    fn addMapTests(self: Ctx, map: *std.StringHashMap(CommandInfo)) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr;
            // Pure groups are bare directories with no file; leaf commands and
            // optional-group index files are real .zig that may carry tests.
            if (info.command_type != .pure_group) self.addOne(info);
            if (info.subcommands) |*subs| self.addMapTests(subs);
        }
    }

    fn addOne(self: Ctx, info: *const CommandInfo) void {
        const b = self.b;
        const full_path = b.fmt("{s}/{s}", .{ self.commands_dir, info.file_path });

        // Module name from the sanitized command path (unique, and distinct from
        // generate()'s `cmd_*`/`*_index` registry modules).
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(b.allocator);
        for (info.path) |part| {
            parts.append(b.allocator, std.mem.replaceOwned(u8, b.allocator, part, "-", "_") catch part) catch @panic("OOM");
        }
        const module_name = b.fmt("cmdtest_{s}", .{std.mem.join(b.allocator, "_", parts.items) catch @panic("OOM")});

        const mod = b.addModule(module_name, .{
            .root_source_file = b.path(full_path),
            .target = self.target,
            .optimize = self.optimize,
        });
        mod.addImport("zcli", self.zcli_module);
        mod.addImport("command_registry", self.registry_stub);
        mod.addImport("zcli-testing", self.testing_module);
        for (self.shared_modules) |sm| mod.addImport(sm.name, sm.module);

        const t = b.addTest(.{ .root_module = mod });
        self.test_step.dependOn(&b.addRunArtifact(t).step);
    }
};
