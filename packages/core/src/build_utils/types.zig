const std = @import("std");

// ============================================================================
// BUILD-TIME TYPES - Used across build utility modules
//
// Everything here may reference std.Build. The runtime-safe discovery types
// (CommandType/DiscoveredCommand/DiscoveredCommands) live in discovery_types.zig
// and are re-exported below for build-time convenience — runtime code imports
// discovery_types.zig (via command_discovery) and never this file.
// ============================================================================

pub const CommandType = @import("discovery_types.zig").CommandType;
pub const DiscoveredCommand = @import("discovery_types.zig").DiscoveredCommand;
pub const DiscoveredCommands = @import("discovery_types.zig").DiscoveredCommands;
pub const sortedByName = @import("discovery_types.zig").sortedByName;

/// Information about a plugin (local or external)
pub const PluginInfo = struct {
    name: []const u8,
    import_name: []const u8,
    is_local: bool,
    dependency: ?*std.Build.Dependency,
    /// Optional initialization code (from PluginConfig)
    init: ?[]const u8 = null,
    /// For plugins discovered in the *consuming project* (via `plugins_dir`):
    /// the project-relative source path, resolved with `b.path`. Null for
    /// framework built-ins, which live in the zcli package (`zcli_dep.path`).
    project_path: ?[]const u8 = null,
};

/// Shared module that should be available to all commands
pub const SharedModule = struct {
    name: []const u8,
    module: *std.Build.Module,
};

/// Configuration to apply to a command module for native dependencies
pub const CommandModuleConfig = struct {
    /// C source files needed by this module
    c_sources: ?[]const []const u8 = null,

    /// C compiler flags
    c_flags: ?[]const []const u8 = null,

    /// C++ source files needed by this module
    cpp_sources: ?[]const []const u8 = null,

    /// C++ compiler flags
    cpp_flags: ?[]const []const u8 = null,

    /// Include paths for C/C++ headers
    include_paths: ?[]const []const u8 = null,

    /// System libraries to link (e.g., "curl", "sqlite3")
    system_libs: ?[]const []const u8 = null,

    /// Whether to link libc (default: auto-detect based on c_sources/system_libs)
    link_libc: ?bool = null,

    /// Whether to link libc++ (default: auto-detect based on cpp_sources)
    link_libcpp: ?bool = null,
};

/// Per-command module with optional build configuration
pub const CommandModule = struct {
    /// Module name for import in the command
    name: []const u8,

    /// The module itself
    module: *std.Build.Module,

    /// Optional build configuration to apply to the command module
    config: ?CommandModuleConfig = null,
};

/// Configuration for a specific command with per-command modules
pub const CommandConfig = struct {
    /// Command path (e.g., &.{"container", "ls"} for "container ls" command)
    command_path: []const []const u8,

    /// Modules specific to this command with their configurations
    modules: []const CommandModule = &.{},
};

/// Enhanced build configuration for plugin support
pub const BuildConfig = struct {
    commands_dir: []const u8,
    plugins_dir: ?[]const u8,
    plugins: ?[]const PluginInfo,
    shared_modules: ?[]const SharedModule = null,
    command_configs: ?[]const CommandConfig = null,
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
    /// Build date stamped into the registry as `YYYY-MM-DD`, used for the man
    /// page `.TH` date. Fixed at build time (honoring `SOURCE_DATE_EPOCH`) so
    /// regenerating docs is reproducible. Empty only for internal test
    /// fixtures, which never run the doc generator.
    build_date: []const u8 = "",
};

/// The native libraries a plugin's backend needs, expressed as a hook the
/// build applies to a module for a given `target`. See `linkSecretsBackend`
/// for the shape a plugin fills in, and `PluginConfig.link` for how it's wired.
pub const PluginLinkFn = *const fn (module: *std.Build.Module, target: std.Target) void;

/// Link the native libraries the `zcli_secrets` plugin's backend needs for
/// `target`. macOS: Security + CoreFoundation frameworks. Windows: advapi32.
/// Linux links **nothing**: its backend reaches the Secret Service (via
/// `secret-tool`) or `pass` by shelling out at runtime, not by linking, so a
/// Linux build stays static and works on musl too (ADR-0010). Any other OS has
/// no secure backend — registering the plugin there is a compile error in the
/// plugin source. Exposed so the plugin's own test targets can link exactly the
/// same way a registered app does.
///
/// This is a `PluginLinkFn`: `builtin(.secrets, ...)` wires it onto the plugin
/// config's `.link` field, so `generate()` applies it via the general
/// plugin-declared mechanism rather than a name special-case.
pub fn linkSecretsBackend(module: *std.Build.Module, target: std.Target) void {
    switch (target.os.tag) {
        .macos => {
            module.linkFramework("Security", .{});
            module.linkFramework("CoreFoundation", .{});
        },
        // Linux shells out (secret-tool / pass) — no library to link, and no
        // musl incompatibility.
        .linux => {},
        .windows => {
            module.linkSystemLibrary("advapi32", .{});
        },
        else => {},
    }
}

