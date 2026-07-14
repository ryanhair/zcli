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

/// Plugin configuration for external plugins
pub const PluginConfig = struct {
    name: []const u8,
    path: []const u8,
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
};

/// Register a built-in plugin in a `generate()` plugins list. Pass `.{}` as the
/// config for plugins that take none:
///
/// ```zig
/// .plugins = &.{
///     zcli.builtin(.help, .{}),
///     zcli.builtin(.github_upgrade, .{ .repo = "user/repo", .command_name = "upgrade" }),
///     .{ .name = "my_plugin", .path = "src/plugins/my_plugin" }, // handrolled
/// },
/// ```
///
/// The config struct is rendered to the plugin's `.init(.{ ... })` call at
/// comptime, so every plugins-list entry is a plain `PluginConfig` and the
/// whole `generate()` config stays an ordinary typed struct.
pub fn builtin(comptime tag: Builtin, comptime config: anytype) PluginConfig {
    return .{
        .name = tag.pluginName(),
        .path = tag.pluginPath(),
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
        out = out ++ "." ++ field.name ++ " = " ++ renderConfigValue(@field(config, field.name));
    }
    return out ++ "})";
}

/// Comptime-render a single plugin config value as Zig source text.
///
/// Plugin config structs are handed to `builtin()` as `anytype`, so a field
/// whose value is a union-typed setting (e.g. `github_upgrade`'s
/// `verification: union(enum) { minisign: []const u8, checksum_only }`) never
/// gets its destination type: the caller writes `.verification = .{ .minisign
/// = "KEY" }` or `.verification = .checksum_only`, and without a known result
/// type Zig infers those as, respectively, an anonymous one-field struct and a
/// bare enum literal — not the union they'll eventually coerce to. This
/// function reproduces the caller's literal source text rather than the
/// union's shape, so it recurses into nested struct literals and renders
/// enum literals as bare `.tag`. The coercion to the real union type happens
/// later, when the generated code calls the plugin's `init(config: Config)`
/// with a known destination type.
fn renderConfigValue(comptime value: anytype) []const u8 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |ptr_info| blk: {
            const is_string = switch (@typeInfo(ptr_info.child)) {
                .int => |int_info| int_info.bits == 8 and int_info.signedness == .unsigned,
                .array => |arr_info| arr_info.child == u8,
                else => false,
            };
            if (!is_string) @compileError("Unsupported pointer type in plugin config: " ++ @typeName(T));
            break :blk std.fmt.comptimePrint("\"{s}\"", .{value});
        },
        .bool => std.fmt.comptimePrint("{}", .{value}),
        .int, .comptime_int => std.fmt.comptimePrint("{d}", .{value}),
        // A tag with no payload, e.g. `.verification = .checksum_only`.
        .enum_literal => "." ++ @tagName(value),
        // A tag with a payload, e.g. `.verification = .{ .minisign = "KEY" }`
        // — inferred (with no destination type) as an anonymous struct with
        // one field named after the active union tag.
        .@"struct" => |s| blk: {
            comptime var out: []const u8 = ".{";
            inline for (s.fields, 0..) |field, i| {
                if (i > 0) out = out ++ ", ";
                out = out ++ "." ++ field.name ++ " = " ++ renderConfigValue(@field(value, field.name));
            }
            break :blk out ++ "}";
        },
        else => @compileError("Unsupported type in plugin config: " ++ @typeName(T)),
    };
}

test "builtin() renders scalar config fields" {
    const cfg = builtin(.github_upgrade, .{ .repo = "owner/app", .command_name = "up", .inform_out_of_date = true });
    try std.testing.expect(cfg.init != null);
    try std.testing.expectEqualStrings(
        ".init(.{.repo = \"owner/app\", .command_name = \"up\", .inform_out_of_date = true})",
        cfg.init.?,
    );
}

test "builtin() renders no init call for an empty config" {
    const cfg = builtin(.help, .{});
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.init);
}

test "builtin() renders a union-payload config field (e.g. github_upgrade's verification: .{ .minisign = ... })" {
    // The config passed to builtin() is `anytype`, so `.{ .minisign = "KEY" }`
    // has no destination type and is inferred as a one-field anonymous struct,
    // not the union it will later coerce to. renderConfigValue must reproduce
    // that literal text verbatim so the generated `init(.{ ... })` call, which
    // DOES have the union's Config type available, coerces it correctly.
    const cfg = builtin(.github_upgrade, .{
        .repo = "owner/app",
        .verification = .{ .minisign = "KEY" },
    });
    try std.testing.expectEqualStrings(
        ".init(.{.repo = \"owner/app\", .verification = .{.minisign = \"KEY\"}})",
        cfg.init.?,
    );
}

test "builtin() renders a bare enum-literal config field (e.g. .checksum_only)" {
    const cfg = builtin(.github_upgrade, .{
        .repo = "owner/app",
        .verification = .checksum_only,
    });
    try std.testing.expectEqualStrings(
        ".init(.{.repo = \"owner/app\", .verification = .checksum_only})",
        cfg.init.?,
    );
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
