const std = @import("std");
const types = @import("types.zig");
const command_config_lookup = @import("command_config_lookup.zig");

const PluginInfo = types.PluginInfo;
const DiscoveredCommands = types.DiscoveredCommands;
const CommandInfo = types.CommandInfo;

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

/// Create modules for all discovered commands dynamically
pub fn createDiscoveredModules(
    b: *std.Build,
    registry_module: *std.Build.Module,
    zcli_module: *std.Build.Module,
    commands: DiscoveredCommands,
    commands_dir: []const u8,
    shared_modules: []const types.SharedModule,
    command_configs: []const types.CommandConfig,
) void {
    var it = commands.root.iterator();
    while (it.next()) |entry| {
        const cmd_name = entry.key_ptr.*;
        const cmd_info = entry.value_ptr.*;

        if (cmd_info.command_type != .leaf) {
            // Create module for optional group with index file
            if (cmd_info.command_type == .optional_group) {
                const module_name = b.fmt("{s}_index", .{cmd_name});
                const full_path = b.fmt("{s}/{s}", .{ commands_dir, cmd_info.file_path });
                const cmd_module = b.addModule(module_name, .{
                    .root_source_file = b.path(full_path),
                });
                cmd_module.addImport("zcli", zcli_module);

                // Add shared modules
                for (shared_modules) |shared_mod| {
                    cmd_module.addImport(shared_mod.name, shared_mod.module);
                }

                // Add command-specific modules
                applyCommandSpecificModules(b, cmd_module, cmd_info.path, shared_modules, command_configs);

                registry_module.addImport(module_name, cmd_module);
            }
            // Create modules for subcommands
            createGroupModules(b, registry_module, zcli_module, cmd_name, &cmd_info, commands_dir, shared_modules, command_configs);
        } else {
            const module_name = if (std.mem.eql(u8, cmd_name, "test"))
                "cmd_test"
            else
                b.fmt("cmd_{s}", .{cmd_name});

            const full_path = b.fmt("{s}/{s}", .{ commands_dir, cmd_info.file_path });
            const cmd_module = b.addModule(module_name, .{
                .root_source_file = b.path(full_path),
            });
            cmd_module.addImport("zcli", zcli_module);

            // Add shared modules
            for (shared_modules) |shared_mod| {
                cmd_module.addImport(shared_mod.name, shared_mod.module);
            }

            // Add command-specific modules
            applyCommandSpecificModules(b, cmd_module, cmd_info.path, shared_modules, command_configs);

            registry_module.addImport(module_name, cmd_module);
        }
    }
}

/// Create modules for command groups recursively
fn createGroupModules(
    b: *std.Build,
    registry_module: *std.Build.Module,
    zcli_module: *std.Build.Module,
    _: []const u8,
    group_info: *const CommandInfo,
    commands_dir: []const u8,
    shared_modules: []const types.SharedModule,
    command_configs: []const types.CommandConfig,
) void {
    if (group_info.subcommands) |subcommands| {
        var it = subcommands.iterator();
        while (it.next()) |entry| {
            const subcmd_name = entry.key_ptr.*;
            const subcmd_info = entry.value_ptr.*;

            if (subcmd_info.command_type == .optional_group) {
                // Create module for nested optional group
                var module_name_parts = std.ArrayList([]const u8){};
                defer module_name_parts.deinit(b.allocator);

                for (subcmd_info.path) |part| {
                    const sanitized_part = std.mem.replaceOwned(u8, b.allocator, part, "-", "_") catch part;
                    module_name_parts.append(b.allocator, sanitized_part) catch unreachable;
                }

                const module_name = std.mem.join(b.allocator, "_", module_name_parts.items) catch unreachable;
                const module_name_with_index = b.fmt("{s}_index", .{module_name});

                const full_path = b.fmt("{s}/{s}", .{ commands_dir, subcmd_info.file_path });
                const cmd_module = b.addModule(module_name_with_index, .{
                    .root_source_file = b.path(full_path),
                });
                cmd_module.addImport("zcli", zcli_module);

                // Add shared modules
                for (shared_modules) |shared_mod| {
                    cmd_module.addImport(shared_mod.name, shared_mod.module);
                }

                // Add command-specific modules
                applyCommandSpecificModules(b, cmd_module, subcmd_info.path, shared_modules, command_configs);

                registry_module.addImport(module_name_with_index, cmd_module);

                // Also recurse for its subcommands
                createGroupModules(b, registry_module, zcli_module, subcmd_name, &subcmd_info, commands_dir, shared_modules, command_configs);
            } else if (subcmd_info.command_type == .pure_group) {
                // Pure groups have no module, just recurse
                createGroupModules(b, registry_module, zcli_module, subcmd_name, &subcmd_info, commands_dir, shared_modules, command_configs);
            } else {
                // Generate module name from the full command path to handle nested directories
                // This ensures unique module names even for deeply nested commands
                var module_name_parts = std.ArrayList([]const u8){};
                defer module_name_parts.deinit(b.allocator);

                for (subcmd_info.path) |part| {
                    const sanitized_part = std.mem.replaceOwned(u8, b.allocator, part, "-", "_") catch part;
                    module_name_parts.append(b.allocator, sanitized_part) catch unreachable;
                }

                const module_name = std.mem.join(b.allocator, "_", module_name_parts.items) catch unreachable;

                const full_path = b.fmt("{s}/{s}", .{ commands_dir, subcmd_info.file_path });
                const cmd_module = b.addModule(module_name, .{
                    .root_source_file = b.path(full_path),
                });
                cmd_module.addImport("zcli", zcli_module);

                // Add shared modules
                for (shared_modules) |shared_mod| {
                    cmd_module.addImport(shared_mod.name, shared_mod.module);
                }

                // Add command-specific modules
                applyCommandSpecificModules(b, cmd_module, subcmd_info.path, shared_modules, command_configs);

                registry_module.addImport(module_name, cmd_module);
            }
        }
    }
}

/// Add plugin modules to registry during generation
pub fn addPluginModulesToRegistry(b: *std.Build, registry_module: *std.Build.Module, zcli_dep: *std.Build.Dependency, zcli_module: *std.Build.Module, plugins: []const PluginInfo) void {
    for (plugins) |plugin_info| {
        if (plugin_info.is_local) {
            // import_name is like "src/plugins/zcli_help/plugin"
            // zcli_dep path handling:
            // - If using .path dependency, it points directly to packages/core
            // - If using .url dependency, it points to the repo root
            // We'll try both paths for compatibility
            const plugin_path = b.fmt("{s}.zig", .{plugin_info.import_name});
            const plugin_module = b.addModule(plugin_info.import_name, .{
                .root_source_file = zcli_dep.path(plugin_path),
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
