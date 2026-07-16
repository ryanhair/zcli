const std = @import("std");
const types = @import("types.zig");

/// Whether a module config implies libc must be linked. Explicit `link_libc`
/// wins; otherwise it is auto-detected from the presence of C sources or system
/// libraries. Pure decision rule, unit-tested below — kept out of the
/// std.Build-graph plumbing so a regression fails a targeted test.
fn needsLibc(config: types.CommandModuleConfig) bool {
    return config.link_libc orelse (config.c_sources != null or config.system_libs != null);
}

/// Whether a module config implies libc++ must be linked. Explicit
/// `link_libcpp` wins; otherwise auto-detected from the presence of C++ sources.
fn needsLibcpp(config: types.CommandModuleConfig) bool {
    return config.link_libcpp orelse (config.cpp_sources != null);
}

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
                // Auto-detect libc / libc++ linking (see needsLibc/needsLibcpp)
                if (needsLibc(config)) needs_libc = true;
                if (needsLibcpp(config)) needs_libcpp = true;

                // Add include paths (deduplicate)
                if (config.include_paths) |paths| {
                    for (paths) |path| {
                        const result = added_includes.getOrPut(path) catch unreachable;
                        if (!result.found_existing) {
                            exe.root_module.addIncludePath(b.path(path));
                        }
                    }
                }

                // Add C source files (deduplicate)
                if (config.c_sources) |sources| {
                    const flags = config.c_flags orelse &.{};
                    for (sources) |source| {
                        const result = added_c_sources.getOrPut(source) catch unreachable;
                        if (!result.found_existing) {
                            exe.root_module.addCSourceFile(.{
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
                            exe.root_module.addCSourceFile(.{
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
                            exe.root_module.linkSystemLibrary(lib, .{});
                        }
                    }
                }
            }
        }
    }

    // Apply library linking at the end
    if (needs_libc) {
        exe.root_module.link_libc = true;
    }
    if (needs_libcpp) {
        exe.root_module.link_libcpp = true;
    }
}

// ============================================================================
// Tests — the pure libc/libc++ auto-detection rules. The apply loop above is
// std.Build-graph plumbing, but the merge decision it makes per module is pure.
// ============================================================================

const testing = std.testing;

test "needsLibc: nothing set is false" {
    try testing.expect(!needsLibc(.{}));
}

test "needsLibc: auto-detected from C sources and system libs" {
    try testing.expect(needsLibc(.{ .c_sources = &.{"foo.c"} }));
    try testing.expect(needsLibc(.{ .system_libs = &.{"curl"} }));
}

test "needsLibc: explicit link_libc overrides auto-detection both ways" {
    // Explicit false wins even though C sources would auto-detect true.
    try testing.expect(!needsLibc(.{ .link_libc = false, .c_sources = &.{"foo.c"} }));
    // Explicit true wins with nothing else set.
    try testing.expect(needsLibc(.{ .link_libc = true }));
}

test "needsLibc: C++ sources alone do not pull in libc" {
    try testing.expect(!needsLibc(.{ .cpp_sources = &.{"foo.cpp"} }));
}

test "needsLibcpp: auto-detected only from C++ sources" {
    try testing.expect(!needsLibcpp(.{}));
    try testing.expect(needsLibcpp(.{ .cpp_sources = &.{"foo.cpp"} }));
    try testing.expect(!needsLibcpp(.{ .c_sources = &.{"foo.c"} }));
}

test "needsLibcpp: explicit link_libcpp overrides auto-detection both ways" {
    try testing.expect(!needsLibcpp(.{ .link_libcpp = false, .cpp_sources = &.{"foo.cpp"} }));
    try testing.expect(needsLibcpp(.{ .link_libcpp = true }));
}
