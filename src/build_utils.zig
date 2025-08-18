// ============================================================================
// BUILD UTILITIES - Modular build system for zcli
// ============================================================================
//
// This module has been refactored into a modular structure for better maintainability:
//
// - build_utils/types.zig            - Shared types and structures
// - build_utils/plugin_system.zig    - Plugin discovery and management  
// - build_utils/command_discovery.zig - Command scanning and validation
// - build_utils/code_generation.zig  - Registry source code generation
// - build_utils/module_creation.zig  - Build-time module creation
// - build_utils/main.zig             - High-level coordination functions
//
// This file re-exports all functionality for backward compatibility.

const main = @import("build_utils/main.zig");

// Re-export all types
pub const PluginInfo = main.PluginInfo;
pub const CommandInfo = main.CommandInfo;
pub const DiscoveredCommands = main.DiscoveredCommands;
pub const BuildConfig = main.BuildConfig;
pub const PluginConfig = main.PluginConfig;
pub const ExternalPluginBuildConfig = main.ExternalPluginBuildConfig;

// Re-export submodules
pub const types = main.types;
pub const plugin_system = main.plugin_system;
pub const command_discovery = main.command_discovery;
pub const code_generation = main.code_generation;
pub const module_creation = main.module_creation;

// Re-export plugin system functions
pub const plugin = main.plugin;
pub const scanLocalPlugins = main.scanLocalPlugins;
pub const combinePlugins = main.combinePlugins;
pub const addPluginModules = main.addPluginModules;

// Re-export command discovery functions
pub const discoverCommands = main.discoverCommands;
pub const isValidCommandName = main.isValidCommandName;

// Re-export code generation functions
pub const generatePluginRegistrySource = main.generatePluginRegistrySource;
pub const generateRegistrySource = main.generateRegistrySource;

// Re-export module creation functions
pub const createDiscoveredModules = main.createDiscoveredModules;

// Re-export high-level build functions
pub const buildWithPlugins = main.buildWithPlugins;
pub const generatePluginRegistry = main.generatePluginRegistry;
pub const generateCommandRegistry = main.generateCommandRegistry;
pub const buildWithExternalPlugins = main.buildWithExternalPlugins;

// Re-export tests
test {
    _ = main;
}