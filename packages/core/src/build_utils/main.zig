const std = @import("std");
const logging = @import("../logging.zig");
const types = @import("types.zig");
const module_creation = @import("module_creation.zig");
const plugin_system = @import("plugin_system.zig");
const command_discovery = @import("command_discovery.zig");
const code_generation = @import("code_generation.zig");

const CommandInfo = types.CommandInfo;
const BuildConfig = types.BuildConfig;
const DiscoveredCommands = types.DiscoveredCommands;
const ExternalPluginBuildConfig = types.ExternalPluginBuildConfig;

/// Link the native libraries the `zcli_secrets` plugin's backend needs for
/// `target`. macOS: Security + CoreFoundation frameworks. Linux: libsecret-1 +
/// glib-2.0 (over libc). Windows: advapi32. Any other OS has no secure backend —
/// registering the plugin there is a compile error in the plugin source — so
/// nothing is linked. Exposed so the plugin's own test targets can link exactly
/// the same way a registered app does.
pub fn linkSecretsBackend(module: *std.Build.Module, target: std.Target) void {
    switch (target.os.tag) {
        .macos => {
            module.linkFramework("Security", .{});
            module.linkFramework("CoreFoundation", .{});
        },
        .linux => {
            // libsecret/glib are glibc-based, so a musl target — zcli's flagship
            // static-single-binary case — cannot link them. Fail with a legible
            // message instead of a cryptic linker/pkg-config error, mirroring the
            // plugin's own unsupported-OS @compileError.
            if (target.abi.isMusl()) std.debug.panic(
                "zcli_secrets: the Linux Secret Service backend links libsecret " ++
                    "(glibc), which is incompatible with a musl target ({s}). Build " ++
                    "with a gnu ABI (e.g. -Dtarget=x86_64-linux-gnu), or do not " ++
                    "register the plugin for musl.",
                .{@tagName(target.abi)},
            );
            module.link_libc = true;
            module.linkSystemLibrary("secret-1", .{});
            module.linkSystemLibrary("glib-2.0", .{});
        },
        .windows => {
            module.linkSystemLibrary("advapi32", .{});
        },
        else => {},
    }
}

// ============================================================================
// VERSION MANAGEMENT - Read version from build.zig.zon
// ============================================================================

/// Read version from the project's build.zig.zon file
fn readVersionFromZon(b: *std.Build) []const u8 {
    // Read the file from build root
    const content = b.build_root.handle.readFileAlloc(b.graph.io, "build.zig.zon", b.allocator, .limited(1024 * 1024)) catch |err| {
        logging.logBuildWarning("Could not read build.zig.zon, using default version 0.0.0: {any}", .{err});
        return "0.0.0";
    };
    // Don't defer free - we're returning a slice of this content

    // Parse the .version = "x.y.z" line
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, ".version")) {
            // Extract version string between quotes
            if (std.mem.indexOf(u8, trimmed, "\"")) |start| {
                const after_first = trimmed[start + 1 ..];
                if (std.mem.indexOf(u8, after_first, "\"")) |end| {
                    // Duplicate the version string so we can free the content
                    const version = b.allocator.dupe(u8, after_first[0..end]) catch "0.0.0";
                    b.allocator.free(content);
                    return version;
                }
            }
        }
    }

    b.allocator.free(content);
    logging.logBuildWarning("Could not parse version from build.zig.zon, using default version 0.0.0", .{});
    return "0.0.0";
}

// ============================================================================
// HIGH-LEVEL BUILD FUNCTIONS - Main entry points for build.zig
// ============================================================================

