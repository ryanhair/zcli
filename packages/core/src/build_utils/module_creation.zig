const std = @import("std");
const types = @import("types.zig");
const module_names = @import("module_names.zig");
const command_config_lookup = @import("command_config_lookup.zig");

const PluginInfo = types.PluginInfo;
const DiscoveredCommands = types.DiscoveredCommands;

// ============================================================================
// MODULE CREATION - Build-time module creation and linking
// ============================================================================

/// Apply command-specific modules to a command module
fn applyCommandSpecificModules(
    b: *std.Build,
    cmd_module: *std.Build.Module,
    cmd_path: []const []const u8,
    shared_modules: []const types.SharedModule,
    command_configs: []const types.CommandConfig,
) void {
    _ = b;
    // Look up command config (supports inheritance)
    const cmd_config = command_config_lookup.findCommandConfig(cmd_path, command_configs) orelse return;

    // Apply command-specific modules
    for (cmd_config.modules) |module_config| {
        // Check for name collision with shared modules
        if (command_config_lookup.moduleNameExistsInShared(module_config.name, shared_modules)) {
            std.log.err("Command-specific module '{s}' conflicts with shared module", .{module_config.name});
            std.log.err("Command path components: {any}", .{cmd_path});
            @panic("Module name conflict detected");
        }

        // Add module import (C dependencies are handled at the executable level)
        cmd_module.addImport(module_config.name, module_config.module);
    }
}

/// Create modules for all discovered commands dynamically.
///
/// Iterates the single `module_names.flatten` walk — the same list of
/// (module_name, path, file_path) triples code_generation.zig emits imports and
/// registrations from — so a build module is created and named for exactly the
/// commands the generated registry imports, with no separate recursion to keep
/// in sync. Pure groups contribute no entry (they get no module); their
/// descendants still appear because flatten visits them.
pub fn createDiscoveredModules(
    b: *std.Build,
    registry_module: *std.Build.Module,
    zcli_module: *std.Build.Module,
    commands: DiscoveredCommands,
    commands_dir: []const u8,
    shared_modules: []const types.SharedModule,
    command_configs: []const types.CommandConfig,
) void {
    const emitted = module_names.flatten(b.allocator, commands) catch @panic("OOM");
    defer module_names.freeEmitted(b.allocator, emitted);
    for (emitted) |e| {
        const full_path = b.fmt("{s}/{s}", .{ commands_dir, e.file_path });
        const cmd_module = b.addModule(e.module_name, .{
            .root_source_file = b.path(full_path),
        });
        cmd_module.addImport("zcli", zcli_module);
        // Let commands optionally name the generated Context type via
        // `@import("command_registry").Context`. The back-reference is safe:
        // Context depends only on config + plugins, not commands.
        cmd_module.addImport("command_registry", registry_module);

        // Add shared modules
        for (shared_modules) |shared_mod| {
            cmd_module.addImport(shared_mod.name, shared_mod.module);
        }

        // Add command-specific modules
        applyCommandSpecificModules(b, cmd_module, e.path, shared_modules, command_configs);

        registry_module.addImport(e.module_name, cmd_module);
    }
}

/// Add plugin modules to registry during generation
pub fn addPluginModulesToRegistry(b: *std.Build, registry_module: *std.Build.Module, zcli_dep: *std.Build.Dependency, zcli_module: *std.Build.Module, plugins: []const PluginInfo) void {
    for (plugins) |plugin_info| {
        if (plugin_info.is_local) {
            // Two kinds of "local" plugin resolve against different roots:
            //   - project_path set → a plugin in the *consuming project*
            //     (discovered under plugins_dir); resolve with b.path.
            //   - otherwise → a framework built-in living in the zcli package;
            //     import_name is like "src/plugins/zcli_help/plugin", resolved
            //     against the zcli dependency.
            const root_source_file = if (plugin_info.project_path) |project_path|
                b.path(project_path)
            else
                zcli_dep.path(b.fmt("{s}.zig", .{plugin_info.import_name}));

            const plugin_module = b.addModule(plugin_info.import_name, .{
                .root_source_file = root_source_file,
            });
            plugin_module.addImport("zcli", zcli_module);

            registry_module.addImport(plugin_info.import_name, plugin_module);
        } else {
            if (plugin_info.dependency) |dep| {
                const plugin_module = dep.module("plugin");
                plugin_module.addImport("zcli", zcli_module);
                registry_module.addImport(plugin_info.import_name, plugin_module);
            }
        }
    }
}
