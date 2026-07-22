const std = @import("std");
const logging = @import("../logging.zig");
const types = @import("types.zig");
const module_creation = @import("module_creation.zig");
const module_names = @import("module_names.zig");
const plugin_system = @import("plugin_system.zig");
const command_discovery = @import("command_discovery.zig");
const code_generation = @import("code_generation.zig");

const DiscoveredCommand = types.DiscoveredCommand;
const BuildConfig = types.BuildConfig;
const DiscoveredCommands = types.DiscoveredCommands;
const GenerateConfig = types.GenerateConfig;

/// `generate()` failed because of a problem in the consuming project's
/// configuration. A human-readable explanation has already been printed;
/// propagate this out of `build()` to stop the build. Every failure path here
/// returns one of these rather than exiting/panicking — a library must not kill
/// the build process itself, and a config mistake must stop the build loudly
/// instead of silently producing (say) a plugin-less binary.
pub const GenerateError = error{
    CommandDiscoveryFailed,
    PluginDiscoveryFailed,
    /// A `PluginConfig` set neither `path` nor `dependency` (or set both).
    PluginConfigInvalid,
    /// An external plugin's `name` is not a valid package/identifier name and
    /// would break out of the generated `@import("...")` string literal.
    PluginNameInvalid,
    /// Two discovered commands sanitize to the same generated module identifier.
    CommandNameCollision,
    /// Two registered plugins sanitize to the same generated import identifier.
    PluginNameCollision,
    /// A registered plugin sanitizes to a reserved generated-registry
    /// identifier (`std`, `zcli`, or a `cmd_`/`_index` affix).
    ReservedPluginIdentifier,
    /// A plugin tool's step name is already taken — by another plugin's tool
    /// or by a step the project registered before calling `generate()`.
    ToolStepCollision,
    /// A `PluginConfig` opted into `.tool` but its external package exposes no
    /// module named `tool`.
    ToolModuleMissing,
};