/// Build function with plugin support that accepts zcli module
fn buildWithPlugins(b: *std.Build, exe: *std.Build.Step.Compile, zcli_dep: *std.Build.Dependency, zcli_module: *std.Build.Module, config: BuildConfig) *std.Build.Module {
    // Get target and optimize from executable
    const target = exe.root_module.resolved_target orelse b.graph.host;
    const optimize = exe.root_module.optimize orelse .Debug;

    // Apply C/C++ dependencies FIRST, before any modules are created
    // This ensures include paths are available when modules use @cImport
    const config_application = @import("config_application.zig");
    const command_configs = config.command_configs orelse &.{};
    config_application.applyCommandConfigsToExecutable(b, exe, command_configs);

    // 1. Discover local plugins
    const local_plugins = if (config.plugins_dir) |dir|
        plugin_system.scanLocalPlugins(b, dir) catch &.{}
    else
        &.{};

    // 2. Combine with external plugins
    const all_plugins = plugin_system.combinePlugins(b, local_plugins, config.plugins orelse &.{});

    // 3. Note: Plugin modules are now added directly in module_creation.addPluginModulesToRegistry
    //    using zcli_dep.path() to ensure correct resolution

    // 4. Generate plugin-enhanced registry
    const registry_module = generatePluginRegistry(b, exe, target, optimize, zcli_dep, zcli_module, config, all_plugins);

    return registry_module;
}

/// Generate registry with plugin support
fn generatePluginRegistry(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zcli_dep: *std.Build.Dependency,
    zcli_module: *std.Build.Module,
    config: BuildConfig,
    plugins: []const types.PluginInfo,
) *std.Build.Module {
    _ = exe;
    _ = target; // Will be used for plugin compilation
    _ = optimize; // Will be used for plugin compilation

    // Discover all commands at build time (same as before)
    var discovered_commands = command_discovery.discoverCommands(b, config.commands_dir) catch |err| {
        // Same error handling as before
        switch (err) {
            error.InvalidPath => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Invalid commands directory path.\nPath contains '..' which is not allowed for security reasons", "Please use a relative path without '..' or an absolute path");
            },
            error.FileNotFound => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Commands directory not found", "Please ensure the directory exists and the path is correct");
            },
            error.AccessDenied => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Access denied to commands directory", "Please check file permissions for the directory");
            },
            error.OutOfMemory => {
                logging.buildError("Build Error", "memory allocation", "Out of memory during command discovery", "Try reducing the number of commands or increasing available memory");
            },
            else => {
                logging.buildError("Command Discovery Error", config.commands_dir, "Failed to discover commands", "Check the command directory structure and file permissions");
                std.debug.print("Error details: {any}\n", .{err});
            },
        }
        std.process.exit(1);
    };
    defer discovered_commands.deinit();

    // Generate plugin-enhanced registry source code
    const registry_source = code_generation.generateComptimeRegistrySource(b.allocator, discovered_commands, config, plugins) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                logging.registryGenerationOutOfMemory();
            },
            else => {
                logging.logBuildWarning("Registry generation failed: {any}", .{err});
            },
        }
        std.process.exit(1);
    };
    defer b.allocator.free(registry_source);

    // Create a write file step to write the generated source
    const write_registry = b.addWriteFiles();
    const registry_file = write_registry.add("zcli_generated.zig", registry_source);

    // Create a module from the generated file
    const registry_module = b.addModule("command_registry", .{
        .root_source_file = registry_file,
    });

    // Add zcli import to registry module
    registry_module.addImport("zcli", zcli_module);

    // Create modules for all discovered command files dynamically
    const shared_modules = config.shared_modules orelse &.{};
    const command_configs = config.command_configs orelse &.{};
    module_creation.createDiscoveredModules(b, registry_module, zcli_module, discovered_commands, config.commands_dir, shared_modules, command_configs);

    // Add plugin imports to registry module
    module_creation.addPluginModulesToRegistry(b, registry_module, zcli_dep, zcli_module, plugins);

    return registry_module;
}

