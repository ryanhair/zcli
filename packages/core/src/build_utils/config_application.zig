const std = @import("std");
const types = @import("types.zig");

/// Collect and apply all C/C++ dependencies from command_configs to the executable
/// Since modules don't support C linking in Zig, all C dependencies must be applied
/// to the final executable that links everything together
pub fn applyCommandConfigsToExecutable(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    command_configs: []const types.CommandConfig,
) void {
    var needs_libc = false;
    var needs_libcpp = false;

    // Track added sources and includes to avoid duplicates
    var added_c_sources = std.StringHashMap(void).init(b.allocator);
    defer added_c_sources.deinit();
    var added_cpp_sources = std.StringHashMap(void).init(b.allocator);
    defer added_cpp_sources.deinit();
    var added_includes = std.StringHashMap(void).init(b.allocator);
    defer added_includes.deinit();
    var added_sys_libs = std.StringHashMap(void).init(b.allocator);
    defer added_sys_libs.deinit();

    // Process all command configs
    for (command_configs) |cmd_config| {
        for (cmd_config.modules) |module_config| {
            if (module_config.config) |config| {
                // Auto-detect libc linking
                if (config.link_libc orelse (config.c_sources != null or config.system_libs != null)) {
                    needs_libc = true;
                }

                // Auto-detect libc++ linking
                if (config.link_libcpp orelse (config.cpp_sources != null)) {
                    needs_libcpp = true;
                }

                // Add include paths (deduplicate)
                if (config.include_paths) |paths| {
                    for (paths) |path| {
                        const result = added_includes.getOrPut(path) catch unreachable;
                        if (!result.found_existing) {
                            exe.addIncludePath(b.path(path));
                        }
                    }
                }

                // Add C source files (deduplicate)
                if (config.c_sources) |sources| {
                    const flags = config.c_flags orelse &.{};
                    for (sources) |source| {
                        const result = added_c_sources.getOrPut(source) catch unreachable;
                        if (!result.found_existing) {
                            exe.addCSourceFile(.{
                                .file = b.path(source),
                                .flags = flags,
                            });
                        }
                    }
                }

                // Add C++ source files (deduplicate)
                if (config.cpp_sources) |sources| {
                    const flags = config.cpp_flags orelse &.{};
                    for (sources) |source| {
                        const result = added_cpp_sources.getOrPut(source) catch unreachable;
                        if (!result.found_existing) {
                            exe.addCSourceFile(.{
                                .file = b.path(source),
                                .flags = flags,
                            });
                        }
                    }
                }

                // Link system libraries (deduplicate)
                if (config.system_libs) |libs| {
                    for (libs) |lib| {
                        const result = added_sys_libs.getOrPut(lib) catch unreachable;
                        if (!result.found_existing) {
                            exe.linkSystemLibrary(lib);
                        }
                    }
                }
            }
        }
    }

    // Apply library linking at the end
    if (needs_libc) {
        exe.linkLibC();
    }
    if (needs_libcpp) {
        exe.linkLibCpp();
    }
}