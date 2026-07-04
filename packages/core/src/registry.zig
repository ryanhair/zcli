const std = @import("std");
const command_parser = @import("command_parser.zig");
const option_utils = @import("options/utils.zig");
const plugin_types = @import("plugin_types.zig");
const types = @import("build_utils/types.zig");
const zcli = @import("zcli.zig");
const testing = std.testing;

/// Split a path string into components at compile time
fn splitPath(comptime path: []const u8) []const []const u8 {
    comptime {
        var components: []const []const u8 = &.{};
        var it = std.mem.splitSequence(u8, path, " ");
        while (it.next()) |component| {
            if (component.len > 0) {
                components = components ++ [_][]const u8{component};
            }
        }
        return components;
    }
}

/// Join a command path with spaces at compile time, for `@compileError`
/// messages — no allocator exists there, so `std.mem.join` cannot be used.
fn comptimeJoinPath(comptime path: []const []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (path, 0..) |component, i| {
            if (i != 0) result = result ++ " ";
            result = result ++ component;
        }
        return result;
    }
}

/// Sort command entries by path length (descending) at compile time, so
/// routing tries the most specific path first. The loop condition is
/// `i + 1 < len` rather than `len - 1`: a plugin-only registry has zero
/// commands, and `0 - 1` underflows usize at comptime.
fn sortedByPathLengthDesc(comptime commands: anytype) @TypeOf(commands[0..commands.len].*) {
    var cmds = commands[0..commands.len].*;
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i + 1 < cmds.len) : (i += 1) {
            if (cmds[i].path.len < cmds[i + 1].path.len) {
                const temp = cmds[i];
                cmds[i] = cmds[i + 1];
                cmds[i + 1] = temp;
                changed = true;
            }
        }
    }
    return cmds;
}

/// Default rendering for a parse error no plugin handled: the diagnostic's
/// precise, human-readable message on stderr (flushed — the process is about
/// to exit with an error). Falls back silently when no diagnostic was filled
/// (the error name still reaches the caller).
fn reportParseError(context: anytype, diag: ?zcli.ZcliDiagnostic) !void {
    const d = diag orelse return;
    const message = zcli.formatDiagnostic(d, context.allocator) catch return;
    var stderr = context.stderr();
    try stderr.print("Error: {s}\n", .{message});
    try stderr.flush();
}

/// Convert a global option's argv string to its declared type. Covers the
/// full set plugin_types.option() accepts (validated at declaration, so the
/// compile-error backstop here is unreachable for declared options).
fn convertGlobalValue(comptime T: type, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .bool => std.mem.eql(u8, value, "true"),
        .int => try std.fmt.parseInt(T, value, 10),
        .float => try std.fmt.parseFloat(T, value),
        .optional => |opt| try convertGlobalValue(opt.child, value),
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8)
            value
        else
            @compileError("Unsupported global option type: " ++ @typeName(T)),
        else => @compileError("Unsupported global option type: " ++ @typeName(T)),
    };
}

/// Errors that execute() reports to the user before returning them — the
/// user-facing message has already been printed by the time these surface.
fn isReportedCliError(err: anyerror) bool {
    return switch (err) {
        error.CommandNotFound,
        error.SubcommandNotFound,
        error.OptionUnknown,
        error.OptionMissingValue,
        error.OptionInvalidValue,
        error.OptionBooleanWithValue,
        error.OptionDuplicate,
        error.ArgumentMissingRequired,
        error.ArgumentInvalidValue,
        error.ArgumentTooMany,
        error.ResourceLimitExceeded,
        => true,
        else => false,
    };
}

/// Build an alias path by replacing the last component with the alias name
fn buildAliasPath(comptime original_path: []const []const u8, comptime alias: []const u8) []const []const u8 {
    comptime {
        if (original_path.len == 0) return &[_][]const u8{alias};
        if (original_path.len == 1) return &[_][]const u8{alias};
        var result: []const []const u8 = &.{};
        for (original_path[0 .. original_path.len - 1]) |component| {
            result = result ++ &[_][]const u8{component};
        }
        result = result ++ &[_][]const u8{alias};
        return result;
    }
}