/// Re-exported so the zcli_secrets plugin's own test targets (in
/// packages/core/build.zig) link exactly the same way a registered app does.
/// The definition lives in types.zig alongside `PluginConfig.link`, which is
/// the mechanism `generate()` uses to apply it.
pub const linkSecretsBackend = types.linkSecretsBackend;

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

    // 1. Discover local plugins. A missing plugins_dir is optional (scan
    //    returns null → no local plugins). Any real failure is surfaced loudly
    //    with the offending path, then propagated out of build() as a
    //    GenerateError — a broken plugins_dir must stop the build, never
    //    silently produce an app with zero plugins (mirrors the
    //    command-discovery reporting below). OOM keeps the std.Build-wide
    //    `@panic("OOM")` convention: not user-actionable, and loud already.
    const local_plugins: []const types.PluginInfo = if (config.plugins_dir) |dir|
        (plugin_system.scanLocalPlugins(b, dir) catch |err| switch (err) {
            error.InvalidPath => {
                logging.buildError("Plugin Discovery Error", dir, "Invalid plugins directory path.\nPath contains '..' which is not allowed for security reasons", "Please use a relative path without '..' or an absolute path");
                return error.PluginDiscoveryFailed;
            },
            error.AccessDenied => {
                logging.buildError("Plugin Discovery Error", dir, "Access denied to plugins directory", "Please check file permissions for the directory");
                return error.PluginDiscoveryFailed;
            },
            error.InvalidPluginName => {
                // The specific, actionable message (naming the exact
                // file/directory) was already logged at the point of
                // discovery; adding the generic block here would only bury
                // it (mirrors command_discovery's error.InvalidCommandName).
                return error.PluginDiscoveryFailed;
            },
            error.OutOfMemory => @panic("OOM"),
            else => {
                logging.buildError("Plugin Discovery Error", dir, "Failed to discover plugins", "Check the plugins directory structure and file permissions");
                std.debug.print("Error details: {any}\n", .{err});
                return error.PluginDiscoveryFailed;
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
            error.DuplicateCommandName, error.InvalidCommandName, error.MaxCommandDepthExceeded, error.CommandPathUnreadable => {
                // The specific, actionable message (naming the exact file(s))
                // was already logged at the point of discovery; adding the
                // generic block here would only bury it.
            },
            else => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Failed to discover commands", "Check the command directory structure and file permissions");
                std.debug.print("Error details: {any}\n", .{err});
            },
        }
        return error.CommandDiscoveryFailed;
    };
    defer discovered_commands.deinit();

    // Command file names are sanitized (non-alnum → `_`) and path parts joined
    // with `_` to form each generated module identifier, so `foo/bar-baz.zig`
    // and `foo/bar/baz.zig` (or `my-cmd.zig` and `my_cmd.zig`) would collide.
    // Two commands sharing one identifier emit duplicate `const X = @import(...)`
    // decls in the registry — an opaque compile error — so reject it here with a
    // message naming both files instead.
    if (module_names.findModuleNameCollision(b.allocator, discovered_commands) catch @panic("OOM")) |collision| {
        const detail = b.fmt("'{s}', generated by both {s} and {s}", .{
            collision.module_name,
            collision.first_file,
            collision.second_file,
        });
        logging.buildError(
            "Command Name Collision",
            detail,
            "Two commands map to the same generated registry module identifier",
            "Rename one command so their sanitized paths differ — '-' and '/' both become '_', so e.g. 'a/b-c.zig' and 'a/b/c.zig' collide",
        );
        return error.CommandNameCollision;
    }

    // Plugin names sanitize the same way (non-alnum → `_`) to form each
    // `const X = @import(...)` decl in the registry, so two plugins whose names
    // sanitize alike (a local `my-plugin.zig` and an external `.name =
    // "my_plugin"`, or a local plugin shadowing a built-in) would emit a
    // duplicate `const` — an opaque compile error — so reject it here with a
    // message naming both plugins instead. Mirrors the command check above.
    if (plugin_system.findPluginNameCollision(b.allocator, plugins) catch @panic("OOM")) |collision| {
        const detail = b.fmt("'{s}', generated by both {s} and {s}", .{
            collision.identifier,
            plugin_system.pluginLocator(b, collision.first),
            plugin_system.pluginLocator(b, collision.second),
        });
        logging.buildError(
            "Plugin Name Collision",
            detail,
            "Two plugins map to the same generated registry import identifier",
            "Rename one plugin so their sanitized names differ — every non-alphanumeric byte (e.g. '-') becomes '_', so e.g. a local 'my-plugin.zig' and an external '.name = \"my_plugin\"' collide",
        );
        return error.PluginNameCollision;
    }

    // A plugin name sanitizing to a reserved generated-registry identifier
    // (the `std`/`zcli` top-of-file imports, or the `cmd_`/`_index`
    // affixes every command module gets) would emit a duplicate top-level
    // decl the same way a plugin-vs-plugin collision would — but commands
    // can never trigger it themselves, so it's checked separately from the
    // symmetric pass above (#637).
    if (plugin_system.findReservedPluginIdentifier(b.allocator, plugins) catch @panic("OOM")) |reserved| {
        const detail = b.fmt("'{s}' sanitizes to '{s}'", .{
            plugin_system.pluginLocator(b, reserved.plugin),
            reserved.identifier,
        });
        logging.buildError(
            "Reserved Plugin Identifier",
            detail,
            "Plugin name sanitizes to a reserved generated-registry identifier",
            "The generated registry reserves 'std', 'zcli', and any 'cmd_'/'_index'-affixed identifier for itself — rename the plugin so its sanitized name avoids these",
        );
        return error.ReservedPluginIdentifier;
    }

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

    // Convert plugin configs to PluginInfo array. Each explicit plugin is
    // registered one of two ways (see PluginConfig): a built-in whose source
    // lives inside the zcli package (`.path` set), or a third-party plugin
    // shipped as its own Zig package (`.dependency` set). Exactly one must be
    // set; getting it wrong stops the build loudly.
    var plugins = std.ArrayList(types.PluginInfo).empty;
    defer plugins.deinit(b.allocator);

    for (config.plugins) |plugin_config| {
        if (plugin_config.dependency) |dep| {
            if (plugin_config.path != null) {
                logging.buildError("Plugin Config Error", plugin_config.name, "A plugin sets both '.path' and '.dependency'", "Use '.path' (via zcli.builtin) for a built-in, or '.dependency' for an external package — not both");
                return error.PluginConfigInvalid;
            }
            // The external plugin's name is emitted verbatim as its
            // `@import("<name>")` string in the generated registry. Reject a
            // name that isn't a valid package/identifier here — otherwise a
            // quote/backslash/space in it produces an opaque compile error in
            // zcli_generated.zig instead of this clean diagnostic. (Built-in
            // `.path` plugins import a filesystem-relative path, not the name,
            // and that path is escaped at emission.)
            if (!plugin_system.isValidPluginName(plugin_config.name)) {
                logging.buildError("Plugin Config Error", plugin_config.name, "External plugin name is not a valid package name", "Use letters, digits, '_' and '-' only, starting with a letter or '_' (no spaces, quotes, or path separators)");
                return error.PluginNameInvalid;
            }
            // A package that exposes no `plugin` module is build-only: it
            // ships a tool and contributes nothing to the registry. Requiring
            // `.tool` in that case keeps a do-nothing registration loud.
            if (plugin_config.build_only or dep.builder.modules.get("plugin") == null) {
                if (plugin_config.tool == null) {
                    logging.buildError("Plugin Config Error", plugin_config.name, "The plugin package exposes no 'plugin' module and no '.tool' was declared, so registering it would do nothing", "Expose the plugin's runtime entry point as a module named 'plugin' in its build.zig, or opt into its build tool by setting '.tool' with a step name and description");
                    return error.PluginConfigInvalid;
                }
                continue;
            }
            // External package plugin: its module is resolved from the
            // dependency in module_creation.addPluginModulesToRegistry via
            // `dep.module("plugin")`; the registry imports it under the
            // plugin's registration name.
            plugins.append(b.allocator, .{
                .name = plugin_config.name,
                .import_name = plugin_config.name,
                .is_local = false,
                .dependency = dep,
                .config = plugin_config.config,
            }) catch @panic("OOM");
        } else if (plugin_config.path) |path| {
            // A build-only built-in (e.g. `.docs`) ships no runtime module —
            // nothing to register; its tool is wired below.
            if (plugin_config.build_only) continue;
            // Built-in: path is relative to the zcli package, e.g.
            // "packages/core/src/plugins/zcli_help"; appending "/plugin" gives
            // the import path resolved against the zcli dependency.
            plugins.append(b.allocator, .{
                .name = plugin_config.name,
                .import_name = b.fmt("{s}/plugin", .{path}),
                .is_local = true,
                .dependency = null,
                .config = plugin_config.config,
            }) catch @panic("OOM");
        } else {
            logging.buildError("Plugin Config Error", plugin_config.name, "A plugin sets neither '.path' nor '.dependency'", "Register a built-in with zcli.builtin(), or an external package with '.dependency = b.dependency(...)'");
            return error.PluginConfigInvalid;
        }
    }

    // Opt-in native linking, driven by each plugin's own `.link` declaration —
    // no plugin is special-cased by name here. A plugin whose backend calls into
    // system libraries (the secrets plugin's OS keychain, or an external
    // plugin's own native deps) sets `PluginConfig.link`; we apply it to the
    // executable ONLY when that plugin is registered, so a CLI that does not opt
    // in stays a static, libc-free single binary. This is the build half of
    // ADR-0003's opt-in guarantee (the source half is the compile-time backend
    // selection in the plugin). For the secrets plugin on an unsupported OS,
    // registering it is a compile error in the plugin source (no insecure file
    // fallback), and its `linkSecretsBackend` hook links nothing there.
    for (config.plugins) |plugin_config| {
        // A build-only plugin puts nothing in the binary, so it has nothing
        // to link into it either (its tool executable links for itself).
        if (plugin_config.build_only) continue;
        if (plugin_config.link) |linkFn| {
            linkFn(exe.root_module, exe.rootModuleTarget());
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

    const registry_module = try buildWithPlugins(b, exe, zcli_dep, zcli_module, build_config);

    // Wire each plugin's build-time tool (see PluginConfig.tool): a host
    // executable importing the registry just generated, registered as a
    // top-level step. Done last so every tool sees the same registry module
    // the app itself compiles against.
    for (config.plugins) |plugin_config| {
        if (plugin_config.tool != null) {
            try wireToolStep(b, zcli_dep, zcli_module, registry_module, plugin_config);
        }
    }

    return registry_module;
}

/// Build a plugin's tool as a host executable and register its build step.
/// The tool's root module gets three imports: `command_registry` (the
/// consumer's generated registry — comptime command metadata), `zcli`, and
/// `tool_config` (a generated module exposing the plugin's rendered config
/// literal through a typed accessor). The tool is compiled for the build host
/// and never linked into the shipped binary; its step is off the default
/// install path, so ordinary builds don't pay for it.
fn wireToolStep(
    b: *std.Build,
    zcli_dep: *std.Build.Dependency,
    zcli_module: *std.Build.Module,
    registry_module: *std.Build.Module,
    plugin_config: types.PluginConfig,
) GenerateError!void {
    const tool = plugin_config.tool.?;

    // b.step() panics on a duplicate name; catch it up front and explain.
    if (b.top_level_steps.contains(tool.step)) {
        const detail = b.fmt("plugin '{s}', step '{s}'", .{ plugin_config.name, tool.step });
        logging.buildError("Plugin Tool Error", detail, "The tool's step name is already taken", "Another plugin's tool (or a step your build.zig registered before generate()) already uses this name — remove one of the two");
        return error.ToolStepCollision;
    }

    // Resolve the tool's root module: a built-in's tool.zig lives next to its
    // plugin source in the zcli package; an external package exposes a module
    // named `tool` (declared without target — tools always run on the build
    // host, so the target is resolved here).
    const tool_module = if (plugin_config.dependency) |dep| blk: {
        const module = dep.builder.modules.get("tool") orelse {
            logging.buildError("Plugin Tool Error", plugin_config.name, "'.tool' is set but the plugin package exposes no 'tool' module", "Expose the tool's root source as a module named 'tool' in the plugin package's build.zig (b.addModule(\"tool\", ...)), or drop the '.tool' opt-in");
            return error.ToolModuleMissing;
        };
        if (module.resolved_target == null) module.resolved_target = b.graph.host;
        break :blk module;
    } else b.createModule(.{
        .root_source_file = zcli_dep.path(b.fmt("{s}/tool.zig", .{plugin_config.path.?})),
        .target = b.graph.host,
    });

    // The rendered config literal, exposed through a typed accessor so it is
    // evaluated with the tool's own Config type as result type — the same
    // trick the generated registry's `.init(<literal>)` call uses.
    const tool_config_source = if (plugin_config.config) |literal|
        b.fmt("// Generated by zcli - DO NOT EDIT\npub fn config(comptime Config: type) Config {{\n    return {s};\n}}\n", .{literal})
    else
        "// Generated by zcli - DO NOT EDIT\npub fn config(comptime Config: type) Config {\n    return .{};\n}\n";
    const write_config = b.addWriteFiles();
    const tool_config_module = b.createModule(.{
        .root_source_file = write_config.add("tool_config.zig", tool_config_source),
    });

    tool_module.addImport("command_registry", registry_module);
    tool_module.addImport("zcli", zcli_module);
    tool_module.addImport("tool_config", tool_config_module);

    const tool_exe = b.addExecutable(.{
        .name = b.fmt("{s}-tool", .{plugin_config.name}),
        .root_module = tool_module,
    });

    const run = b.addRunArtifact(tool_exe);
    const tool_step = b.step(tool.step, tool.description);
    tool_step.dependOn(&run.step);
}