/// Build function for external plugins with explicit plugin configuration
pub fn generate(b: *std.Build, exe: *std.Build.Step.Compile, zcli_dep: *std.Build.Dependency, zcli_module: *std.Build.Module, config: anytype) *std.Build.Module {
    // Validate required fields
    if (!@hasField(@TypeOf(config), "commands_dir")) @compileError("config must have 'commands_dir' field");
    if (!@hasField(@TypeOf(config), "app_name")) @compileError("config must have 'app_name' field");
    if (!@hasField(@TypeOf(config), "app_description")) @compileError("config must have 'app_description' field");
    if (!@hasField(@TypeOf(config), "plugins")) @compileError("config must have 'plugins' field");

    // Always read version from build.zig.zon - single source of truth
    const app_version = readVersionFromZon(b);

    // Convert plugin configs to PluginInfo array
    var plugins = std.ArrayList(types.PluginInfo).empty;
    defer plugins.deinit(b.allocator);

    inline for (config.plugins) |plugin_config| {
        // Validate plugin config has required fields
        if (!@hasField(@TypeOf(plugin_config), "name")) @compileError("plugin config must have 'name' field");
        if (!@hasField(@TypeOf(plugin_config), "path")) @compileError("plugin config must have 'path' field");

        // Plugin path is relative to the zcli package, e.g. "src/plugins/zcli_help"
        // Just append "/plugin" to get the full import path
        const plugin_import_path = std.fmt.allocPrint(b.allocator, "{s}/plugin", .{plugin_config.path}) catch {
            logging.buildError("Plugin System", "memory allocation", "Failed to allocate memory for plugin import name", "Out of memory while processing external plugin. Reduce number of plugins or increase available memory");
            std.debug.print("Plugin name: {s}\n", .{plugin_config.name});
            std.process.exit(1);
        };

        // Check if plugin has a non-empty config and generate init code.
        // An empty config (e.g. `builtin(.help, .{})`) means no `.init(...)` call.
        const has_config = @hasField(@TypeOf(plugin_config), "config") and
            @typeInfo(@TypeOf(plugin_config.config)).@"struct".fields.len > 0;
        const init_code = if (has_config)
            configToInitString(b.allocator, plugin_config.config)
        else
            null;

        const plugin_info = types.PluginInfo{
            .name = plugin_config.name,
            .import_name = plugin_import_path,
            .is_local = true, // Plugins are now local paths within the zcli package
            .dependency = null, // No separate dependency needed
            .init = init_code,
        };
        plugins.append(b.allocator, plugin_info) catch {
            logging.buildError("Plugin System", "memory allocation", "Failed to add plugin to plugin list", "Out of memory while adding external plugin. Reduce number of plugins or increase available memory");
            std.debug.print("Plugin name: {s}\n", .{plugin_config.name});
            std.process.exit(1);
        };
    }

    // Opt-in native linking. The secrets plugin's native backends call into an
    // OS keychain, which requires dynamic linking. We add each platform's
    // libraries to the executable ONLY when the secrets plugin is registered —
    // so a CLI that does not opt in stays a static, libc-free single binary.
    // This is the build half of ADR-0003's opt-in guarantee (the source half is
    // the compile-time backend selection in the plugin). Registering the plugin
    // for an unsupported OS is a compile error in the plugin source — there is
    // no insecure file fallback — so `linkSecretsBackend` links nothing there.
    inline for (config.plugins) |plugin_config| {
        if (std.mem.eql(u8, plugin_config.name, "zcli_secrets")) {
            linkSecretsBackend(exe.root_module, exe.rootModuleTarget());
        }
    }

    // Create BuildConfig
    const build_config = BuildConfig{
        .commands_dir = config.commands_dir,
        // Honor a caller-provided plugins_dir so local plugins under it are
        // convention-discovered (ADR-0006). Optional: absent → no local scan.
        .plugins_dir = if (@hasField(@TypeOf(config), "plugins_dir")) config.plugins_dir else null,
        .plugins = plugins.items,
        .shared_modules = if (@hasField(@TypeOf(config), "shared_modules")) config.shared_modules else null,
        .command_configs = if (@hasField(@TypeOf(config), "command_configs")) config.command_configs else null,
        .app_name = config.app_name,
        .app_version = app_version,
        .app_description = config.app_description,
    };

    return buildWithPlugins(b, exe, zcli_dep, zcli_module, build_config);
}