/// Check if two paths are equal at compile time
fn pathsEqual(comptime path1: []const []const u8, comptime path2: []const []const u8) bool {
    if (path1.len != path2.len) return false;
    inline for (path1, path2) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

/// Compute command entries including aliases
fn computeEntriesWithAliases(
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

/// Plugin entry for the registry (legacy support)
pub const PluginEntry = struct {
    plugin: type,
};

/// Registry builder for comptime command registration
pub const Registry = struct {
    pub fn init(comptime config: Config) RegistryBuilder(config, &.{}, &.{}) {
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
fn discoverPluginCommands(comptime CommandsStruct: type, comptime path_prefix: []const []const u8) []const CommandEntry {
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

/// Compiled registry with all command and plugin information
fn CompiledRegistry(comptime config: Config, comptime cmd_entries: []const CommandEntry, comptime new_plugins: []const type) type {
    // Validate plugin conflicts at compile time
    comptime {
        // Use arrays to check for conflicts since ComptimeStringMap may not be available
        var global_option_names: []const []const u8 = &.{};
        var command_paths: []const []const []const u8 = &.{};

        // Check for command path conflicts among regular commands
        for (cmd_entries) |cmd| {
            for (command_paths) |existing_path| {
                // Compare path arrays element by element
                var paths_equal = existing_path.len == cmd.path.len;
                if (paths_equal) {
                    for (existing_path, 0..) |existing_component, i| {
                        if (!std.mem.eql(u8, existing_component, cmd.path[i])) {
                            paths_equal = false;
                            break;
                        }
                    }
                }
                if (paths_equal) {
                    @compileError("Duplicate command path: " ++ comptimeJoinPath(cmd.path));
                }
            }
            command_paths = command_paths ++ .{cmd.path};
        }

        // Validate optional command groups (commands that have subcommands)
        for (cmd_entries) |cmd| {
            // Check if this command has subcommands
            var has_subcommands = false;
            for (cmd_entries) |other_cmd| {
                // Skip self
                if (other_cmd.path.len <= cmd.path.len) continue;

                // Check if other_cmd is a subcommand of cmd
                var is_subcommand = true;
                for (cmd.path, 0..) |component, i| {
                    if (!std.mem.eql(u8, component, other_cmd.path[i])) {
                        is_subcommand = false;
                        break;
                    }
                }

                if (is_subcommand) {
                    has_subcommands = true;
                    break;
                }
            }

            // If this command has subcommands, validate it's an optional command group
            if (has_subcommands) {
                if (@hasDecl(cmd.module, "Args")) {
                    const args_fields = std.meta.fields(cmd.module.Args);
                    if (args_fields.len > 0) {
                        // Build path string for error message
                        var path_str: []const u8 = "";
                        for (cmd.path, 0..) |component, idx| {
                            if (idx > 0) path_str = path_str ++ " ";
                            path_str = path_str ++ component;
                        }
                        @compileError("Optional command group '" ++ path_str ++ "' cannot have Args fields. " ++
                            "Command groups with subcommands must have an empty Args struct.");
                    }
                }
            }
        }

        // Check for conflicts between plugin commands and regular commands
        var plugin_command_paths: []const []const []const u8 = &.{};
        for (new_plugins) |Plugin| {
            if (@hasDecl(Plugin, "commands")) {
                // Recursively discover all plugin commands (including nested)
                const plugin_cmd_entries = discoverPluginCommands(Plugin.commands, &.{});

                for (plugin_cmd_entries) |plugin_cmd| {
                    // Check against regular commands
                    for (command_paths) |existing_path| {
                        var paths_equal = existing_path.len == plugin_cmd.path.len;
                        if (paths_equal) {
                            for (existing_path, 0..) |existing_component, i| {
                                if (!std.mem.eql(u8, existing_component, plugin_cmd.path[i])) {
                                    paths_equal = false;
                                    break;
                                }
                            }
                        }
                        if (paths_equal) {
                            @compileError("Plugin command conflicts with existing command: " ++ comptimeJoinPath(plugin_cmd.path));
                        }
                    }
                    // Check against other plugin commands
                    for (plugin_command_paths) |existing_plugin_path| {
                        var paths_equal = existing_plugin_path.len == plugin_cmd.path.len;
                        if (paths_equal) {
                            for (existing_plugin_path, 0..) |existing_component, i| {
                                if (!std.mem.eql(u8, existing_component, plugin_cmd.path[i])) {
                                    paths_equal = false;
                                    break;
                                }
                            }
                        }
                        if (paths_equal) {
                            @compileError("Duplicate plugin command: " ++ comptimeJoinPath(plugin_cmd.path));
                        }
                    }
                    plugin_command_paths = plugin_command_paths ++ .{plugin_cmd.path};
                }
            }
        }

        // Check for global option conflicts
        for (new_plugins) |Plugin| {
            if (plugin_types.hasGlobalOptions(Plugin)) {
                for (Plugin.global_options) |opt| {
                    for (global_option_names) |existing_name| {
                        if (std.mem.eql(u8, existing_name, opt.name)) {
                            @compileError("Duplicate global option: " ++ opt.name);
                        }
                    }
                    global_option_names = global_option_names ++ .{opt.name};
                }
            }
        }
    }

    return struct {
        const Self = @This();

        // Export the computed Context type for this registry
        pub const Context = zcli.ContextFor(new_plugins);

        // Expose commands array for testing and introspection
        pub const commands = cmd_entries;

        /// Metadata for a command that can be queried by plugins
        pub const CommandMetadata = struct {
            path: []const []const u8,
            description: []const u8,
            hidden: bool,
        };

        /// Get all commands with metadata (for use by plugins)
        /// Returns a compile-time array of command metadata including hidden status
        pub fn getAllCommands() []const CommandMetadata {
            comptime {
                var result: []const CommandMetadata = &.{};

                // Add regular commands
                for (cmd_entries) |cmd| {
                    const hidden = if (@hasDecl(cmd.module, "meta") and @hasField(@TypeOf(cmd.module.meta), "hidden"))
                        cmd.module.meta.hidden
                    else
                        false;

                    const description = if (@hasDecl(cmd.module, "meta") and @hasField(@TypeOf(cmd.module.meta), "description"))
                        cmd.module.meta.description
                    else
                        "";

                    result = result ++ .{CommandMetadata{
                        .path = cmd.path,
                        .description = description,
                        .hidden = hidden,
                    }};
                }

                // Add plugin commands
                for (plugin_command_entries) |plugin_cmd| {
                    const hidden = if (@hasDecl(plugin_cmd.module, "meta") and @hasField(@TypeOf(plugin_cmd.module.meta), "hidden"))
                        plugin_cmd.module.meta.hidden
                    else
                        false;

                    const description = if (@hasDecl(plugin_cmd.module, "meta") and @hasField(@TypeOf(plugin_cmd.module.meta), "description"))
                        plugin_cmd.module.meta.description
                    else
                        "";

                    result = result ++ .{CommandMetadata{
                        .path = plugin_cmd.path,
                        .description = description,
                        .hidden = hidden,
                    }};
                }

                return result;
            }
        }

        // Collect all global options at compile time
        const global_options = blk: {
            var opts: []const plugin_types.GlobalOption = &.{};
            for (new_plugins) |Plugin| {
                if (plugin_types.hasGlobalOptions(Plugin)) {
                    opts = opts ++ Plugin.global_options;
                }
            }
            break :blk opts;
        };

        // Validate no duplicate global option names or short flags
        comptime {
            for (global_options, 0..) |opt_a, i| {
                for (global_options[i + 1 ..]) |opt_b| {
                    if (std.mem.eql(u8, opt_a.name, opt_b.name)) {
                        @compileError("Duplicate global option name: --" ++ opt_a.name ++ ". Two plugins define the same global option.");
                    }
                    if (opt_a.short != null and opt_b.short != null and opt_a.short.? == opt_b.short.?) {
                        @compileError("Duplicate global option short flag: -" ++ &[_]u8{opt_a.short.?} ++ " (used by both --" ++ opt_a.name ++ " and --" ++ opt_b.name ++ ")");
                    }
                }
            }
        }

        // Discover all plugin command entries (including nested)
        const plugin_command_entries = blk: {
            var entries: []const CommandEntry = &.{};
            for (new_plugins) |Plugin| {
                if (@hasDecl(Plugin, "commands")) {
                    entries = entries ++ discoverPluginCommands(Plugin.commands, &.{});
                }
            }
            break :blk entries;
        };

        // Sort plugins by priority at compile time
        const sorted_plugins = blk: {
            // Handle empty plugins case
            if (new_plugins.len == 0) {
                break :blk &.{};
            }

            // Handle single plugin case
            if (new_plugins.len == 1) {
                break :blk &.{new_plugins[0]};
            }

            // Create a mutable array for sorting
            var plugins_with_priority: [new_plugins.len]struct { type, i32 } = undefined;
            for (new_plugins, 0..) |Plugin, i| {
                plugins_with_priority[i] = .{ Plugin, plugin_types.getPriority(Plugin) };
            }

            // Sort by priority (higher first) using comptime bubble sort
            var changed = true;
            while (changed) {
                changed = false;
                var i: usize = 0;
                while (i < plugins_with_priority.len - 1) : (i += 1) {
                    if (plugins_with_priority[i][1] < plugins_with_priority[i + 1][1]) {
                        const temp = plugins_with_priority[i];
                        plugins_with_priority[i] = plugins_with_priority[i + 1];
                        plugins_with_priority[i + 1] = temp;
                        changed = true;
                    }
                }
            }

            var result: []const type = &.{};
            for (plugins_with_priority) |plugin_entry| {
                result = result ++ .{plugin_entry[0]};
            }
            break :blk result;
        };

        // Command metadata for documentation, completions, and help.
        // Built at comptime from all registered commands and plugins.
        pub const command_info = buildCommandInfo();
        pub const global_options_info = buildGlobalOptionsInfo();

        fn buildGlobalOptionsInfo() []const zcli.OptionInfo {
            var opts: []const zcli.OptionInfo = &.{};
            for (global_options) |global_opt| {
                opts = opts ++ .{zcli.OptionInfo{
                    .name = global_opt.name,
                    .short = global_opt.short,
                    .description = global_opt.description,
                    .takes_value = global_opt.type != bool,
                }};
            }
            return opts;
        }

        fn buildCommandInfo() []const zcli.CommandInfo {
            @setEvalBranchQuota(10000);
            return buildCommandInfoFromEntries(cmd_entries) ++ buildCommandInfoFromEntries(plugin_command_entries);
        }

        fn buildCommandInfoFromEntries(entries: anytype) []const zcli.CommandInfo {
            var cmd_info_list: []const zcli.CommandInfo = &.{};
            for (entries) |cmd| {
                // Skip root command
                if (cmd.path.len == 1 and std.mem.eql(u8, cmd.path[0], "root")) continue;

                var description: ?[]const u8 = null;
                var examples: ?[]const []const u8 = null;
                var hidden: bool = false;
                var aliases: []const []const u8 = &.{};

                if (@hasDecl(cmd.module, "meta")) {
                    const meta = cmd.module.meta;
                    if (@hasField(@TypeOf(meta), "description")) description = meta.description;
                    if (@hasField(@TypeOf(meta), "examples")) examples = meta.examples;
                    if (@hasField(@TypeOf(meta), "hidden")) hidden = meta.hidden;
                    if (@hasField(@TypeOf(meta), "aliases")) aliases = meta.aliases;
                }

                // Introspect Options
                var options: []const zcli.OptionInfo = &.{};
                if (@hasDecl(cmd.module, "Options")) {
                    const OptionsType = cmd.module.Options;
                    const options_type_info = @typeInfo(OptionsType);
                    if (options_type_info == .@"struct") {
                        for (options_type_info.@"struct".fields) |field| {
                            const base_type = if (@typeInfo(field.type) == .optional) @typeInfo(field.type).optional.child else field.type;
                            var opt_desc: ?[]const u8 = null;
                            var opt_short: ?u8 = null;
                            if (@hasDecl(cmd.module, "meta")) {
                                const meta = cmd.module.meta;
                                if (@hasField(@TypeOf(meta), "options")) {
                                    if (@hasField(@TypeOf(meta.options), field.name)) {
                                        const opt_meta = @field(meta.options, field.name);
                                        if (@hasField(@TypeOf(opt_meta), "description")) opt_desc = opt_meta.description;
                                        if (@hasField(@TypeOf(opt_meta), "short")) opt_short = opt_meta.short;
                                    }
                                }
                            }
                            options = options ++ .{zcli.OptionInfo{ .name = field.name, .short = opt_short, .description = opt_desc, .takes_value = base_type != bool }};
                        }
                    }
                }

                // Introspect Args
                var arg_infos: []const zcli.ArgInfo = &.{};
                if (@hasDecl(cmd.module, "Args")) {
                    const ArgsType = cmd.module.Args;
                    const args_type_info = @typeInfo(ArgsType);
                    if (args_type_info == .@"struct") {
                        for (args_type_info.@"struct".fields) |field| {
                            var arg_desc: ?[]const u8 = null;
                            if (@hasDecl(cmd.module, "meta")) {
                                const meta = cmd.module.meta;
                                if (@hasField(@TypeOf(meta), "args")) {
                                    if (@hasField(@TypeOf(meta.args), field.name)) {
                                        arg_desc = @field(meta.args, field.name);
                                    }
                                }
                            }
                            const is_opt = @typeInfo(field.type) == .optional or field.default_value_ptr != null;
                            const is_variadic = vblk: {
                                const ft = @typeInfo(field.type);
                                break :vblk ft == .pointer and ft.pointer.size == .slice and ft.pointer.child != u8;
                            };
                            arg_infos = arg_infos ++ .{zcli.ArgInfo{ .name = field.name, .description = arg_desc, .is_optional = is_opt, .is_variadic = is_variadic }};
                        }
                    }
                }

                cmd_info_list = cmd_info_list ++ .{zcli.CommandInfo{
                    .path = cmd.path,
                    .description = description,
                    .examples = examples,
                    .args = arg_infos,
                    .options = options,
                    .hidden = hidden,
                    .aliases = aliases,
                }};
            }
            return cmd_info_list;
        }

        pub fn init() Self {
            return Self{};
        }

        pub fn execute(self: *Self, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8) !void {
            // Build list of available commands at compile time
            const available_commands = comptime blk: {
                var cmd_list: []const []const []const u8 = &.{};
                // Add regular commands (paths are already arrays), but skip "root"
                for (cmd_entries) |cmd| {
                    // Skip root command from the visible commands list
                    if (cmd.path.len == 1 and std.mem.eql(u8, cmd.path[0], "root")) {
                        continue;
                    }
                    cmd_list = cmd_list ++ .{cmd.path};
                }
                // Add plugin commands (with full paths including nested)
                for (plugin_command_entries) |plugin_cmd| {
                    cmd_list = cmd_list ++ .{plugin_cmd.path};
                }
                break :blk cmd_list;
            };

            const global_options_list = global_options_info;

            const plugin_command_info_list = command_info;

            // Create the standard-stream holder and finalize before passing to Context
            var stdio: zcli.Stdio = undefined;
            stdio.init(io);
            defer stdio.flush();

            // Arena-per-command allocator: everything the command and framework
            // bookkeeping allocate during this invocation lives in the arena and is
            // reclaimed wholesale when execute() returns. Command authors never need
            // to call free. See docs/adr/0001-arena-per-command-allocator.md.
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            // Use the computed Context type which includes type-safe plugin data
            var context = Context{
                .allocator = arena.allocator(),
                .io = io,
                .stdio = &stdio,
                .environ = environ,
                .theme = zcli.ztheme.Theme.init(environ, io),
                .app_name = config.app_name,
                .app_version = config.app_version,
                .app_description = config.app_description,
                .available_commands = available_commands,
                .command_path = &.{},
                .plugin_command_info = plugin_command_info_list,
                .global_options = global_options_list,
            };
            defer context.deinit();

            // 1. Run preParse hooks
            var current_args = args;
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "preParse")) {
                    current_args = try Plugin.preParse(&context, current_args);
                }
            }

            // 2. Extract and handle global options. Failures here are parse
            // errors like any other: dispatch onError, default-render the
            // diagnostic when unhandled.
            const global_result = self.parseGlobalOptions(&context, current_args) catch |err| {
                if (!isReportedCliError(err)) return err;
                var error_handled = false;
                inline for (sorted_plugins) |Plugin| {
                    if (@hasDecl(Plugin, "onError")) {
                        if (try Plugin.onError(&context, err)) {
                            error_handled = true;
                            break;
                        }
                    }
                }
                if (!error_handled) {
                    try reportParseError(&context, context.diagnostic);
                    return err;
                }
                return;
            };
            defer context.allocator.free(global_result.consumed);
            defer context.allocator.free(global_result.remaining);
            current_args = global_result.remaining;

            // 3. Transform arguments
            var transform_result = zcli.TransformResult{ .args = current_args };
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "transformArgs") and transform_result.continue_processing) {
                    transform_result = try Plugin.transformArgs(&context, transform_result.args);
                }
            }

            if (!transform_result.continue_processing) {
                return; // Plugin stopped execution
            }

            current_args = transform_result.args;

            // 4. Route to command
            try self.executeCommand(&context, current_args);
        }

        /// Convenient run method that handles process args, io, and environment
        pub fn run(self: *Self, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8) !void {
            self.execute(allocator, io, environ, if (args.len > 0) args[1..] else args) catch |err| {
                // CLI-entry semantics: parse/routing failures were already
                // reported to the user (diagnostic rendering, a plugin, or
                // the framework fallback message) — exit(1) without letting
                // the raw error trace follow the friendly message. Anything
                // else is a real command failure; propagate it so the trace
                // aids debugging. Library/test callers who want the error
                // itself use execute() directly.
                if (isReportedCliError(err)) std.process.exit(1);
                return err;
            };
        }

        /// Convert `value` and hand it to the plugin that declared
        /// `global_opt`. A value that doesn't parse as the declared type is
        /// reported as OptionInvalidValue with a diagnostic.
        fn dispatchGlobalOption(context: *Context, comptime global_opt: zcli.GlobalOption, value: []const u8, is_short: bool) !void {
            const typed_value = convertGlobalValue(global_opt.type, value) catch {
                context.diagnostic = .{ .OptionInvalidValue = .{
                    .option_name = global_opt.name,
                    .is_short = is_short,
                    .provided_value = value,
                    .expected_type = @typeName(global_opt.type),
                } };
                return zcli.ZcliError.OptionInvalidValue;
            };
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "handleGlobalOption") and @hasDecl(Plugin, "global_options")) {
                    inline for (Plugin.global_options) |plugin_opt| {
                        if (comptime std.mem.eql(u8, plugin_opt.name, global_opt.name)) {
                            try Plugin.handleGlobalOption(context, global_opt.name, typed_value);
                            return;
                        }
                    }
                }
            }
        }

        pub fn parseGlobalOptions(_: *Self, context: *Context, args: []const []const u8) !zcli.GlobalOptionsResult {
            var consumed = std.ArrayList(usize).empty;
            var remaining = std.ArrayList([]const u8).empty;
            defer consumed.deinit(context.allocator);
            defer remaining.deinit(context.allocator);

            var i: usize = 0;
            while (i < args.len) {
                const arg = args[i];
                var handled = false;

                if (std.mem.startsWith(u8, arg, "--")) {
                    const opt_name = arg[2..];
                    // Check if this is a global option
                    inline for (global_options) |global_opt| {
                        if (std.mem.eql(u8, opt_name, global_opt.name)) {
                            // Handle the global option
                            try consumed.append(context.allocator, i);

                            var value: []const u8 = "true"; // Boolean flags: presence == true
                            if (global_opt.type != bool) {
                                // Same next-token-is-a-value rule the command
                                // parsers share (options/utils.zig).
                                if (i + 1 < args.len and
                                    (!std.mem.startsWith(u8, args[i + 1], "-") or option_utils.isNegativeNumber(args[i + 1])))
                                {
                                    i += 1;
                                    value = args[i];
                                    try consumed.append(context.allocator, i);
                                } else {
                                    context.diagnostic = .{ .OptionMissingValue = .{
                                        .option_name = global_opt.name,
                                        .is_short = false,
                                        .expected_type = @typeName(global_opt.type),
                                    } };
                                    return zcli.ZcliError.OptionMissingValue;
                                }
                            }

                            try dispatchGlobalOption(context, global_opt, value, false);

                            handled = true;
                            break;
                        }
                    }
                } else if (std.mem.startsWith(u8, arg, "-") and arg.len == 2) {
                    // Single short option: mirrors the long path, including
                    // values for non-boolean globals (`-c config.json`).
                    const short_char = arg[1];
                    inline for (global_options) |global_opt| {
                        if (global_opt.short == short_char) {
                            try consumed.append(context.allocator, i);

                            var value: []const u8 = "true";
                            if (global_opt.type != bool) {
                                if (i + 1 < args.len and
                                    (!std.mem.startsWith(u8, args[i + 1], "-") or option_utils.isNegativeNumber(args[i + 1])))
                                {
                                    i += 1;
                                    value = args[i];
                                    try consumed.append(context.allocator, i);
                                } else {
                                    context.diagnostic = .{ .OptionMissingValue = .{
                                        .option_name = global_opt.name,
                                        .is_short = true,
                                        .expected_type = @typeName(global_opt.type),
                                    } };
                                    return zcli.ZcliError.OptionMissingValue;
                                }
                            }

                            try dispatchGlobalOption(context, global_opt, value, true);

                            handled = true;
                            break;
                        }
                    }
                } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 2) {
                    // Bundled shorts (-abc): consumed as globals only when
                    // EVERY char is a boolean global — a partial match would
                    // silently drop the other chars, and a value-taking short
                    // can't get a value inside a bundle. Anything else stays
                    // in `remaining` for the command's own option parser.
                    const short_opts = arg[1..];
                    var all_boolean_globals = true;
                    for (short_opts) |short_char| {
                        var char_is_boolean_global = false;
                        inline for (global_options) |global_opt| {
                            if (global_opt.short == short_char and global_opt.type == bool) {
                                char_is_boolean_global = true;
                            }
                        }
                        if (!char_is_boolean_global) all_boolean_globals = false;
                    }

                    if (all_boolean_globals) {
                        try consumed.append(context.allocator, i);
                        for (short_opts) |short_char| {
                            inline for (global_options) |global_opt| {
                                if (global_opt.short == short_char) {
                                    try dispatchGlobalOption(context, global_opt, "true", true);
                                }
                            }
                        }
                        handled = true;
                    }
                }

                if (!handled) {
                    try remaining.append(context.allocator, arg);
                }

                i += 1;
            }

            const result = zcli.GlobalOptionsResult{
                .consumed = try consumed.toOwnedSlice(context.allocator),
                .remaining = try remaining.toOwnedSlice(context.allocator),
            };
            // Note: Caller is responsible for freeing consumed and remaining arrays
            return result;
        }

        // ------------------------------------------------------------------
        // Command execution
        //
        // executeCommand routes argv to a command module; everything after
        // routing — context metadata, hook dispatch, parsing, execution,
        // error handling — is shared by regular and plugin commands in
        // executeResolvedCommand and the hook helpers below.
        // ------------------------------------------------------------------

        /// Whether a resolved module came from the app's command tree or a
        /// plugin's `commands`. The paths differ in one place: a regular
        /// command with no positional Args treats a stray non-option argument
        /// as a mistyped subcommand (CommandNotFound); plugin commands keep
        /// their historical behavior of letting the parser report it.
        const CommandKind = enum { regular, plugin };

        /// Dispatch `err` to the plugins' onError hooks, first handler wins.
        /// Returns whether a plugin handled (and thereby suppressed) the error.
        fn runOnErrorHooks(context: *Context, err: anyerror) !bool {
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "onError")) {
                    if (try Plugin.onError(context, err)) return true;
                }
            }
            return false;
        }

        /// Run postParse hooks, threading each plugin's replacement ParsedArgs.
        fn runPostParseHooks(context: *Context, parsed: zcli.ParsedArgs) !zcli.ParsedArgs {
            var parsed_args = parsed;
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "postParse")) {
                    if (try Plugin.postParse(context, parsed_args)) |new_parsed| {
                        parsed_args = new_parsed;
                    }
                }
            }
            return parsed_args;
        }

        /// Run preExecute hooks. Returns null when a plugin cancels execution.
        fn runPreExecuteHooks(context: *Context, parsed: zcli.ParsedArgs) !?zcli.ParsedArgs {
            var parsed_args = parsed;
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "preExecute")) {
                    if (try Plugin.preExecute(context, parsed_args)) |new_parsed| {
                        parsed_args = new_parsed;
                    } else {
                        return null;
                    }
                }
            }
            return parsed_args;
        }

        /// Point context.command_path at an allocated copy of `parts`.
        fn setCommandPath(context: *Context, parts: []const []const u8) !void {
            const copy = try context.allocator.alloc([]const u8, parts.len);
            for (parts, 0..) |part, i| {
                copy[i] = try context.allocator.dupe(u8, part);
            }
            context.command_path = copy;
        }

        /// Convert a command struct's fields to runtime FieldInfo for plugin
        /// introspection, pulling per-option short/description from
        /// `options_meta` (pass null for Args structs, which carry neither).
        fn buildFieldInfoList(comptime T: type, comptime options_meta: anytype, allocator: std.mem.Allocator) ![]const zcli.FieldInfo {
            const type_info = @typeInfo(T);
            if (type_info != .@"struct") return &.{};
            var field_list = std.ArrayList(zcli.FieldInfo).empty;
            inline for (type_info.@"struct".fields) |field| {
                const field_type_info = @typeInfo(field.type);
                var short: ?u8 = null;
                var description: ?[]const u8 = null;
                if (comptime @TypeOf(options_meta) != @TypeOf(null)) {
                    if (@hasField(@TypeOf(options_meta), field.name)) {
                        const field_meta = @field(options_meta, field.name);
                        if (@hasField(@TypeOf(field_meta), "short")) short = field_meta.short;
                        if (@hasField(@TypeOf(field_meta), "description")) description = field_meta.description;
                    }
                }
                try field_list.append(allocator, zcli.FieldInfo{
                    .name = field.name,
                    .is_optional = field_type_info == .optional or field.default_value_ptr != null,
                    .is_array = field_type_info == .pointer and field_type_info.pointer.size == .slice and field_type_info.pointer.child != u8,
                    .short = short,
                    .description = description,
                });
            }
            return field_list.toOwnedSlice(allocator);
        }

        /// Record the resolved command's metadata and introspection info on
        /// the context (the help plugin renders from these).
        fn setCommandInfo(comptime Module: type, context: *Context) !void {
            if (@hasDecl(Module, "meta")) {
                const meta = Module.meta;
                context.command_meta = zcli.CommandMeta{
                    .description = if (@hasField(@TypeOf(meta), "description")) meta.description else null,
                    .examples = if (@hasField(@TypeOf(meta), "examples")) meta.examples else null,
                };
            }

            const options_meta = comptime blk: {
                if (@hasDecl(Module, "meta") and @hasField(@TypeOf(Module.meta), "options")) break :blk Module.meta.options;
                break :blk null;
            };
            context.command_module_info = zcli.CommandModuleInfo{
                .has_args = @hasDecl(Module, "Args"),
                .has_options = @hasDecl(Module, "Options"),
                .raw_meta_ptr = if (@hasDecl(Module, "meta")) &Module.meta else null,
                .args_fields = if (@hasDecl(Module, "Args")) try buildFieldInfoList(Module.Args, null, context.allocator) else &.{},
                .options_fields = if (@hasDecl(Module, "Options")) try buildFieldInfoList(Module.Options, options_meta, context.allocator) else &.{},
            };
        }

        /// Everything that happens after routing has resolved a command
        /// module: record context info, run postParse/preExecute hooks, parse
        /// argv, execute, and dispatch errors/postExecute. `command_parts` is
        /// the matched command path; `remaining_args` the argv after it.
        fn executeResolvedCommand(comptime Module: type, comptime kind: CommandKind, context: *Context, command_parts: []const []const u8, remaining_args: []const []const u8) !void {
            @setEvalBranchQuota(10000);
            try setCommandPath(context, command_parts);
            try setCommandInfo(Module, context);

            var parsed_args = zcli.ParsedArgs.init(context.allocator);
            parsed_args.positional = remaining_args;
            parsed_args = try runPostParseHooks(context, parsed_args);
            parsed_args = (try runPreExecuteHooks(context, parsed_args)) orelse return; // plugin cancelled execution

            // Metadata-only command group (no execute): route through
            // CommandNotFound so the help plugin renders the subcommand list.
            if (!@hasDecl(Module, "execute")) {
                if (try runOnErrorHooks(context, error.CommandNotFound)) return;
                const cmd_name_str = try std.mem.join(context.allocator, " ", command_parts);
                defer context.allocator.free(cmd_name_str);
                try context.stderr().print("'{s}' is a command group. Use --help to see available subcommands.\n", .{cmd_name_str});
                return error.CommandNotFound;
            }

            const ArgsType = if (@hasDecl(Module, "Args")) Module.Args else struct {};
            const OptionsType = if (@hasDecl(Module, "Options")) Module.Options else struct {};
            const cmd_meta = if (@hasDecl(Module, "meta")) Module.meta else null;

            // A regular command that declares no positionals but got a
            // non-option argument was almost certainly invoked with a
            // mistyped subcommand — CommandNotFound, not a parse error.
            if (kind == .regular and std.meta.fields(ArgsType).len == 0 and
                remaining_args.len > 0 and !std.mem.startsWith(u8, remaining_args[0], "-"))
            {
                return error.CommandNotFound;
            }

            var parse_diag: ?zcli.ZcliDiagnostic = null;
            const parse_result = command_parser.parseCommandLine(ArgsType, OptionsType, cmd_meta, context.allocator, context.environ, parsed_args.positional, &parse_diag) catch |err| {
                context.diagnostic = parse_diag;
                if (try runOnErrorHooks(context, err)) return;
                try reportParseError(context, parse_diag);
                return err;
            };
            defer parse_result.deinit();

            const args_instance = parse_result.args;
            var options_instance = parse_result.options;

            // Config defaults override struct defaults; CLI-provided values
            // (already parsed) still take precedence.
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "applyConfigDefaults")) {
                    Plugin.applyConfigDefaults(context, OptionsType, &options_instance);
                }
            }

            // Execute. A handled error (onError returns true) is suppressed
            // and falls through to postExecute with success = false.
            var success = true;
            Module.execute(args_instance, options_instance, context) catch |err| {
                success = false;
                if (!try runOnErrorHooks(context, err)) return err;
            };

            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "postExecute")) {
                    try Plugin.postExecute(context, success);
                }
            }
        }

        fn executeCommand(_: *Self, context: *Context, args_input: []const []const u8) !void {
            @setEvalBranchQuota(10000);
            // The root command handles bare invocation: no args, or a first
            // arg that's an option rather than a command name.
            const use_root_command = args_input.len == 0 or std.mem.startsWith(u8, args_input[0], "-");

            const root_exists = comptime blk: {
                for (cmd_entries) |cmd| {
                    if (cmd.path.len == 1 and std.mem.eql(u8, cmd.path[0], "root")) break :blk true;
                }
                break :blk false;
            };

            // Route through the "root" pseudo-path when applicable. The root
            // command still receives the original argv for option parsing.
            const root_args = [_][]const u8{"root"};
            const args: []const []const u8 = if (use_root_command and root_exists) &root_args else args_input;

            // No command and no root command to fall back on: run the hooks
            // (the help plugin answers a bare --help here), then route
            // through CommandNotFound.
            if (args.len == 0) {
                const parsed_args = try runPostParseHooks(context, zcli.ParsedArgs.init(context.allocator));
                _ = (try runPreExecuteHooks(context, parsed_args)) orelse return; // plugin cancelled execution
                if (try runOnErrorHooks(context, error.CommandNotFound)) return;
                try context.stderr().print("No command specified. Use --help for usage information.\n", .{});
                return error.CommandNotFound;
            }

            // Regular commands, longest path first so the longest match wins.
            const sorted_commands = comptime sortedByPathLengthDesc(cmd_entries);
            inline for (sorted_commands) |cmd| {
                if (cmd.path.len <= args.len) {
                    var parts_match = true;
                    for (cmd.path, 0..) |part, i| {
                        if (!std.mem.eql(u8, part, args[i])) {
                            parts_match = false;
                            break;
                        }
                    }
                    if (parts_match) {
                        // The root command keeps the original argv (it's all
                        // options/positionals for root); other commands skip
                        // their matched path parts.
                        const remaining_args = if (use_root_command and std.mem.eql(u8, cmd.path[0], "root"))
                            args_input
                        else
                            args[cmd.path.len..];
                        return executeResolvedCommand(cmd.module, .regular, context, cmd.path, remaining_args);
                    }
                }
            }

            // Plugin commands: find the longest matching path, then execute it.
            var best_match_idx: ?usize = null;
            var best_match_len: usize = 0;
            inline for (plugin_command_entries, 0..) |plugin_cmd, idx| {
                if (args.len >= plugin_cmd.path.len and plugin_cmd.path.len > best_match_len) {
                    var matches = true;
                    for (plugin_cmd.path, 0..) |path_part, i| {
                        if (!std.mem.eql(u8, path_part, args[i])) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) {
                        best_match_idx = idx;
                        best_match_len = plugin_cmd.path.len;
                    }
                }
            }
            if (best_match_idx) |match_idx| {
                inline for (plugin_command_entries, 0..) |plugin_cmd, idx| {
                    if (idx == match_idx) {
                        return executeResolvedCommand(plugin_cmd.module, .plugin, context, plugin_cmd.path, args[plugin_cmd.path.len..]);
                    }
                }
            }

            // Nothing matched. Record the attempted path and route through
            // CommandNotFound (the help plugin suggests near-misses).
            try setCommandPath(context, args);
            if (try runOnErrorHooks(context, error.CommandNotFound)) return;
            try context.stderr().print("command {s} not found\n", .{args[0]});
            return error.CommandNotFound;
        }

        // Testing/introspection methods for the test suite
        pub fn getGlobalOptions() []const plugin_types.GlobalOption {
            return global_options;
        }

        pub fn getPluginCommandEntries() []const CommandEntry {
            return plugin_command_entries;
        }

        pub fn transformArgs(self: @This(), context: anytype, args: []const []const u8) !zcli.TransformResult {
            _ = self;
            var transform_result = zcli.TransformResult{ .args = args };
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "transformArgs") and transform_result.continue_processing) {
                    transform_result = try Plugin.transformArgs(context, transform_result.args);
                }
            }
            return transform_result;
        }
    };
}

