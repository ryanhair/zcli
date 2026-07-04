const std = @import("std");
const logging = @import("../logging.zig");
const types = @import("types.zig");
const module_creation = @import("module_creation.zig");
const plugin_system = @import("plugin_system.zig");
const command_discovery = @import("command_discovery.zig");
const code_generation = @import("code_generation.zig");

const CommandInfo = types.CommandInfo;
const BuildConfig = types.BuildConfig;
const DiscoveredCommands = types.DiscoveredCommands;
const GenerateConfig = types.GenerateConfig;
const DocsConfig = types.DocsConfig;

/// `generate()` failed because of a problem in the consuming project's
/// configuration. A human-readable explanation has already been printed;
/// propagate this out of `build()` to stop the build.
pub const GenerateError = error{CommandDiscoveryFailed};

/// Link the native libraries the `zcli_secrets` plugin's backend needs for
/// `target`. macOS: Security + CoreFoundation frameworks. Linux: libsecret-1 +
/// glib-2.0 (over libc). Windows: advapi32. Any other OS has no secure backend —
/// registering the plugin there is a compile error in the plugin source — so
/// nothing is linked. Exposed so the plugin's own test targets can link exactly
/// the same way a registered app does.
pub fn linkSecretsBackend(module: *std.Build.Module, target: std.Target) void {
    switch (target.os.tag) {
        .macos => {
            module.linkFramework("Security", .{});
            module.linkFramework("CoreFoundation", .{});
        },
        .linux => {
            // libsecret/glib are glibc-based, so a musl target — zcli's flagship
            // static-single-binary case — cannot link them. Fail with a legible
            // message instead of a cryptic linker/pkg-config error, mirroring the
            // plugin's own unsupported-OS @compileError.
            if (target.abi.isMusl()) std.debug.panic(
                "zcli_secrets: the Linux Secret Service backend links libsecret " ++
                    "(glibc), which is incompatible with a musl target ({s}). Build " ++
                    "with a gnu ABI (e.g. -Dtarget=x86_64-linux-gnu), or do not " ++
                    "register the plugin for musl.",
                .{@tagName(target.abi)},
            );
            module.link_libc = true;
            module.linkSystemLibrary("secret-1", .{});
            module.linkSystemLibrary("glib-2.0", .{});
        },
        .windows => {
            module.linkSystemLibrary("advapi32", .{});
        },
        else => {},
    }
}

// ============================================================================
// VERSION MANAGEMENT - Read version from build.zig.zon
// ============================================================================

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

    // 1. Discover local plugins
    const local_plugins = if (config.plugins_dir) |dir|
        plugin_system.scanLocalPlugins(b, dir) catch &.{}
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
/// const cmd_registry = try zcli.generate(b, exe, zcli_dep, zcli_module, .{ ... });
/// ```
///
/// The version is always read from the project's build.zig.zon — single
/// source of truth, so there is no version field to pass.
pub fn generate(b: *std.Build, exe: *std.Build.Step.Compile, zcli_dep: *std.Build.Dependency, zcli_module: *std.Build.Module, config: GenerateConfig) GenerateError!*std.Build.Module {
    const app_version = readVersionFromZon(b);

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
    };

    return buildWithPlugins(b, exe, zcli_dep, zcli_module, build_config);
}

/// Generate documentation from command metadata during the build.
///
/// Docs are generated automatically on every `zig build` and also
/// available via `zig build docs`. Output goes to `output_dir`.
///
/// ```zig
/// // Single format (default: markdown)
/// zcli.generateDocs(b, cmd_registry, zcli_dep, zcli_module, .{});
///
/// // Multiple formats — each gets its own subdirectory
/// zcli.generateDocs(b, cmd_registry, zcli_dep, zcli_module, .{
///     .formats = &.{ "markdown", "man" },
///     .output_dir = "docs",
/// });
/// ```
pub fn generateDocs(b: *std.Build, registry_module: *std.Build.Module, zcli_dep: *std.Build.Dependency, zcli_module: *std.Build.Module, config: DocsConfig) void {
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

    // Run on every `zig build`
    b.getInstallStep().dependOn(&run.step);

    // Also available as explicit `zig build docs`
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&run.step);
}
