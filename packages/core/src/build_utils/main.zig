const std = @import("std");
const logging = @import("../logging.zig");
const types = @import("types.zig");
const module_creation = @import("module_creation.zig");
const plugin_system = @import("plugin_system.zig");
const command_discovery = @import("command_discovery.zig");
const code_generation = @import("code_generation.zig");

const DiscoveredCommand = types.DiscoveredCommand;
const BuildConfig = types.BuildConfig;
const DiscoveredCommands = types.DiscoveredCommands;
const GenerateConfig = types.GenerateConfig;
const DocsConfig = types.DocsConfig;

/// `generate()` failed because of a problem in the consuming project's
/// configuration. A human-readable explanation has already been printed;
/// propagate this out of `build()` to stop the build.
pub const GenerateError = error{CommandDiscoveryFailed};

/// Link the native libraries the `zcli_secrets` plugin's backend needs for
/// `target`. macOS: Security + CoreFoundation frameworks. Windows: advapi32.
/// Linux links **nothing**: its backend reaches the Secret Service (via
/// `secret-tool`) or `pass` by shelling out at runtime, not by linking, so a
/// Linux build stays static and works on musl too (ADR-0010). Any other OS has
/// no secure backend — registering the plugin there is a compile error in the
/// plugin source. Exposed so the plugin's own test targets can link exactly the
/// same way a registered app does.
pub fn linkSecretsBackend(module: *std.Build.Module, target: std.Target) void {
    switch (target.os.tag) {
        .macos => {
            module.linkFramework("Security", .{});
            module.linkFramework("CoreFoundation", .{});
        },
        // Linux shells out (secret-tool / pass) — no library to link, and no
        // musl incompatibility.
        .linux => {},
        .windows => {
            module.linkSystemLibrary("advapi32", .{});
        },
        else => {},
    }
}

// ============================================================================
// VERSION MANAGEMENT - Read version from build.zig.zon
// ============================================================================

/// Compute the build date (`YYYY-MM-DD`) stamped into the registry for the man
/// page `.TH` field. Honors `SOURCE_DATE_EPOCH` (the reproducible-builds
/// convention) when set, otherwise stamps the current build time. Either way
/// the date is fixed at build time, so `zig build docs` is reproducible across
/// runs of the same build.
fn computeBuildDate(b: *std.Build) []const u8 {
    const epoch_secs: u64 = blk: {
        if (b.graph.environ_map.get("SOURCE_DATE_EPOCH")) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (std.fmt.parseInt(u64, trimmed, 10)) |secs| {
                break :blk secs;
            } else |_| {
                logging.logBuildWarning("SOURCE_DATE_EPOCH is not a valid integer ('{s}'); using build time", .{trimmed});
            }
        }
        const ns = std.Io.Clock.real.now(b.graph.io).nanoseconds;
        break :blk @intCast(@divTrunc(ns, std.time.ns_per_s));
    };

    const epoch_day = (std.time.epoch.EpochSeconds{ .secs = epoch_secs }).getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(b.allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    }) catch @panic("OOM");
}

/// Read version from the project's build.zig.zon file
fn readVersionFromZon(b: *std.Build) []const u8 {
    // Read the file from build root
    const content = b.build_root.handle.readFileAlloc(b.graph.io, "build.zig.zon", b.allocator, .limited(1024 * 1024)) catch |err| {
        logging.logBuildWarning("Could not read build.zig.zon, using default version 0.0.0: {any}", .{err});
        return "0.0.0";
    };
    defer b.allocator.free(content);
    const source = b.allocator.dupeZ(u8, content) catch @panic("OOM");
    defer b.allocator.free(source);

    // A real ZON parse of just the field we need — not a line scan, so
    // formatting, comments, and field order don't matter.
    const Manifest = struct { version: []const u8 };
    const manifest = std.zon.parse.fromSliceAlloc(
        Manifest,
        b.allocator,
        source,
        null,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        logging.logBuildWarning("Could not parse version from build.zig.zon, using default version 0.0.0: {any}", .{err});
        return "0.0.0";
    };
    return manifest.version;
}

// ============================================================================
// HIGH-LEVEL BUILD FUNCTIONS - Main entry points for build.zig
// ============================================================================