const build_utils = @import("build_utils.zig");

// ============================================================================
// TEST HELPERS
// ============================================================================

fn createTestCommands(allocator: std.mem.Allocator) !types.DiscoveredCommands {
    var commands = types.DiscoveredCommands.init(allocator);

    // Create a pure command group (no index.zig)
    var network_subcommands = std.StringHashMap(types.CommandInfo).init(allocator);

    // Create path array properly
    var network_ls_path = try allocator.alloc([]const u8, 2);
    network_ls_path[0] = try allocator.dupe(u8, "network");
    network_ls_path[1] = try allocator.dupe(u8, "ls");

    const network_ls = types.CommandInfo{
        .name = try allocator.dupe(u8, "ls"),
        .path = network_ls_path,
        .file_path = try allocator.dupe(u8, "network/ls.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try network_subcommands.put(try allocator.dupe(u8, "ls"), network_ls);

    var network_path = try allocator.alloc([]const u8, 1);
    network_path[0] = try allocator.dupe(u8, "network");

    const network_group = types.CommandInfo{
        .name = try allocator.dupe(u8, "network"),
        .path = network_path,
        .file_path = try allocator.dupe(u8, "network"), // No index.zig
        .command_type = .pure_group,
        .subcommands = network_subcommands,
    };
    try commands.root.put(try allocator.dupe(u8, "network"), network_group);

    // Create an optional command group (with index.zig)
    var container_subcommands = std.StringHashMap(types.CommandInfo).init(allocator);
    var container_run_path = try allocator.alloc([]const u8, 2);
    container_run_path[0] = try allocator.dupe(u8, "container");
    container_run_path[1] = try allocator.dupe(u8, "run");

    const container_run = types.CommandInfo{
        .name = try allocator.dupe(u8, "run"),
        .path = container_run_path,
        .file_path = try allocator.dupe(u8, "container/run.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try container_subcommands.put(try allocator.dupe(u8, "run"), container_run);

    var container_path = try allocator.alloc([]const u8, 1);
    container_path[0] = try allocator.dupe(u8, "container");

    const container_group = types.CommandInfo{
        .name = try allocator.dupe(u8, "container"),
        .path = container_path,
        .file_path = try allocator.dupe(u8, "container/index.zig"),
        .command_type = .optional_group,
        .subcommands = container_subcommands,
    };
    try commands.root.put(try allocator.dupe(u8, "container"), container_group);

    // Create a leaf command
    var version_path = try allocator.alloc([]const u8, 1);
    version_path[0] = try allocator.dupe(u8, "version");

    const version_cmd = types.CommandInfo{
        .name = try allocator.dupe(u8, "version"),
        .path = version_path,
        .file_path = try allocator.dupe(u8, "version.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try commands.root.put(try allocator.dupe(u8, "version"), version_cmd);

    return commands;
}

// ============================================================================
// COMMAND TYPE DETECTION TESTS
// ============================================================================

test "command type detection: pure group without index.zig" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const network = commands.root.get("network").?;
    try testing.expect(network.command_type == .pure_group);
    try testing.expect(!std.mem.endsWith(u8, network.file_path, "index.zig"));
}

test "command type detection: optional group with index.zig" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const container = commands.root.get("container").?;
    try testing.expect(container.command_type == .optional_group);
    try testing.expect(std.mem.endsWith(u8, container.file_path, "index.zig"));
}

test "command type detection: leaf command" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const version = commands.root.get("version").?;
    try testing.expect(version.command_type == .leaf);
    try testing.expect(std.mem.endsWith(u8, version.file_path, ".zig"));
    try testing.expect(!std.mem.endsWith(u8, version.file_path, "index.zig"));
}

// ============================================================================
// CODE GENERATION TESTS
// ============================================================================

const code_generation = @import("build_utils/code_generation.zig");

test "code generation: pure groups are not registered as commands" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const config = types.BuildConfig{
        .commands_dir = "test/commands",
        .plugins_dir = null,
        .plugins = null,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    };

    const source = try code_generation.generateComptimeRegistrySource(allocator, commands, config, &.{});
    defer allocator.free(source);

    // Pure group "network" should NOT be in .register() calls
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"network\",") == null);

    // But its subcommand should be
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"network ls\",") != null);

    // Optional group "container" SHOULD be registered
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"container\",") != null);
}