/// Plugin configuration. A plugin is registered one of two ways, mutually
/// exclusive:
///
///   - **built-in** (`path` set): a plugin that ships inside the zcli package.
///     Use `builtin()` — it fills in `name`/`path`/`link` for you.
///   - **external package** (`dependency` set): a third-party plugin shipped
///     as its own Zig package. The consumer does `b.dependency("my_plugin",
///     .{...})` in build.zig and passes the result here; the package must
///     expose a module named `plugin` (its entry point). `generate()` injects
///     the consumer's `zcli` import into it, so the plugin package needs no
///     zcli dependency of its own.
///
/// (A *project-local* plugin — one living in the consuming project's own
/// source tree — is not registered here at all; it's auto-discovered via
/// `GenerateConfig.plugins_dir`.)
pub const PluginConfig = struct {
    name: []const u8,
    /// Source path of a built-in plugin *within the zcli package* (e.g.
    /// "packages/core/src/plugins/zcli_help"). Set by `builtin()`. Mutually
    /// exclusive with `dependency`; exactly one must be set.
    path: ?[]const u8 = null,
    /// A third-party plugin shipped as its own Zig package: the consumer's
    /// `b.dependency("my_plugin", .{...})`. Mutually exclusive with `path`.
    dependency: ?*std.Build.Dependency = null,
    /// Optional native-link hook. When a plugin's backend needs system
    /// libraries or frameworks, it declares them here; `generate()` applies the
    /// hook to the executable's root module exactly when the plugin is
    /// registered — so a CLI that doesn't opt in stays a static single binary.
    /// `builtin(.secrets, ...)` sets this to `linkSecretsBackend`; an external
    /// plugin package can export its own `PluginLinkFn` and pass it here.
    link: ?PluginLinkFn = null,
    /// Optional initialization code to call on the plugin
    /// Example: ".init(.{ .repo = \"user/repo\", .command_name = \"upgrade\" })"
    /// Will generate: const plugin = @import("name")<init_code>;
    init: ?[]const u8 = null,
};

/// Built-in plugins that ship with zcli. Enable one with `builtin(.help, .{})`
/// instead of spelling out its name and path by hand.
pub const Builtin = enum {
    help,
    version,
    not_found,
    completions,
    config,
    secrets,
    github_upgrade,

    /// Registration name, e.g. `zcli_help`.
    pub fn pluginName(comptime self: Builtin) []const u8 {
        return "zcli_" ++ @tagName(self);
    }

    /// Path to the plugin's source within the zcli package.
    pub fn pluginPath(comptime self: Builtin) []const u8 {
        return "packages/core/src/plugins/zcli_" ++ @tagName(self);
    }

    /// The native-link hook a built-in needs, or null if it links nothing.
    /// Only `secrets` reaches an OS keychain, so only it declares a hook;
    /// `builtin()` copies this onto the plugin config's `.link` field.
    pub fn linkHook(comptime self: Builtin) ?PluginLinkFn {
        return switch (self) {
            .secrets => &linkSecretsBackend,
            else => null,
        };
    }
};

/// Register a built-in plugin in a `generate()` plugins list. Pass `.{}` as the
/// config for plugins that take none:
///
/// ```zig
/// .plugins = &.{
///     zcli.builtin(.help, .{}),
///     zcli.builtin(.github_upgrade, .{ .repo = "user/repo", .command_name = "upgrade" }),
///     // A third-party plugin shipped as its own Zig package (see PluginConfig):
///     .{ .name = "my_plugin", .dependency = b.dependency("my_plugin", .{ .target = target, .optimize = optimize }) },
/// },
/// // A plugin living in the consuming project's own tree is NOT listed here —
/// // it's auto-discovered by dropping it under `.plugins_dir` (ADR-0006).
/// ```
///
/// The config struct is rendered to the plugin's `.init(.{ ... })` call at
/// comptime, so every plugins-list entry is a plain `PluginConfig` and the
/// whole `generate()` config stays an ordinary typed struct.
pub fn builtin(comptime tag: Builtin, comptime config: anytype) PluginConfig {
    return .{
        .name = tag.pluginName(),
        .path = tag.pluginPath(),
        .link = tag.linkHook(),
        .init = comptime initString(config),
    };
}

