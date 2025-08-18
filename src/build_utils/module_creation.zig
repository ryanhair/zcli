const std = @import("std");
const types = @import("types.zig");

const PluginInfo = types.PluginInfo;
const DiscoveredCommands = types.DiscoveredCommands;
const CommandInfo = types.CommandInfo;

// ============================================================================
// MODULE CREATION - Build-time module creation and linking
// ============================================================================

/// Create modules for all discovered commands dynamically
pub fn createDiscoveredModules(b: *std.Build, registry_module: *std.Build.Module, zcli_module: *std.Build.Module, commands: DiscoveredCommands, commands_dir: []const u8) void {
    var it = commands.root.iterator();
    while (it.next()) |entry| {
        const cmd_name = entry.key_ptr.*;
        const cmd_info = entry.value_ptr.*;
        
        if (cmd_info.is_group) {
            createGroupModules(b, registry_module, zcli_module, cmd_name, &cmd_info, commands_dir);
        } else {
            const module_name = if (std.mem.eql(u8, cmd_name, "test")) 
                "cmd_test" 
            else 
                b.fmt("cmd_{s}", .{cmd_name});
            
            const full_path = b.fmt("{s}/{s}", .{ commands_dir, cmd_info.path });
            const cmd_module = b.addModule(module_name, .{
                .root_source_file = b.path(full_path),
            });
            cmd_module.addImport("zcli", zcli_module);
            registry_module.addImport(module_name, cmd_module);
        }
    }
}

/// Create modules for command groups recursively
fn createGroupModules(b: *std.Build, registry_module: *std.Build.Module, zcli_module: *std.Build.Module, group_name: []const u8, group_info: *const CommandInfo, commands_dir: []const u8) void {
    if (group_info.subcommands) |subcommands| {
        var it = subcommands.iterator();
        while (it.next()) |entry| {
            const subcmd_name = entry.key_ptr.*;
            const subcmd_info = entry.value_ptr.*;
            
            if (subcmd_info.is_group) {
                createGroupModules(b, registry_module, zcli_module, subcmd_name, &subcmd_info, commands_dir);
            } else {
                const module_name = b.fmt("{s}_{s}", .{ group_name, subcmd_name });
                
                const full_path = b.fmt("{s}/{s}", .{ commands_dir, subcmd_info.path });
                const cmd_module = b.addModule(module_name, .{
                    .root_source_file = b.path(full_path),
                });
                cmd_module.addImport("zcli", zcli_module);
                registry_module.addImport(module_name, cmd_module);
            }
        }
    }
}

/// Add plugin modules to registry during generation
pub fn addPluginModulesToRegistry(b: *std.Build, registry_module: *std.Build.Module, plugins: []const PluginInfo) void {
    for (plugins) |plugin_info| {
        if (plugin_info.is_local) {
            const plugin_module = b.addModule(plugin_info.import_name, .{
                .root_source_file = b.path(if (std.mem.endsWith(u8, plugin_info.import_name, "/plugin"))
                    b.fmt("src/{s}.zig", .{plugin_info.import_name})
                else
                    b.fmt("src/{s}.zig", .{plugin_info.import_name})),
            });
            registry_module.addImport(plugin_info.import_name, plugin_module);
        } else {
            if (plugin_info.dependency) |dep| {
                const plugin_module = dep.module("plugin");
                registry_module.addImport(plugin_info.name, plugin_module);
            }
        }
    }
}