test "code generation: pure groups listed in metadata" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const config = types.BuildConfig{
        .commands_dir = "test/commands",
        .plugins_dir = null,
        .plugins = null,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    };

    const source = try code_generation.generateComptimeRegistrySource(allocator, commands, config, &.{});
    defer allocator.free(source);

    // Should have pure_command_groups array
    try testing.expect(std.mem.indexOf(u8, source, "pub const pure_command_groups") != null);

    // Should list "network" as a pure group
    try testing.expect(std.mem.indexOf(u8, source, "&.{\"network\"}") != null);
}

// ============================================================================
// NESTED COMMAND GROUP TESTS
// ============================================================================

test "nested pure command groups" {
    const allocator = testing.allocator;
    var commands = types.DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // Create nested structure: docker -> compose (pure) -> up (leaf)
    var compose_subcommands = std.StringHashMap(types.CommandInfo).init(allocator);

    var compose_up_path = try allocator.alloc([]const u8, 3);
    compose_up_path[0] = try allocator.dupe(u8, "docker");
    compose_up_path[1] = try allocator.dupe(u8, "compose");
    compose_up_path[2] = try allocator.dupe(u8, "up");

    const compose_up = types.CommandInfo{
        .name = try allocator.dupe(u8, "up"),
        .path = compose_up_path,
        .file_path = try allocator.dupe(u8, "docker/compose/up.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try compose_subcommands.put(try allocator.dupe(u8, "up"), compose_up);

    // Compose is a pure group (no index.zig)
    var compose_path = try allocator.alloc([]const u8, 2);
    compose_path[0] = try allocator.dupe(u8, "docker");
    compose_path[1] = try allocator.dupe(u8, "compose");

    const compose_group = types.CommandInfo{
        .name = try allocator.dupe(u8, "compose"),
        .path = compose_path,
        .file_path = try allocator.dupe(u8, "docker/compose"),
        .command_type = .pure_group,
        .subcommands = compose_subcommands,
    };

    // Docker is an optional group
    var docker_subcommands = std.StringHashMap(types.CommandInfo).init(allocator);
    try docker_subcommands.put(try allocator.dupe(u8, "compose"), compose_group);

    var docker_path = try allocator.alloc([]const u8, 1);
    docker_path[0] = try allocator.dupe(u8, "docker");

    const docker_group = types.CommandInfo{
        .name = try allocator.dupe(u8, "docker"),
        .path = docker_path,
        .file_path = try allocator.dupe(u8, "docker/index.zig"),
        .command_type = .optional_group,
        .subcommands = docker_subcommands,
    };
    try commands.root.put(try allocator.dupe(u8, "docker"), docker_group);

    // Generate code
    const config = types.BuildConfig{
        .commands_dir = "test/commands",
        .plugins_dir = null,
        .plugins = null,
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    };

    const source = try code_generation.generateComptimeRegistrySource(allocator, commands, config, &.{});
    defer allocator.free(source);

    // Nested pure group should be in metadata
    try testing.expect(std.mem.indexOf(u8, source, "&.{\"docker\", \"compose\"}") != null);

    // Should NOT be registered as a command
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"docker compose\",") == null);

    // But the leaf command under it should be
    try testing.expect(std.mem.indexOf(u8, source, ".register(\"docker compose up\",") != null);
}

