//! Build-time utilities module root. The implementation lives in build_utils/:
//!
//! - build_utils/types.zig             - Shared types and structures
//! - build_utils/plugin_system.zig     - Plugin discovery and management
//! - build_utils/command_discovery.zig - Command scanning and validation
//! - build_utils/code_generation.zig   - Registry source code generation
//! - build_utils/module_creation.zig   - Build-time module creation
//! - build_utils/main.zig              - High-level coordination (generate())

pub const main = @import("build_utils/main.zig");
pub const generate = main.generate;
pub const PluginConfig = @import("build_utils/types.zig").ExternalPluginBuildConfig.PluginConfig;

// This file is the build-utils test root (see build.zig core_test_files):
// reference the submodules so their tests are collected.
test {
    _ = @import("build_utils/types.zig");
    _ = @import("build_utils/command_discovery.zig");
    _ = @import("build_utils/code_generation.zig");
    _ = @import("build_utils/main.zig");
    _ = @import("build_utils/module_creation.zig");
}
