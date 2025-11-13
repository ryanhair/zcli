const std = @import("std");
const types = @import("types.zig");

/// Apply CommandModuleConfig to a command module
/// This adds C/C++ sources, include paths, system libraries, etc. to the module
pub fn applyCommandModuleConfig(
    b: *std.Build,
    cmd_module: *std.Build.Module,
    config: types.CommandModuleConfig,
) void {
    // Auto-detect libc linking if not explicitly specified
    const should_link_libc = config.link_libc orelse (config.c_sources != null or config.system_libs != null);
    if (should_link_libc) {
        cmd_module.linkLibC();
    }

    // Auto-detect libc++ linking if not explicitly specified
    const should_link_libcpp = config.link_libcpp orelse (config.cpp_sources != null);
    if (should_link_libcpp) {
        cmd_module.linkLibCpp();
    }

    // Add include paths
    if (config.include_paths) |paths| {
        for (paths) |path| {
            cmd_module.addIncludePath(b.path(path));
        }
    }

    // Add C source files
    if (config.c_sources) |sources| {
        const flags = config.c_flags orelse &.{};
        for (sources) |source| {
            cmd_module.addCSourceFile(.{
                .file = b.path(source),
                .flags = flags,
            });
        }
    }

    // Add C++ source files
    if (config.cpp_sources) |sources| {
        const flags = config.cpp_flags orelse &.{};
        for (sources) |source| {
            cmd_module.addCSourceFile(.{
                .file = b.path(source),
                .flags = flags,
            });
        }
    }

    // Link system libraries
    if (config.system_libs) |libs| {
        for (libs) |lib| {
            cmd_module.linkSystemLibrary(lib);
        }
    }
}