// ============================================================================
// VALIDATION TESTS
// ============================================================================

// Test structures for compile-time validation
const ValidOptionalGroup = struct {
    pub const Args = zcli.NoArgs;
    pub const Options = struct {
        verbose: bool = false,
    };
    pub fn execute(_: Args, _: Options, _: *zcli.Context) !void {}
};

const InvalidOptionalGroup = struct {
    pub const Args = struct {
        name: []const u8, // This should fail validation!
    };
    pub const Options = zcli.NoOptions;
    pub fn execute(_: Args, _: Options, _: *zcli.Context) !void {}
};

test "validation: optional group with empty Args is valid" {
    // This should compile without issues
    const TestRegistry = Registry.init(.{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "test",
    })
        .register("group", ValidOptionalGroup)
        .register("group sub", ValidOptionalGroup) // Makes "group" a group with subcommands
        .build();
    _ = TestRegistry;

    try testing.expect(true); // If we get here, compilation succeeded
}

// This test is commented out because it would cause a compile error (which is what we want!)
// Uncomment to verify the validation works
// test "validation: optional group with Args fields fails" {
//     const TestRegistry = Registry.init(.{
//         .app_name = "test",
//         .app_version = "1.0.0",
//         .app_description = "test",
//     })
//         .register("group", InvalidOptionalGroup)
//         .register("group sub", ValidOptionalGroup)
//         .build();
// }