/// Comptime-render a plugin config struct as the `.init(.{ ... })` code the
/// generated registry applies to the plugin. An empty config means no init
/// call at all (null).
fn initString(comptime config: anytype) ?[]const u8 {
    const T = @TypeOf(config);
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields,
        else => @compileError("plugin config must be a struct, got: " ++ @typeName(T)),
    };
    if (fields.len == 0) return null;

    comptime var out: []const u8 = ".init(.{";
    inline for (fields, 0..) |field, i| {
        if (i > 0) out = out ++ ", ";
        out = out ++ "." ++ field.name ++ " = ";
        const value = @field(config, field.name);
        out = out ++ switch (@typeInfo(field.type)) {
            .pointer => |ptr_info| blk: {
                const is_string = switch (@typeInfo(ptr_info.child)) {
                    .int => |int_info| int_info.bits == 8 and int_info.signedness == .unsigned,
                    .array => |arr_info| arr_info.child == u8,
                    else => false,
                };
                if (!is_string) @compileError("Unsupported pointer type in plugin config: " ++ @typeName(field.type));
                break :blk std.fmt.comptimePrint("\"{s}\"", .{value});
            },
            .bool => std.fmt.comptimePrint("{}", .{value}),
            .int, .comptime_int => std.fmt.comptimePrint("{d}", .{value}),
            else => @compileError("Unsupported type in plugin config: " ++ @typeName(field.type)),
        };
    }
    return out ++ "})";
}

/// Configuration for `generate()` — the project-facing build entry point.
/// `app_version` is deliberately absent: the version always comes from the
/// project's build.zig.zon (single source of truth).
pub const GenerateConfig = struct {
    commands_dir: []const u8,
    app_name: []const u8,
    app_description: []const u8,
    /// Explicitly registered plugins (see `builtin()` for the shipped ones).
    /// Optional: a project may rely solely on `plugins_dir` discovery.
    plugins: []const PluginConfig = &.{},
    /// Directory scanned for the consuming project's local plugins (ADR-0006).
    /// Null → no local scan; a missing directory is harmless.
    plugins_dir: ?[]const u8 = null,
    shared_modules: ?[]const SharedModule = null,
    command_configs: ?[]const CommandConfig = null,
};

/// Configuration for `generateDocs()`.
pub const DocsConfig = struct {
    /// Formats to generate; each gets its own subdirectory under `output_dir`.
    formats: []const []const u8 = &.{"markdown"},
    output_dir: []const u8 = "docs",
};

/// Configuration for `addCommandTests()` (the scaffolded-project unit-test
/// idiom: each command file compiled as its own test root).
pub const CommandTestsConfig = struct {
    commands_dir: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The same list passed to `generate()`, so command imports resolve
    /// identically under test.
    shared_modules: []const SharedModule = &.{},
    /// The same `plugins_dir` passed to `generate()`, so the stub Context
    /// includes the project's local plugins.
    plugins_dir: ?[]const u8 = null,
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "builtin(): produces a path-based PluginConfig, no dependency" {
    const cfg = builtin(.help, .{});
    try testing.expectEqualStrings("zcli_help", cfg.name);
    try testing.expectEqualStrings("packages/core/src/plugins/zcli_help", cfg.path.?);
    try testing.expectEqual(@as(?*std.Build.Dependency, null), cfg.dependency);
    // help links nothing native.
    try testing.expectEqual(@as(?PluginLinkFn, null), cfg.link);
}

test "builtin(.secrets): wires linkSecretsBackend onto .link" {
    const cfg = builtin(.secrets, .{});
    try testing.expectEqualStrings("zcli_secrets", cfg.name);
    // The native-link needs are declared by the plugin's config, not by a
    // name special-case in generate(). Only secrets declares a hook.
    try testing.expect(cfg.link != null);
    try testing.expectEqual(@as(PluginLinkFn, &linkSecretsBackend), cfg.link.?);
}

test "Builtin.linkHook: only secrets declares a native-link hook" {
    inline for (@typeInfo(Builtin).@"enum".fields) |field| {
        const tag = @field(Builtin, field.name);
        const hook = comptime tag.linkHook();
        if (tag == .secrets) {
            try testing.expect(hook != null);
        } else {
            try testing.expectEqual(@as(?PluginLinkFn, null), hook);
        }
    }
}

test "PluginConfig: an external-package plugin sets .dependency, not .path" {
    // The value a consumer writes for a third-party plugin shipped as a Zig
    // package: name + dependency, no path. (A real *std.Build.Dependency can't
    // be built in a unit test, so this exercises the field shape/defaults that
    // generate() dispatches on; the end-to-end wiring is covered by the
    // ext-plugin example under build-examples.)
    const cfg = PluginConfig{ .name = "greet", .path = null };
    try testing.expectEqualStrings("greet", cfg.name);
    try testing.expectEqual(@as(?[]const u8, null), cfg.path);
    try testing.expectEqual(@as(?*std.Build.Dependency, null), cfg.dependency);
    try testing.expectEqual(@as(?PluginLinkFn, null), cfg.link);
}