/// Build function with plugin support that accepts zcli module
fn buildWithPlugins(b: *std.Build, exe: *std.Build.Step.Compile, zcli_dep: *std.Build.Dependency, zcli_module: *std.Build.Module, config: BuildConfig) GenerateError!*std.Build.Module {
    // Get target and optimize from executable
    const target = exe.root_module.resolved_target orelse b.graph.host;
    const optimize = exe.root_module.optimize orelse .Debug;

    // Apply C/C++ dependencies FIRST, before any modules are created
    // This ensures include paths are available when modules use @cImport
    const config_application = @import("config_application.zig");
    const command_configs = config.command_configs orelse &.{};
    config_application.applyCommandConfigsToExecutable(b, exe, command_configs);

    // 1. Discover local plugins. A missing plugins_dir is optional (scan
    //    returns null → no local plugins). Any real failure is surfaced loudly
    //    with the offending path so a broken plugins_dir can't silently build
    //    an app with zero plugins (mirrors the command-discovery reporting
    //    below). We hard-fail via @panic because scanLocalPlugins returns an
    //    error set (not GenerateError) and there is no recoverable state.
    const local_plugins: []const types.PluginInfo = if (config.plugins_dir) |dir|
        (plugin_system.scanLocalPlugins(b, dir) catch |err| switch (err) {
            error.InvalidPath => {
                logging.buildError("Plugin Discovery Error", dir, "Invalid plugins directory path.\nPath contains '..' which is not allowed for security reasons", "Please use a relative path without '..' or an absolute path");
                std.debug.panic("Plugin discovery failed for '{s}': {s}", .{ dir, @errorName(err) });
            },
            error.AccessDenied => {
                logging.buildError("Plugin Discovery Error", dir, "Access denied to plugins directory", "Please check file permissions for the directory");
                std.debug.panic("Plugin discovery failed for '{s}': {s}", .{ dir, @errorName(err) });
            },
            error.OutOfMemory => @panic("OOM"),
            else => {
                logging.buildError("Plugin Discovery Error", dir, "Failed to discover plugins", "Check the plugins directory structure and file permissions");
                std.debug.panic("Plugin discovery failed for '{s}': {s}", .{ dir, @errorName(err) });
            },
        }) orelse &.{}
    else
        &.{};

    // 2. Combine with external plugins
    const all_plugins = plugin_system.combinePlugins(b, local_plugins, config.plugins orelse &.{});

    // 3. Note: Plugin modules are now added directly in module_creation.addPluginModulesToRegistry
    //    using zcli_dep.path() to ensure correct resolution

    // 4. Generate plugin-enhanced registry
    return generatePluginRegistry(b, exe, target, optimize, zcli_dep, zcli_module, config, all_plugins);
}

/// Generate registry with plugin support
fn generatePluginRegistry(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zcli_dep: *std.Build.Dependency,
    zcli_module: *std.Build.Module,
    config: BuildConfig,
    plugins: []const types.PluginInfo,
) GenerateError!*std.Build.Module {
    _ = exe;
    _ = target; // Will be used for plugin compilation
    _ = optimize; // Will be used for plugin compilation

    // Discover all commands at build time. On failure: print an actionable
    // explanation, then propagate an error out of build() — a library must
    // not exit the build process itself.
    var discovered_commands = command_discovery.discoverCommands(b, config.commands_dir) catch |err| {
        switch (err) {
            error.InvalidPath => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Invalid commands directory path.\nPath contains '..' which is not allowed for security reasons", "Please use a relative path without '..' or an absolute path");
            },
            error.FileNotFound => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Commands directory not found", "Please ensure the directory exists and the path is correct");
            },
            error.AccessDenied => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Access denied to commands directory", "Please check file permissions for the directory");
            },
            error.OutOfMemory => @panic("OOM"),
            else => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Failed to discover commands", "Check the command directory structure and file permissions");
                std.debug.print("Error details: {any}\n", .{err});
            },
        }
        return error.CommandDiscoveryFailed;
    };
    defer discovered_commands.deinit();

    // Generate plugin-enhanced registry source code. The only failure here is
    // allocation, which follows std.Build's own convention.
    const registry_source = code_generation.generateComptimeRegistrySource(b.allocator, discovered_commands, config, plugins) catch @panic("OOM");
    defer b.allocator.free(registry_source);

    // Create a write file step to write the generated source
    const write_registry = b.addWriteFiles();
    const registry_file = write_registry.add("zcli_generated.zig", registry_source);

    // Create a module from the generated file
    const registry_module = b.addModule("command_registry", .{
        .root_source_file = registry_file,
    });

    // Add zcli import to registry module
    registry_module.addImport("zcli", zcli_module);

    // Create modules for all discovered command files dynamically
    const shared_modules = config.shared_modules orelse &.{};
    const command_configs = config.command_configs orelse &.{};
    module_creation.createDiscoveredModules(b, registry_module, zcli_module, discovered_commands, config.commands_dir, shared_modules, command_configs);

    // Add plugin imports to registry module
    module_creation.addPluginModulesToRegistry(b, registry_module, zcli_dep, zcli_module, plugins);

    return registry_module;
}