// ============================================================================
// EDGE CASES
// ============================================================================

test "empty pure command group without subcommands" {
    const allocator = testing.allocator;
    var commands = types.DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // According to the discovery logic, empty directories are not included
    // This test documents that behavior

    // An empty pure group would not be discovered
    try testing.expect(commands.root.count() == 0);
}

test "command path array handling" {
    const allocator = testing.allocator;
    var commands = try createTestCommands(allocator);
    defer commands.deinit();

    const network = commands.root.get("network").?;
    try testing.expect(network.path.len == 1);
    try testing.expectEqualStrings("network", network.path[0]);

    const network_ls = network.subcommands.?.get("ls").?;
    try testing.expect(network_ls.path.len == 2);
    try testing.expectEqualStrings("network", network_ls.path[0]);
    try testing.expectEqualStrings("ls", network_ls.path[1]);
}

test "mixed command types in same parent" {
    const allocator = testing.allocator;
    var commands = types.DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // Create a structure with both pure and optional groups at same level
    var app_subcommands = std.StringHashMap(types.CommandInfo).init(allocator);

    // Pure group
    var pure_subcommands = std.StringHashMap(types.CommandInfo).init(allocator);

    var pure_cmd_path = try allocator.alloc([]const u8, 2);
    pure_cmd_path[0] = try allocator.dupe(u8, "pure");
    pure_cmd_path[1] = try allocator.dupe(u8, "list");

    const pure_cmd = types.CommandInfo{
        .name = try allocator.dupe(u8, "list"),
        .path = pure_cmd_path,
        .file_path = try allocator.dupe(u8, "pure/list.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try pure_subcommands.put(try allocator.dupe(u8, "list"), pure_cmd);

    var pure_path = try allocator.alloc([]const u8, 1);
    pure_path[0] = try allocator.dupe(u8, "pure");

    const pure_group = types.CommandInfo{
        .name = try allocator.dupe(u8, "pure"),
        .path = pure_path,
        .file_path = try allocator.dupe(u8, "pure"),
        .command_type = .pure_group,
        .subcommands = pure_subcommands,
    };
    try app_subcommands.put(try allocator.dupe(u8, "pure"), pure_group);

    // Optional group
    var optional_subcommands = std.StringHashMap(types.CommandInfo).init(allocator);

    var optional_cmd_path = try allocator.alloc([]const u8, 2);
    optional_cmd_path[0] = try allocator.dupe(u8, "optional");
    optional_cmd_path[1] = try allocator.dupe(u8, "exec");

    const optional_cmd = types.CommandInfo{
        .name = try allocator.dupe(u8, "exec"),
        .path = optional_cmd_path,
        .file_path = try allocator.dupe(u8, "optional/exec.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try optional_subcommands.put(try allocator.dupe(u8, "exec"), optional_cmd);

    var optional_path = try allocator.alloc([]const u8, 1);
    optional_path[0] = try allocator.dupe(u8, "optional");

    const optional_group = types.CommandInfo{
        .name = try allocator.dupe(u8, "optional"),
        .path = optional_path,
        .file_path = try allocator.dupe(u8, "optional/index.zig"),
        .command_type = .optional_group,
        .subcommands = optional_subcommands,
    };
    try app_subcommands.put(try allocator.dupe(u8, "optional"), optional_group);

    // Both should coexist properly
    commands.root = app_subcommands;

    const pure = commands.root.get("pure").?;
    const optional = commands.root.get("optional").?;

    try testing.expect(pure.command_type == .pure_group);
    try testing.expect(optional.command_type == .optional_group);
}

// Test command modules to simulate the nested command scenario
const RootCommand = struct {
    pub const meta = .{
        .description = "Root command",
    };

    pub const Args = zcli.NoArgs;
    pub const Options = zcli.NoOptions;

    pub fn execute(_: Args, _: Options, context: anytype) !void {
        try context.io.stdout.print("root executed\n", .{});
    }
};

const NestedCommand = struct {
    pub const meta = .{
        .description = "Nested command",
    };

    pub const Args = struct {
        name: []const u8,
    };
    pub const Options = struct {
        force: bool = false,
    };

    pub fn execute(args: Args, options: Options, context: anytype) !void {
        try context.io.stdout.print("nested executed: name={s}, force={}\n", .{ args.name, options.force });
    }
};

// Create a test registry with nested command paths to test longest-match routing
fn createTestRegistry(comptime config: Config) type {
    return Registry.init(config)
        .register("container", RootCommand) // 1 component
        .register("container run", NestedCommand) // 2 components
        .build();
}

test "command routing: longest match wins for nested commands" {
    // Create test registry
    const config = Config{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "Test CLI",
    };

    const TestApp = createTestRegistry(config);

    // Test that "container run arg" routes to NestedCommand (2 components)
    // not RootCommand (1 component)

    // Check that commands are properly registered
    const commands = TestApp.commands;
    var found_root = false;
    var found_nested = false;

    inline for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.path[0], "container")) {
            if (cmd.path.len == 1) {
                found_root = true;
                try testing.expect(cmd.module == RootCommand);
            } else if (cmd.path.len == 2 and std.mem.eql(u8, cmd.path[1], "run")) {
                found_nested = true;
                try testing.expect(cmd.module == NestedCommand);
            }
        }
    }

    try testing.expect(found_root);
    try testing.expect(found_nested);

    // Test command path sorting - longer paths should come first (the same
    // comptime sort execute() uses for routing)
    const sorted_commands = comptime sortedByPathLengthDesc(commands);

    // Verify that longer commands come first in sorted order
    var prev_length: usize = std.math.maxInt(usize);
    inline for (sorted_commands) |cmd| {
        try testing.expect(cmd.path.len <= prev_length);
        prev_length = cmd.path.len;
    }

    // Test command matching logic (simulating the registry matching algorithm)
    const test_args = [_][]const u8{ "container", "run", "myapp" };

    // Find the longest matching command
    var best_match_length: usize = 0;
    var best_match_found = false;
    var best_match_is_nested = false;

    inline for (sorted_commands) |cmd| {
        const parts_count = cmd.path.len;

        if (parts_count <= test_args.len and parts_count > best_match_length) {
            // Check if all parts match
            var parts_match = true;
            for (cmd.path, 0..) |part, i| {
                if (i >= test_args.len or !std.mem.eql(u8, part, test_args[i])) {
                    parts_match = false;
                    break;
                }
            }

            if (parts_match) {
                best_match_found = true;
                best_match_length = parts_count;
                best_match_is_nested = (cmd.module == NestedCommand);
            }
        }
    }

    // Verify that the nested command (2 components) was selected
    // over the root command (1 component)
    try testing.expect(best_match_found);
    try testing.expect(best_match_length == 2);
    try testing.expect(best_match_is_nested);
}

test "command routing: exact match for single component commands" {
    // Create test registry
    const config = Config{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "Test CLI",
    };

    const TestApp = createTestRegistry(config);

    // Test that "container" routes to RootCommand when there's no longer match
    const test_args = [_][]const u8{"container"};
    const commands = TestApp.commands;

    // Find the longest matching command
    var best_match_length: usize = 0;
    var best_match_found = false;
    var best_match_is_root = false;

    inline for (commands) |cmd| {
        const parts_count = cmd.path.len;

        if (parts_count <= test_args.len and parts_count > best_match_length) {
            // Check if all parts match
            var parts_match = true;
            for (cmd.path, 0..) |part, i| {
                if (i >= test_args.len or !std.mem.eql(u8, part, test_args[i])) {
                    parts_match = false;
                    break;
                }
            }

            if (parts_match) {
                best_match_found = true;
                best_match_length = parts_count;
                best_match_is_root = (cmd.module == RootCommand);
            }
        }
    }

    // Verify that the root command (1 component) was selected
    try testing.expect(best_match_found);
    try testing.expect(best_match_length == 1);
    try testing.expect(best_match_is_root);
}

test "command routing: no partial matches" {
    // Create test registry
    const config = Config{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "Test CLI",
    };

    const TestApp = createTestRegistry(config);

    // Test that "container start" doesn't match any command
    // (we only have "container" and "container run")
    const test_args = [_][]const u8{ "container", "start" };
    const commands = TestApp.commands;

    // Find the longest matching command
    var best_match_length: usize = 0;
    var best_match_found = false;

    inline for (commands) |cmd| {
        const parts_count = cmd.path.len;

        if (parts_count <= test_args.len and parts_count > best_match_length) {
            // Check if all parts match
            var parts_match = true;
            for (cmd.path, 0..) |part, i| {
                if (i >= test_args.len or !std.mem.eql(u8, part, test_args[i])) {
                    parts_match = false;
                    break;
                }
            }

            if (parts_match) {
                best_match_found = true;
                best_match_length = parts_count;
            }
        }
    }

    // Should match "container" (1 component) but not "container start"
    try testing.expect(best_match_found);
    try testing.expect(best_match_length == 1); // Only matches "container", not "container start"
}

// ============================================================================
// PURE COMMAND GROUP TESTS
// Tests for the new command group architecture where pure command groups
// (directories without index.zig) always show help and never execute.
// ============================================================================

// Test command modules
const NetworkLs = struct {
    pub const meta = .{
        .description = "List networks",
    };
    pub const Args = zcli.NoArgs;
    pub const Options = zcli.NoOptions;
    pub fn execute(_: Args, _: Options, context: anytype) !void {
        // Test command - no output needed
        _ = context;
    }
};

const TestHelpPlugin = struct {
    pub const priority = 100;

    var help_shown = false;
    var command_found_error = false;

    pub fn reset() void {
        help_shown = false;
        command_found_error = false;
    }

    pub fn onError(context: anytype, err: anyerror) !bool {
        _ = context;
        if (err == error.CommandNotFound) {
            command_found_error = true;
            help_shown = true;
            return true; // Handle the error - this simulates help plugin behavior
        }
        return false;
    }
};

// Create a test registry that simulates pure command groups
fn createPureCommandTestRegistry() type {
    // Only register leaf commands - pure command groups are NOT registered
    return Registry.init(.{
        .app_name = "test-cli",
        .app_version = "1.0.0",
        .app_description = "Test CLI with pure command groups",
    })
        .register("network ls", NetworkLs) // Only the leaf command is registered
        .registerPlugin(TestHelpPlugin)
        .build();
}

test "pure command group behavior: always shows help without error" {
    const TestApp = createPureCommandTestRegistry();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // Test 1: Pure command group without --help should show help and succeed
    TestHelpPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{"network"});

    // Should have triggered CommandNotFound -> help showing -> error handled
    try testing.expect(TestHelpPlugin.help_shown);
    try testing.expect(TestHelpPlugin.command_found_error);

    // Test 2: Pure command group with --help should also show help and succeed
    TestHelpPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "network", "--help" });

    // Should have triggered help showing (same behavior regardless of --help)
    try testing.expect(TestHelpPlugin.help_shown);
}

