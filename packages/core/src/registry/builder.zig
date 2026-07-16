const std = @import("std");
const zcli = @import("../zcli.zig");
const plugin_types = @import("../plugin_types.zig");

const paths = @import("paths.zig");
const compiled = @import("compiled.zig");
const splitPath = paths.splitPath;
const buildAliasPath = paths.buildAliasPath;
const pathsEqual = paths.pathsEqual;
const CompiledRegistry = compiled.CompiledRegistry;

/// Compute command entries including aliases
pub fn computeEntriesWithAliases(
    comptime existing: []const CommandEntry,
    comptime path: []const u8,
    comptime Module: type,
) []const CommandEntry {
    comptime {
        const path_components = splitPath(path);
        var result: []const CommandEntry = existing ++ [_]CommandEntry{
            .{ .path = path_components, .module = Module },
        };

        // Add alias entries if the module has aliases in meta
        if (@hasDecl(Module, "meta") and @hasField(@TypeOf(Module.meta), "aliases")) {
            for (Module.meta.aliases) |alias| {
                const alias_path = buildAliasPath(path_components, alias);

                // Check for conflicts with existing entries
                for (result) |entry| {
                    if (pathsEqual(entry.path, alias_path)) {
                        @compileError("Alias '" ++ alias ++ "' conflicts with existing command at path");
                    }
                }

                result = result ++ [_]CommandEntry{
                    .{ .path = alias_path, .module = Module },
                };
            }
        }
        return result;
    }
}

/// Configuration for the application
pub const Config = struct {
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
};

/// Command entry for the registry
pub const CommandEntry = struct {
    path: []const []const u8,
    module: type,
};

/// Validate `app_name` against a strict identifier charset at compile time.
///
/// The app name is interpolated unescaped into generated shell completion
/// scripts as function names and `complete` targets (see zcli_completions/
/// {bash,zsh,fish}.zig). Rather than escaping it per-shell, we reject any name
/// that isn't a safe identifier — a developer-controlled comptime value should
/// never contain shell metacharacters, whitespace, quotes, or path separators.
fn validateAppName(comptime app_name: []const u8) void {
    if (app_name.len == 0) {
        @compileError("app_name must not be empty");
    }
    for (app_name) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.';
        if (!ok) {
            @compileError("app_name \"" ++ app_name ++
                "\" contains an invalid character; only [A-Za-z0-9._-] are allowed " ++
                "(it is interpolated unescaped into generated shell completion scripts)");
        }
    }
}

/// Registry builder for comptime command registration
pub const Registry = struct {
    pub fn init(comptime config: Config) RegistryBuilder(config, &.{}, &.{}) {
        comptime validateAppName(config.app_name);
        return RegistryBuilder(config, &.{}, &.{}).init();
    }
};

/// Comptime builder that tracks commands and plugins
fn RegistryBuilder(comptime config: Config, comptime commands: []const CommandEntry, comptime new_plugins: []const type) type {
    return struct {
        pub fn init() @This() {
            return @This(){};
        }

        pub fn register(comptime self: @This(), comptime path: []const u8, comptime Module: type) RegistryBuilder(
            config,
            computeEntriesWithAliases(commands, path, Module),
            new_plugins,
        ) {
            _ = self;

            // Validate the whole command contract at compile time, with errors
            // that name this command by its path.
            comptime zcli.validateCommand(path, Module);

            return RegistryBuilder(
                config,
                computeEntriesWithAliases(commands, path, Module),
                new_plugins,
            ).init();
        }

        pub fn registerPlugin(comptime self: @This(), comptime Plugin: type) RegistryBuilder(
            config,
            commands,
            new_plugins ++ [_]type{Plugin},
        ) {
            _ = self;
            // Backstop against silently-dead misspelled hooks (exact-name
            // detection has no diagnostics of its own).
            comptime plugin_types.validatePlugin(Plugin);
            return RegistryBuilder(
                config,
                commands,
                new_plugins ++ [_]type{Plugin},
            ).init();
        }

        pub fn build(comptime self: @This()) type {
            _ = self;
            return CompiledRegistry(config, commands, new_plugins);
        }
    };
}

/// Helper to check if a declaration is a command struct (not Args/Options/meta/execute)
fn isCommandDecl(comptime name: []const u8) bool {
    return !std.mem.eql(u8, name, "Args") and
        !std.mem.eql(u8, name, "Options") and
        !std.mem.eql(u8, name, "meta") and
        !std.mem.eql(u8, name, "execute");
}

/// Recursively discover plugin commands from a struct type
pub fn discoverPluginCommands(comptime CommandsStruct: type, comptime path_prefix: []const []const u8) []const CommandEntry {
    const info = @typeInfo(CommandsStruct);
    if (info != .@"struct") return &.{};

    var entries: []const CommandEntry = &.{};

    // Iterate through all declarations in this struct
    inline for (info.@"struct".decls) |decl| {
        // Skip non-command declarations
        if (!isCommandDecl(decl.name)) continue;

        // Get the declaration - this must be a public constant type
        if (!@hasDecl(CommandsStruct, decl.name)) continue;

        const DeclValue = @field(CommandsStruct, decl.name);
        const DeclValueType = @TypeOf(DeclValue);

        // Check if this declaration is a type
        if (@typeInfo(DeclValueType) != .type) continue;

        // DeclValue is a type, use it directly
        const CommandType = DeclValue;
        const command_type_info = @typeInfo(CommandType);

        // Only process struct types
        if (command_type_info != .@"struct") continue;

        // Build the path for this command
        const current_path = path_prefix ++ .{decl.name};

        // Validate the whole command contract at compile time, naming the
        // command by its space-joined path.
        comptime var path_str: []const u8 = "";
        inline for (current_path, 0..) |component, idx| {
            if (idx > 0) path_str = path_str ++ " ";
            path_str = path_str ++ component;
        }
        comptime zcli.validateCommand(path_str, CommandType);

        // Add this command/group to entries
        entries = entries ++ .{CommandEntry{
            .path = current_path,
            .module = CommandType,
        }};

        // Recursively discover nested commands
        const nested_entries = discoverPluginCommands(CommandType, current_path);
        entries = entries ++ nested_entries;
    }

    return entries;
}

test "validateAppName accepts safe identifier charset" {
    // These must all compile without a @compileError. If any of them were
    // rejected, this test file would fail to build.
    comptime validateAppName("myapp");
    comptime validateAppName("my-app");
    comptime validateAppName("my_app");
    comptime validateAppName("my.app");
    comptime validateAppName("App123");
    // Registry.init runs the same check on the way in.
    _ = Registry.init(.{
        .app_name = "safe-name_1.0",
        .app_version = "1.0.0",
        .app_description = "desc",
    });
}
