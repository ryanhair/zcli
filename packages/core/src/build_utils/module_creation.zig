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

        if (cmd_info.command_type != .leaf) {
            // Create module for optional group with index file
            if (cmd_info.command_type == .optional_group) {
                const module_name = b.fmt("{s}_index", .{cmd_name});
                const full_path = b.fmt("{s}/{s}", .{ commands_dir, cmd_info.file_path });
                const cmd_module = b.addModule(module_name, .{
                    .root_source_file = b.path(full_path),
                });
                cmd_module.addImport("zcli", zcli_module);
                registry_module.addImport(module_name, cmd_module);
            }
            // Create modules for subcommands
            createGroupModules(b, registry_module, zcli_module, cmd_name, &cmd_info, commands_dir);
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
            registry_module.addImport(module_name, cmd_module);
        }
    }
}

/// Create modules for command groups recursively
fn createGroupModules(b: *std.Build, registry_module: *std.Build.Module, zcli_module: *std.Build.Module, _: []const u8, group_info: *const CommandInfo, commands_dir: []const u8) void {
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
                registry_module.addImport(module_name_with_index, cmd_module);

                // Also recurse for its subcommands
                createGroupModules(b, registry_module, zcli_module, subcmd_name, &subcmd_info, commands_dir);
            } else if (subcmd_info.command_type == .pure_group) {
                // Pure groups have no module, just recurse
                createGroupModules(b, registry_module, zcli_module, subcmd_name, &subcmd_info, commands_dir);
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
                registry_module.addImport(module_name, cmd_module);
            }
        }
    }
}

/// Add plugin modules to registry during generation
pub fn addPluginModulesToRegistry(b: *std.Build, registry_module: *std.Build.Module, zcli_dep: *std.Build.Dependency, zcli_module: *std.Build.Module, plugins: []const PluginInfo) void {
    // Create markdown_fmt module from zcli dependency's path
    // (markdown_fmt is a dependency of zcli's build.zig.zon)
    // For external deps, it's at packages/markdown_fmt; for local it's ../markdown_fmt
    const markdown_fmt_module = b.addModule("markdown_fmt_for_help", .{
        .root_source_file = zcli_dep.path("../markdown_fmt/src/main.zig"),
    });

    for (plugins) |plugin_info| {
        if (plugin_info.is_local) {
            // import_name is like "src/plugins/zcli_help/plugin"
            // zcli_dep.path() handles the resolution - for local builds it's relative to core,
            // for external deps it's relative to the extracted archive root
            const plugin_path = b.fmt("{s}.zig", .{plugin_info.import_name});
            const plugin_module = b.addModule(plugin_info.import_name, .{
                .root_source_file = zcli_dep.path(plugin_path),
            });
            plugin_module.addImport("zcli", zcli_module);

            // Add markdown_fmt for help plugin
            if (std.mem.indexOf(u8, plugin_info.name, "help") != null) {
                plugin_module.addImport("markdown_fmt", markdown_fmt_module);
            }

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