test "pure command group: subcommands execute normally" {
    const TestApp = createPureCommandTestRegistry();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // Subcommand should execute normally without help plugin intervention
    TestHelpPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "network", "ls" });
    try testing.expect(!TestHelpPlugin.command_found_error); // Should not hit CommandNotFound
}

test "error handling: plugin returns true prevents error propagation" {
    const TestApp = createPureCommandTestRegistry();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // This tests the fix - when a plugin handles CommandNotFound by returning true,
    // the registry should not propagate the error
    TestHelpPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{"nonexistent"});

    // Plugin should have handled the error
    try testing.expect(TestHelpPlugin.command_found_error);
    try testing.expect(TestHelpPlugin.help_shown);
}

// ============================================================================
// Execution-path semantics (guard the executeResolvedCommand refactor):
// metadata-only groups, and error/postExecute dispatch.
// ============================================================================

const MetadataOnlyGroup = struct {
    pub const meta = .{
        .description = "A command group registered without an execute function",
    };
};

test "metadata-only group without a handling plugin reports CommandNotFound" {
    const TestApp = Registry.init(.{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "test",
    })
        .register("group", MetadataOnlyGroup)
        .build();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // No plugin handles CommandNotFound: the group message is printed (stderr
    // noise below is expected) and the error propagates — invoking a bare
    // group is not a success.
    try testing.expectError(
        error.CommandNotFound,
        app.execute(testing.allocator, std.testing.io, &test_environ, &.{"group"}),
    );
}

test "metadata-only group routes through onError so the help plugin can render it" {
    const TestApp = Registry.init(.{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "test",
    })
        .register("group", MetadataOnlyGroup)
        .registerPlugin(TestHelpPlugin)
        .build();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    TestHelpPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{"group"});
    try testing.expect(TestHelpPlugin.command_found_error);
}

const OkCommand = struct {
    pub const Args = zcli.NoArgs;
    pub const Options = zcli.NoOptions;
    pub fn execute(_: Args, _: Options, context: anytype) !void {
        _ = context;
    }
};

const FailingCommand = struct {
    pub const Args = zcli.NoArgs;
    pub const Options = zcli.NoOptions;
    pub fn execute(_: Args, _: Options, context: anytype) !void {
        _ = context;
        return error.Boom;
    }
};

const PostExecuteCapturePlugin = struct {
    var post_execute_success: ?bool = null;
    var seen_error: ?anyerror = null;

    pub fn reset() void {
        post_execute_success = null;
        seen_error = null;
    }

    pub fn onError(context: anytype, err: anyerror) !bool {
        _ = context;
        seen_error = err;
        return err == error.Boom; // handle command failures, not routing errors
    }

    pub fn postExecute(context: anytype, success: bool) !void {
        _ = context;
        post_execute_success = success;
    }
};

fn createPostExecuteTestRegistry() type {
    return Registry.init(.{
        .app_name = "test",
        .app_version = "1.0.0",
        .app_description = "test",
    })
        .register("ok", OkCommand)
        .register("fail", FailingCommand)
        .registerPlugin(PostExecuteCapturePlugin)
        .build();
}

test "successful execution reaches postExecute with success=true" {
    const TestApp = createPostExecuteTestRegistry();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    PostExecuteCapturePlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{"ok"});
    try testing.expectEqual(@as(?bool, true), PostExecuteCapturePlugin.post_execute_success);
    try testing.expectEqual(@as(?anyerror, null), PostExecuteCapturePlugin.seen_error);
}

test "handled execution error is suppressed and reaches postExecute with success=false" {
    const TestApp = createPostExecuteTestRegistry();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    PostExecuteCapturePlugin.reset();
    // onError handles error.Boom, so execute() must not propagate it — but
    // postExecute still observes the failure.
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{"fail"});
    try testing.expectEqual(@as(?anyerror, error.Boom), PostExecuteCapturePlugin.seen_error);
    try testing.expectEqual(@as(?bool, false), PostExecuteCapturePlugin.post_execute_success);
}

test "comptimeJoinPath joins components with spaces" {
    try testing.expectEqualStrings("container run", comptime comptimeJoinPath(&.{ "container", "run" }));
    try testing.expectEqualStrings("root", comptime comptimeJoinPath(&.{"root"}));
    try testing.expectEqualStrings("", comptime comptimeJoinPath(&.{}));
}

test "sortedByPathLengthDesc handles an empty command list" {
    // Regression: the sort used `i < len - 1`, which underflows usize at
    // comptime for a registry with zero regular commands (plugin-only).
    const Entry = struct { path: []const []const u8 };
    const none: [0]Entry = .{};
    const sorted = comptime sortedByPathLengthDesc(&none);
    try testing.expectEqual(@as(usize, 0), sorted.len);
}

// Regression fixture: a registry whose ONLY command comes from a plugin, with
// slice-typed Args/Options fields. Exercises two comptime paths that used to
// be compile errors when first reached: the zero-command routing sort (usize
// underflow) and FieldInfo extraction for slice fields (`.Slice` is not a
// valid `std.builtin.Type.Pointer.Size` literal in 0.16 — it's `.slice`).
const SliceFieldPlugin = struct {
    var executed = false;
    var tag_count: usize = 0;

    pub fn reset() void {
        executed = false;
        tag_count = 0;
    }

    pub const commands = struct {
        pub const tagged = struct {
            pub const meta = .{ .description = "test command with slice fields" };
            pub const Args = struct {
                tags: []const []const u8,
            };
            pub const Options = struct {
                labels: []const []const u8 = &.{},
            };
            pub fn execute(args: Args, options: Options, context: anytype) !void {
                _ = options;
                _ = context;
                SliceFieldPlugin.executed = true;
                SliceFieldPlugin.tag_count = args.tags.len;
            }
        };
    };
};

test "plugin-only registry routes and executes a plugin command with slice fields" {
    const TestApp = Registry.init(.{
        .app_name = "plugin-only",
        .app_version = "1.0.0",
        .app_description = "Registry with zero regular commands",
    })
        .registerPlugin(SliceFieldPlugin)
        .build();

    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    SliceFieldPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "tagged", "a", "b" });

    try testing.expect(SliceFieldPlugin.executed);
    try testing.expectEqual(@as(usize, 2), SliceFieldPlugin.tag_count);
}

// ============================================================================
// Alias Tests
// ============================================================================

test "buildAliasPath: top-level command" {
    // Top-level command ["ls"] with alias "list" should produce ["list"]
    const original_path = &[_][]const u8{"ls"};
    const alias_path = comptime buildAliasPath(original_path, "list");

    try testing.expectEqual(@as(usize, 1), alias_path.len);
    try testing.expectEqualStrings("list", alias_path[0]);
}

test "buildAliasPath: nested command" {
    // Nested command ["container", "ls"] with alias "list" should produce ["container", "list"]
    const original_path = &[_][]const u8{ "container", "ls" };
    const alias_path = comptime buildAliasPath(original_path, "list");

    try testing.expectEqual(@as(usize, 2), alias_path.len);
    try testing.expectEqualStrings("container", alias_path[0]);
    try testing.expectEqualStrings("list", alias_path[1]);
}

test "buildAliasPath: deeply nested command" {
    // Deeply nested command ["a", "b", "c"] with alias "d" should produce ["a", "b", "d"]
    const original_path = &[_][]const u8{ "a", "b", "c" };
    const alias_path = comptime buildAliasPath(original_path, "d");

    try testing.expectEqual(@as(usize, 3), alias_path.len);
    try testing.expectEqualStrings("a", alias_path[0]);
    try testing.expectEqualStrings("b", alias_path[1]);
    try testing.expectEqualStrings("d", alias_path[2]);
}

test "pathsEqual: equal paths" {
    const path1 = &[_][]const u8{ "container", "ls" };
    const path2 = &[_][]const u8{ "container", "ls" };
    try testing.expect(pathsEqual(path1, path2));
}

test "pathsEqual: different lengths" {
    const path1 = &[_][]const u8{ "container", "ls" };
    const path2 = &[_][]const u8{"container"};
    try testing.expect(!pathsEqual(path1, path2));
}

