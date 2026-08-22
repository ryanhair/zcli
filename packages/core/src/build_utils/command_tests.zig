//! Build-time wiring for command unit tests in a scaffolded project.
//!
//! `addCommandTests` discovers every command file under `commands_dir` and
//! compiles each as its own in-process test binary, so `zig build test` runs
//! the `test` blocks a command author writes (e.g. `zcli-testing`'s
//! `runCommand`). Every configured shared module is a test root too, so the
//! logic commands delegate to is covered by the same step. This is the
//! generated-project counterpart to the meta-CLI's hand-maintained
//! `command_test_files` loop.

const std = @import("std");
const types = @import("types.zig");
const command_discovery = @import("command_discovery.zig");
const plugin_system = @import("plugin_system.zig");

const DiscoveredCommands = types.DiscoveredCommands;
const DiscoveredCommand = types.DiscoveredCommand;
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
///   - `zcli-testing`     — the in-process unit-testing tier (`zcli_testing_unit`),
///     exposed by the zcli dependency, so no extra dependency is needed. (Command
///     tests are in-process; the subprocess/PTY tiers live in separate modules.)
///   - any `shared_modules` the commands were generated with.
///
/// Each distinct `shared_modules` module is *also* compiled as a test root, so
/// the helper logic commands delegate to is covered by the same `zig build
/// test` without a second hand-written test target per module. The project's
/// module is never modified: a mirror of it roots the test compile, carrying
/// its imports and build configuration, with only the target/optimize a test
/// root cannot inherit completed from `config` (see `testRootFor`). Two names
/// pointing at one module yield one test root, not two.
///
/// `exe` is the project's real executable (the one built by `generate()`). The
/// `test` step depends on it so that `zig build test` — which CI runs on all
/// three OSes — also proves the real registry/main.zig link on every OS. The
/// per-command stub tests alone don't compile the app; without this, a
/// Windows- or macOS-only link break could stay green until someone happens
/// to run `zig build build-examples`/`b.installArtifact` there.
///
/// Returns the created `test` step so the caller can attach more to it.
pub fn addCommandTests(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    zcli_dep: *std.Build.Dependency,
    config: types.CommandTestsConfig,
) *std.Build.Step {
    const zcli_module = zcli_dep.module("zcli");
    const test_step = b.step("test", "Run command unit tests");
    test_step.dependOn(&exe.step);

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
        if (config.plugins_dir) |dir| (plugin_system.scanLocalPlugins(b, dir) catch &.{}) orelse &.{} else &.{};

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
        .testing_module = zcli_dep.module("zcli_testing_unit"),
        .shared_modules = shared_modules,
    };

    // Shared modules are test roots in their own right. A command is usually a
    // thin shell over a shared helper, so testing only the command files leaves
    // the interesting logic uncovered unless the project hand-writes a second
    // `addTest` per module. Each is compiled through a mirror of the project's
    // module (see `testRootFor`), which keeps every import and build setting it
    // was configured with — what the commands compile against.
    //
    // Wired before command discovery so a project that has shared modules but
    // no commands directory yet still runs them.
    for (shared_modules, 0..) |sm, i| {
        // One module may be registered under several names (an alias for the
        // same helper). Every alias must stay in the command imports above, but
        // its tests are one test root, not one per name — so the identity this
        // keys on is the module the project owns, never the mirror below.
        if (!isFirstAliasOf(shared_modules, i)) continue;

        const shared_tests = b.addTest(.{ .root_module = testRootFor(b, sm.module, config) });
        test_step.dependOn(&b.addRunArtifact(shared_tests).step);
    }

    // Discovery failures (e.g. no commands dir yet) simply yield an empty step.
    var commands = command_discovery.discoverCommands(b, config.commands_dir) catch return test_step;
    // The root group's index (a top-level index.zig) is a real command file
    // that may carry tests, same as any nested group index.
    if (commands.root_index) |*ri| ctx.addOne(ri);
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

    fn addMapTests(self: Ctx, map: *std.StringHashMap(DiscoveredCommand)) void {
        var it = map.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr;
            // Pure groups are bare directories with no file; leaf commands and
            // optional-group index files are real .zig that may carry tests.
            if (info.command_type != .pure_group) self.addOne(info);
            if (info.subcommands) |*subs| self.addMapTests(subs);
        }
    }

    fn addOne(self: Ctx, info: *const DiscoveredCommand) void {
        const b = self.b;
        const full_path = b.fmt("{s}/{s}", .{ self.commands_dir, info.file_path });

        // Module name from the sanitized command path (unique, and distinct from
        // generate()'s `cmd_*`/`*_index` registry modules).
        const module_name = cmdTestModuleName(b.allocator, info.path) catch @panic("OOM");

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

/// A module that can serve as the *root* of a test compile for `shared`,
/// without touching `shared` itself.
///
/// The project's own module must be left exactly as it configured it. A null
/// `target`/`optimize` is not an oversight there: `std.Build.Module` treats it
/// as "inherit from whichever compilation imports me" (see `Module.CreateOptions`),
/// and the same pointer is read again — later, at make time — by every other
/// compile that imports it, starting with the executable this project already
/// configured. Filling those fields in place would pin all of them to the test
/// configuration, silently rebuilding a module that is deliberately shared
/// across targets or optimize modes.
///
/// So mirror it instead (`Module.init`'s `.existing` case is std's own copy of
/// a module's whole configuration — imports, link objects, include paths, every
/// per-module setting) and complete only what a test root cannot inherit,
/// because a test root has no importer to inherit from: `addTest` panics
/// without a resolved target, and an absent optimize would quietly mean Debug
/// rather than the mode the project passed here. Anything set explicitly is
/// carried over untouched.
///
/// The mirror is a snapshot taken at this call: it copies the import table
/// rather than sharing it, so neither module's later `addImport` can disturb
/// the other's, and it starts with no cached module graph of its own.
fn testRootFor(b: *std.Build, shared: *std.Build.Module, config: types.CommandTestsConfig) *std.Build.Module {
    const root = b.allocator.create(std.Build.Module) catch @panic("OOM");
    root.init(b, .{ .existing = shared });

    // `.existing` is a shallow copy; give the mirror its own import table and
    // an empty graph cache so it can never write through to the original's.
    root.import_table = .empty;
    for (shared.import_table.keys(), shared.import_table.values()) |name, module| {
        root.addImport(name, module);
    }
    root.cached_graph = .{ .modules = &.{}, .names = &.{} };

    if (root.resolved_target == null) root.resolved_target = config.target;
    if (root.optimize == null) root.optimize = config.optimize;
    return root;
}

/// True when `entries[i]` is the first entry naming its module — the rule that
/// turns an aliased shared module (one module registered under two names, both
/// of which must stay importable from commands) into ONE test root instead of
/// two builds of the same file racing each other. Generic over the entry type
/// so the rule can be unit-tested directly, without a `std.Build` graph.
fn isFirstAliasOf(entries: anytype, i: usize) bool {
    for (entries[0..i]) |earlier| {
        if (earlier.module == entries[i].module) return false;
    }
    return true;
}

/// Derive the unique test-module identifier for a command from its path:
/// `cmdtest_<parts joined by '_'>`, with '-' in each part replaced by '_' so a
/// dash-named command file yields a valid Zig identifier. Extracted from the
/// std.Build-graph wiring in `addOne` so the derivation rule can be unit-tested
/// directly (a regression fails here, not an opaque example build). Caller owns
/// the returned string.
fn cmdTestModuleName(allocator: std.mem.Allocator, path: []const []const u8) ![]u8 {
    // The root group's index has the empty path; give it a stable name in the
    // same reserved (underscore-prefixed, hence non-producible) namespace as
    // its registry module.
    if (path.len == 0) return allocator.dupe(u8, "cmdtest__root_index");
    var parts = std.ArrayList([]const u8).empty;
    defer {
        for (parts.items) |p| allocator.free(p);
        parts.deinit(allocator);
    }
    for (path) |part| {
        try parts.append(allocator, try std.mem.replaceOwned(u8, allocator, part, "-", "_"));
    }
    const joined = try std.mem.join(allocator, "_", parts.items);
    defer allocator.free(joined);
    return std.fmt.allocPrint(allocator, "cmdtest_{s}", .{joined});
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isFirstAliasOf: each distinct module is wired once, under its first name" {
    // Stand-ins for two *std.Build.Module values; only their identity matters.
    const first: u8 = 1;
    const second: u8 = 2;
    const Entry = struct { module: *const u8 };
    const entries = [_]Entry{
        .{ .module = &first },
        .{ .module = &second },
        .{ .module = &first }, // the same module under a second name
    };
    try testing.expect(isFirstAliasOf(&entries, 0));
    try testing.expect(isFirstAliasOf(&entries, 1));
    try testing.expect(!isFirstAliasOf(&entries, 2));
}

test "cmdTestModuleName names the root index from the reserved namespace" {
    const name = try cmdTestModuleName(testing.allocator, &.{});
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("cmdtest__root_index", name);
}

test "cmdTestModuleName joins path parts under a cmdtest_ prefix" {
    const name = try cmdTestModuleName(testing.allocator, &.{ "users", "list" });
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("cmdtest_users_list", name);
}

test "cmdTestModuleName replaces dashes so the identifier stays valid" {
    const name = try cmdTestModuleName(testing.allocator, &.{ "gh", "add-item" });
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("cmdtest_gh_add_item", name);
}

test "cmdTestModuleName for a single top-level command" {
    const name = try cmdTestModuleName(testing.allocator, &.{"init"});
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("cmdtest_init", name);
}