/// Generate documentation from command metadata during the build.
///
/// Docs are generated automatically on every `zig build` and also
/// available via `zig build docs`. Output goes to `output_dir`.
///
/// ```zig
/// // Single format (default: markdown)
/// zcli.generateDocs(b, cmd_registry, zcli_dep, zcli_module, .{});
///
/// // Multiple formats — each gets its own subdirectory
/// zcli.generateDocs(b, cmd_registry, zcli_dep, zcli_module, .{
///     .formats = &.{ "markdown", "man" },
///     .output_dir = "docs",
/// });
/// ```
pub fn generateDocs(b: *std.Build, registry_module: *std.Build.Module, zcli_dep: *std.Build.Dependency, zcli_module: *std.Build.Module, comptime config: anytype) void {
    const formats: []const []const u8 = if (@hasField(@TypeOf(config), "formats"))
        config.formats
    else if (@hasField(@TypeOf(config), "format"))
        &.{config.format}
    else
        &.{"markdown"};
    const output_dir = if (@hasField(@TypeOf(config), "output_dir")) config.output_dir else "docs";

    const doc_exe = b.addExecutable(.{
        .name = "zcli-doc-gen",
        .root_module = b.createModule(.{
            .root_source_file = zcli_dep.path("packages/core/src/doc_gen_main.zig"),
            .target = b.graph.host,
        }),
    });
    doc_exe.root_module.addImport("command_registry", registry_module);
    doc_exe.root_module.addImport("zcli", zcli_module);

    const run = b.addRunArtifact(doc_exe);
    run.addArg(output_dir);
    inline for (formats) |fmt| {
        run.addArg(fmt);
    }

    // Run on every `zig build`
    b.getInstallStep().dependOn(&run.step);

    // Also available as explicit `zig build docs`
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&run.step);
}

/// Convert a comptime config struct to an init string
fn configToInitString(allocator: std.mem.Allocator, comptime config: anytype) []const u8 {
    const T = @TypeOf(config);
    const type_info = @typeInfo(T);

    const fields = switch (type_info) {
        .@"struct" => |s| s.fields,
        else => @compileError("Plugin config must be a struct, got: " ++ @typeName(T)),
    };

    var result = std.ArrayList(u8).empty;

    result.appendSlice(allocator, ".init(.{") catch unreachable;

    inline for (fields, 0..) |field, i| {
        if (i > 0) result.appendSlice(allocator, ", ") catch unreachable;

        const prefix = std.fmt.allocPrint(allocator, ".{s} = ", .{field.name}) catch unreachable;
        result.appendSlice(allocator, prefix) catch unreachable;
        allocator.free(prefix);

        const value = @field(config, field.name);
        switch (@typeInfo(field.type)) {
            .pointer => |ptr_info| {
                // Handle string slices and array pointers
                const child_info = @typeInfo(ptr_info.child);
                const is_string = switch (child_info) {
                    .int => |int_info| int_info.bits == 8 and int_info.signedness == .unsigned,
                    .array => |arr_info| arr_info.child == u8,
                    else => false,
                };

                if (is_string) {
                    const s = std.fmt.allocPrint(allocator, "\"{s}\"", .{value}) catch unreachable;
                    result.appendSlice(allocator, s) catch unreachable;
                    allocator.free(s);
                } else {
                    @compileError("Unsupported pointer type in plugin config: " ++ @typeName(field.type));
                }
            },
            .bool => {
                const s = std.fmt.allocPrint(allocator, "{}", .{value}) catch unreachable;
                result.appendSlice(allocator, s) catch unreachable;
                allocator.free(s);
            },
            .int, .comptime_int => {
                const s = std.fmt.allocPrint(allocator, "{d}", .{value}) catch unreachable;
                result.appendSlice(allocator, s) catch unreachable;
                allocator.free(s);
            },
            else => {
                @compileError("Unsupported type in plugin config: " ++ @typeName(field.type));
            },
        }
    }

    result.appendSlice(allocator, "})") catch unreachable;

    return result.toOwnedSlice(allocator) catch unreachable;
}