test "pathsEqual: different components" {
    const path1 = &[_][]const u8{ "container", "ls" };
    const path2 = &[_][]const u8{ "container", "list" };
    try testing.expect(!pathsEqual(path1, path2));
}

test "pathsEqual: empty paths" {
    const path1: []const []const u8 = &.{};
    const path2: []const []const u8 = &.{};
    try testing.expect(pathsEqual(path1, path2));
}

// Test command with aliases for registration tests
const AliasTestCommand = struct {
    pub const meta = .{
        .description = "Test command with aliases",
        .aliases = &.{ "alias1", "alias2" },
    };
    pub const Args = zcli.NoArgs;
    pub const Options = zcli.NoOptions;
    pub fn execute(_: Args, _: Options, _: *zcli.Context) !void {}
};

const NoAliasTestCommand = struct {
    pub const meta = .{
        .description = "Test command without aliases",
    };
    pub const Args = zcli.NoArgs;
    pub const Options = zcli.NoOptions;
    pub fn execute(_: Args, _: Options, _: *zcli.Context) !void {}
};

test "alias registration: creates multiple command entries" {
    // Test that computeEntriesWithAliases creates entries for primary + aliases
    const entries = comptime computeEntriesWithAliases(&.{}, "test", AliasTestCommand);

    // Should have 3 entries: primary "test", alias "alias1", alias "alias2"
    try testing.expectEqual(@as(usize, 3), entries.len);
}

test "alias registration: all entries point to same module" {
    const entries = comptime computeEntriesWithAliases(&.{}, "test", AliasTestCommand);

    // All entries should point to the same module
    inline for (entries) |entry| {
        try testing.expect(entry.module == AliasTestCommand);
    }
}

test "alias registration: command without aliases creates single entry" {
    const entries = comptime computeEntriesWithAliases(&.{}, "test", NoAliasTestCommand);

    // Should have only 1 entry
    try testing.expectEqual(@as(usize, 1), entries.len);
}

// Regression fixture for the diagnostic pipeline: a plugin that records what
// context.diagnostic held when its onError hook ran, plus a command with a
// typed option to fail parsing against.
const DiagnosticCapturePlugin = struct {
    var captured: ?zcli.ZcliDiagnostic = null;
    var captured_err: ?anyerror = null;

    pub fn reset() void {
        captured = null;
        captured_err = null;
    }

    pub fn onError(context: anytype, err: anyerror) !bool {
        captured = context.diagnostic;
        captured_err = err;
        return true; // handled — suppress
    }

    pub const commands = struct {
        pub const ping = struct {
            pub const meta = .{ .description = "ping with a typed option" };
            pub const Args = struct {};
            pub const Options = struct { count: u32 = 1 };
            pub fn execute(args: Args, options: Options, context: anytype) !void {
                _ = args;
                _ = options;
                _ = context;
            }
        };
    };
};

test "parse errors run onError with context.diagnostic populated" {
    const TestApp = Registry.init(.{
        .app_name = "diag-test",
        .app_version = "1.0.0",
        .app_description = "diagnostic pipeline test",
    })
        .registerPlugin(DiagnosticCapturePlugin)
        .build();

    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // Unknown option: the plugin sees the error AND the precise diagnostic.
    DiagnosticCapturePlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "ping", "--bogus" });
    try testing.expectEqual(@as(?anyerror, error.OptionUnknown), DiagnosticCapturePlugin.captured_err);
    try testing.expectEqualStrings("bogus", DiagnosticCapturePlugin.captured.?.OptionUnknown.option_name);

    // Invalid value: same pipeline, different diagnostic payload.
    DiagnosticCapturePlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "ping", "--count", "lots" });
    try testing.expectEqual(@as(?anyerror, error.OptionInvalidValue), DiagnosticCapturePlugin.captured_err);
    try testing.expectEqualStrings("lots", DiagnosticCapturePlugin.captured.?.OptionInvalidValue.provided_value);
    try testing.expectEqualStrings("count", DiagnosticCapturePlugin.captured.?.OptionInvalidValue.option_name);
}

// Fixture for the typed-global-options pipeline: declares one global of each
// supported category (also exercising declaration-time type validation),
// records what handleGlobalOption receives, and captures parse failures.
const TypedGlobalsPlugin = struct {
    var level: i64 = -1;
    var ratio: f64 = 0;
    var label: []const u8 = "";
    var verbose: bool = false;
    var debug: bool = false;
    var captured_err: ?anyerror = null;
    var captured_diag: ?zcli.ZcliDiagnostic = null;
    var command_ran: bool = false;

    pub fn reset() void {
        level = -1;
        ratio = 0;
        label = "";
        verbose = false;
        debug = false;
        captured_err = null;
        captured_diag = null;
        command_ran = false;
    }

    pub const global_options = [_]zcli.GlobalOption{
        zcli.option("level", i64, .{ .short = 'l', .description = "level" }),
        zcli.option("ratio", f64, .{ .description = "ratio" }),
        zcli.option("label", []const u8, .{ .description = "label" }),
        zcli.option("verbose", bool, .{ .short = 'v', .description = "verbose" }),
        zcli.option("debug", bool, .{ .short = 'd', .description = "debug" }),
    };

    pub fn handleGlobalOption(context: anytype, name: []const u8, value: anytype) !void {
        _ = context;
        const T = @TypeOf(value);
        if (comptime T == i64) {
            level = value;
        } else if (comptime T == f64) {
            ratio = value;
        } else if (comptime T == []const u8) {
            label = value;
        } else if (comptime T == bool) {
            if (std.mem.eql(u8, name, "verbose")) verbose = value;
            if (std.mem.eql(u8, name, "debug")) debug = value;
        }
    }

    pub fn onError(context: anytype, err: anyerror) !bool {
        captured_err = err;
        captured_diag = context.diagnostic;
        return true;
    }

    pub const commands = struct {
        pub const ping = struct {
            pub const meta = .{ .description = "noop" };
            pub const Args = struct {};
            pub const Options = struct {};
            pub fn execute(args: Args, options: Options, context: anytype) !void {
                _ = args;
                _ = options;
                _ = context;
                TypedGlobalsPlugin.command_ran = true;
            }
        };
    };
};

fn typedGlobalsApp() type {
    return Registry.init(.{
        .app_name = "globals-test",
        .app_version = "1.0.0",
        .app_description = "typed global options",
    })
        .registerPlugin(TypedGlobalsPlugin)
        .build();
}

test "global options: full type set converts and dispatches" {
    const TestApp = typedGlobalsApp();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    TypedGlobalsPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "--level", "5", "--ratio", "1.5", "--label", "hi", "-v", "ping" });
    try testing.expectEqual(@as(i64, 5), TypedGlobalsPlugin.level);
    try testing.expectEqual(@as(f64, 1.5), TypedGlobalsPlugin.ratio);
    try testing.expectEqualStrings("hi", TypedGlobalsPlugin.label);
    try testing.expect(TypedGlobalsPlugin.verbose);
    try testing.expect(TypedGlobalsPlugin.command_ran);
}

test "global options: short options take values (no more assume-boolean)" {
    const TestApp = typedGlobalsApp();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    TypedGlobalsPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "-l", "7", "ping" });
    try testing.expectEqual(@as(i64, 7), TypedGlobalsPlugin.level);
    try testing.expect(TypedGlobalsPlugin.command_ran);

    // Negative values pass the shared next-token rule.
    TypedGlobalsPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "--level", "-5", "ping" });
    try testing.expectEqual(@as(i64, -5), TypedGlobalsPlugin.level);
}

test "global options: boolean bundles are all-or-nothing" {
    const TestApp = typedGlobalsApp();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // All chars are boolean globals: both dispatch.
    TypedGlobalsPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "-vd", "ping" });
    try testing.expect(TypedGlobalsPlugin.verbose);
    try testing.expect(TypedGlobalsPlugin.debug);
    try testing.expect(TypedGlobalsPlugin.command_ran);

    // A bundle containing a non-global char is left for the command parser
    // (which reports it, instead of the old behavior: consuming the token
    // and silently dropping the unknown chars).
    TypedGlobalsPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "ping", "-vx" });
    try testing.expectEqual(@as(?anyerror, error.OptionUnknown), TypedGlobalsPlugin.captured_err);
    try testing.expect(!TypedGlobalsPlugin.command_ran);
}

test "global options: missing and invalid values produce diagnostics" {
    const TestApp = typedGlobalsApp();
    var app = TestApp.init();
    const test_environ = std.process.Environ.Map.init(testing.allocator);

    // Value missing at end of argv.
    TypedGlobalsPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{"--level"});
    try testing.expectEqual(@as(?anyerror, error.OptionMissingValue), TypedGlobalsPlugin.captured_err);
    try testing.expectEqualStrings("level", TypedGlobalsPlugin.captured_diag.?.OptionMissingValue.option_name);

    // Next token is a flag, not a value.
    TypedGlobalsPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "--level", "--verbose" });
    try testing.expectEqual(@as(?anyerror, error.OptionMissingValue), TypedGlobalsPlugin.captured_err);

    // Unparseable value.
    TypedGlobalsPlugin.reset();
    try app.execute(testing.allocator, std.testing.io, &test_environ, &.{ "--level", "abc", "ping" });
    try testing.expectEqual(@as(?anyerror, error.OptionInvalidValue), TypedGlobalsPlugin.captured_err);
    try testing.expectEqualStrings("abc", TypedGlobalsPlugin.captured_diag.?.OptionInvalidValue.provided_value);
    try testing.expectEqualStrings("i64", TypedGlobalsPlugin.captured_diag.?.OptionInvalidValue.expected_type);
}