/// Generate the command registry for a zcli project. Call it with `try` from
/// your build():
///
/// ```zig
/// const cmd_registry = try zcli.generate(b, exe, zcli_dep, .{ ... });
/// ```
///
/// The version is always read from the project's build.zig.zon — single
/// source of truth, so there is no version field to pass. The zcli module is
/// derived from `zcli_dep` (it is always `zcli_dep.module("zcli")`) for the
/// same reason.
pub fn generate(b: *std.Build, exe: *std.Build.Step.Compile, zcli_dep: *std.Build.Dependency, config: GenerateConfig) GenerateError!*std.Build.Module {
    const zcli_module = zcli_dep.module("zcli");
    const app_version = readVersionFromZon(b);
    const build_date = computeBuildDate(b);

    // Convert plugin configs to PluginInfo array
    var plugins = std.ArrayList(types.PluginInfo).empty;
    defer plugins.deinit(b.allocator);

    for (config.plugins) |plugin_config| {
        plugins.append(b.allocator, .{
            .name = plugin_config.name,
            // Plugin path is relative to the zcli package, e.g.
            // "packages/core/src/plugins/zcli_help"; appending "/plugin" gives
            // the import path.
            .import_name = b.fmt("{s}/plugin", .{plugin_config.path}),
            .is_local = true, // Plugins are local paths within the zcli package
            .dependency = null, // No separate dependency needed
            .init = plugin_config.init,
        }) catch @panic("OOM");
    }

    // Opt-in native linking. The secrets plugin's native backends call into an
    // OS keychain, which requires dynamic linking. We add each platform's
    // libraries to the executable ONLY when the secrets plugin is registered —
    // so a CLI that does not opt in stays a static, libc-free single binary.
    // This is the build half of ADR-0003's opt-in guarantee (the source half is
    // the compile-time backend selection in the plugin). Registering the plugin
    // for an unsupported OS is a compile error in the plugin source — there is
    // no insecure file fallback — so `linkSecretsBackend` links nothing there.
    for (config.plugins) |plugin_config| {
        if (std.mem.eql(u8, plugin_config.name, "zcli_secrets")) {
            linkSecretsBackend(exe.root_module, exe.rootModuleTarget());
        }
    }

    const build_config = BuildConfig{
        .commands_dir = config.commands_dir,
        .plugins_dir = config.plugins_dir,
        .plugins = plugins.items,
        .shared_modules = config.shared_modules,
        .command_configs = config.command_configs,
        .app_name = config.app_name,
        .app_version = app_version,
        .app_description = config.app_description,
        .build_date = build_date,
    };

    return buildWithPlugins(b, exe, zcli_dep, zcli_module, build_config);
}

/// Generate documentation from command metadata during the build.
///
/// Docs are generated on demand via `zig build docs` (kept off the default
/// build so ordinary builds stay quiet). Output goes to `output_dir`.
///
/// ```zig
/// // Single format (default: markdown)
/// zcli.generateDocs(b, cmd_registry, zcli_dep, .{});
///
/// // Multiple formats — each gets its own subdirectory
/// zcli.generateDocs(b, cmd_registry, zcli_dep, .{
///     .formats = &.{ "markdown", "man" },
///     .output_dir = "docs",
/// });
/// ```
pub fn generateDocs(b: *std.Build, registry_module: *std.Build.Module, zcli_dep: *std.Build.Dependency, config: DocsConfig) void {
    const zcli_module = zcli_dep.module("zcli");
    const doc_exe = b.addExecutable(.{
        .name = "zcli-doc-gen",
        .root_module = b.createModule(.{
            .root_source_file = zcli_dep.path("packages/core/src/doc_gen_main.zig"),
            .target = b.graph.host,
        }),
    });
    doc_exe.root_module.addImport("command_registry", registry_module);
    doc_exe.root_module.addImport("zcli", zcli_module);

    const run = b.addRunArtifact(doc_exe);
    run.addArg(config.output_dir);
    for (config.formats) |fmt| {
        run.addArg(fmt);
    }

    // Only run when explicitly requested via `zig build docs`. Keeping it off
    // the default install step means an ordinary `zig build` stays quiet and
    // fast — no doc-gen output on every build of every consuming project.
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&run.step);
}
