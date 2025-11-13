const std = @import("std");
const types = @import("types.zig");

/// Find command config by path, checking parent paths for inheritance
/// Returns the most specific matching config (exact match first, then parents)
pub fn findCommandConfig(
    command_path: []const []const u8,
    configs: []const types.CommandConfig,
) ?types.CommandConfig {
    // First try exact match
    for (configs) |config| {
        if (pathsEqual(command_path, config.command_path)) {
            return config;
        }
    }

    // Try parent paths for inheritance (e.g., ["container"] for ["container", "ls"])
    if (command_path.len > 1) {
        const parent_path = command_path[0 .. command_path.len - 1];
        return findCommandConfig(parent_path, configs);
    }

    return null;
}

/// Compare two command paths for equality
fn pathsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_part, b_part| {
        if (!std.mem.eql(u8, a_part, b_part)) return false;
    }
    return true;
}

/// Check if a module name exists in a list of shared modules
pub fn moduleNameExistsInShared(
    module_name: []const u8,
    shared_modules: []const types.SharedModule,
) bool {
    for (shared_modules) |shared_mod| {
        if (std.mem.eql(u8, module_name, shared_mod.name)) {
            return true;
        }
    }
    return false;
}

// ============================================================================
// TESTS
// ============================================================================

test "exact path match" {
    const config1 = types.CommandConfig{
        .command_path = &.{"discover"},
        .modules = &.{},
    };
    const config2 = types.CommandConfig{
        .command_path = &.{ "container", "ls" },
        .modules = &.{},
    };

    const configs = &[_]types.CommandConfig{ config1, config2 };

    // Test exact match for single-component path
    const found1 = findCommandConfig(&.{"discover"}, configs);
    try std.testing.expect(found1 != null);
    try std.testing.expect(pathsEqual(found1.?.command_path, &.{"discover"}));

    // Test exact match for multi-component path
    const found2 = findCommandConfig(&.{ "container", "ls" }, configs);
    try std.testing.expect(found2 != null);
    try std.testing.expect(pathsEqual(found2.?.command_path, &.{ "container", "ls" }));
}

test "parent path inheritance" {
    const parent_config = types.CommandConfig{
        .command_path = &.{"container"},
        .modules = &.{},
    };

    const configs = &[_]types.CommandConfig{parent_config};

    // Child command should inherit from parent
    const found = findCommandConfig(&.{ "container", "ls" }, configs);
    try std.testing.expect(found != null);
    try std.testing.expect(pathsEqual(found.?.command_path, &.{"container"}));
}

test "no config found returns null" {
    const config = types.CommandConfig{
        .command_path = &.{"discover"},
        .modules = &.{},
    };

    const configs = &[_]types.CommandConfig{config};

    // Different command should not match
    const found = findCommandConfig(&.{"build"}, configs);
    try std.testing.expect(found == null);
}

test "exact match preferred over parent" {
    const parent_config = types.CommandConfig{
        .command_path = &.{"container"},
        .modules = &.{},
    };
    const child_config = types.CommandConfig{
        .command_path = &.{ "container", "ls" },
        .modules = &.{},
    };

    const configs = &[_]types.CommandConfig{ parent_config, child_config };

    // Should find child config, not parent
    const found = findCommandConfig(&.{ "container", "ls" }, configs);
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.command_path.len == 2);
    try std.testing.expect(pathsEqual(found.?.command_path, &.{ "container", "ls" }));
}

test "multiple levels of inheritance" {
    const root_config = types.CommandConfig{
        .command_path = &.{"docker"},
        .modules = &.{},
    };

    const configs = &[_]types.CommandConfig{root_config};

    // Deeply nested command should inherit from root
    const found = findCommandConfig(&.{ "docker", "container", "ls" }, configs);
    try std.testing.expect(found != null);
    try std.testing.expect(pathsEqual(found.?.command_path, &.{"docker"}));
}

test "moduleNameExistsInShared detects conflicts" {
    const shared1 = types.SharedModule{
        .name = "yaml",
        .module = undefined, // Not used in this test
    };
    const shared2 = types.SharedModule{
        .name = "config",
        .module = undefined,
    };

    const shared_modules = &[_]types.SharedModule{ shared1, shared2 };

    try std.testing.expect(moduleNameExistsInShared("yaml", shared_modules));
    try std.testing.expect(moduleNameExistsInShared("config", shared_modules));
    try std.testing.expect(!moduleNameExistsInShared("discovery", shared_modules));
}