const std = @import("std");
const command_parser = @import("command_parser.zig");
const plugin_types = @import("plugin_types.zig");
const zcli = @import("zcli.zig");

// Re-export for convenience
pub const PluginResult = plugin_types.PluginResult;
pub const OptionEvent = plugin_types.OptionEvent;
pub const ErrorEvent = plugin_types.ErrorEvent;

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
            commands ++ [_]CommandEntry{.{ .path = splitPath(path), .module = Module }},
            new_plugins,
        ) {
            _ = self;
            return RegistryBuilder(
                config,
                commands ++ [_]CommandEntry{.{ .path = splitPath(path), .module = Module }},
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
                    // Convert path to string for error message
                    const path_str = std.mem.join(&[_]u8{}, " ", cmd.path);
                    @compileError("Duplicate command path: " ++ path_str);
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
        var plugin_command_paths: []const []const u8 = &.{};
        for (new_plugins) |Plugin| {
            if (@hasDecl(Plugin, "commands")) {
                // Get command names from plugin struct at comptime
                const plugin_cmd_names = blk: {
                    const info = @typeInfo(Plugin.commands);
                    if (info != .@"struct") break :blk &[_][]const u8{};
                    var names: []const []const u8 = &.{};
                    for (info.@"struct".decls) |decl| {
                        names = names ++ .{decl.name};
                    }
                    break :blk names;
                };

                for (plugin_cmd_names) |plugin_cmd_path| {
                    // Check against regular commands
                    for (command_paths) |existing_path| {
                        // Convert plugin path to array for comparison
                        const plugin_path_array = &[_][]const u8{plugin_cmd_path};
                        var paths_equal = existing_path.len == plugin_path_array.len;
                        if (paths_equal) {
                            for (existing_path, 0..) |existing_component, i| {
                                if (!std.mem.eql(u8, existing_component, plugin_path_array[i])) {
                                    paths_equal = false;
                                    break;
                                }
                            }
                        }
                        if (paths_equal) {
                            @compileError("Plugin command conflicts with existing command: " ++ plugin_cmd_path);
                        }
                    }
                    // Check against other plugin commands
                    for (plugin_command_paths) |existing_plugin_path| {
                        if (std.mem.eql(u8, existing_plugin_path, plugin_cmd_path)) {
                            @compileError("Duplicate plugin command: " ++ plugin_cmd_path);
                        }
                    }
                    plugin_command_paths = plugin_command_paths ++ .{plugin_cmd_path};
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

        // Expose commands array for testing and introspection
        pub const commands = cmd_entries;

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

        // Store plugin command info
        const PluginCommandInfo = struct { name: []const u8, plugin_name: []const u8 };
        const plugin_command_info = blk: {
            var info: []const PluginCommandInfo = &.{};
            for (new_plugins) |Plugin| {
                if (@hasDecl(Plugin, "commands")) {
                    const plugin_name = @typeName(Plugin);
                    const cmd_info = @typeInfo(Plugin.commands);
                    if (cmd_info == .@"struct") {
                        for (cmd_info.@"struct".decls) |decl| {
                            info = info ++ .{PluginCommandInfo{ .name = decl.name, .plugin_name = plugin_name }};
                        }
                    }
                }
            }
            break :blk info;
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

        pub fn init() Self {
            return Self{};
        }

        pub fn run_with_args(self: *Self, allocator: std.mem.Allocator, args: []const []const u8) !void {

            // Build list of available commands at compile time
            const available_commands = comptime blk: {
                var cmd_list: []const []const []const u8 = &.{};
                // Add regular commands (paths are already arrays)
                for (cmd_entries) |cmd| {
                    cmd_list = cmd_list ++ .{cmd.path};
                }
                // Add plugin commands (they are single names)
                for (plugin_command_info) |plugin_cmd| {
                    cmd_list = cmd_list ++ .{&.{plugin_cmd.name}};
                }
                break :blk cmd_list;
            };

            // Build command info for plugins at compile time
            const plugin_command_info_list = comptime blk: {
                var cmd_info_list: []const zcli.CommandInfo = &.{};
                // Add regular commands with their metadata
                for (cmd_entries) |cmd| {
                    var description: ?[]const u8 = null;
                    var examples: ?[]const []const u8 = null;

                    if (@hasDecl(cmd.module, "meta")) {
                        const meta = cmd.module.meta;
                        if (@hasField(@TypeOf(meta), "description")) {
                            description = meta.description;
                        }
                        if (@hasField(@TypeOf(meta), "examples")) {
                            examples = meta.examples;
                        }
                    }

                    cmd_info_list = cmd_info_list ++ .{zcli.CommandInfo{
                        .path = cmd.path,
                        .description = description,
                        .examples = examples,
                    }};
                }
                break :blk cmd_info_list;
            };

            var context = zcli.Context{
                .allocator = allocator,
                .io = zcli.IO.init(),
                .environment = zcli.Environment.init(),
                .plugin_extensions = zcli.ContextExtensions.init(allocator),
                .app_name = config.app_name,
                .app_version = config.app_version,
                .app_description = config.app_description,
                .available_commands = available_commands,
                .command_path = &.{},
                .plugin_command_info = plugin_command_info_list,
            };
            defer context.deinit();

            // 1. Run preParse hooks
            var current_args = args;
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "preParse")) {
                    current_args = try Plugin.preParse(&context, current_args);
                }
            }

            // 2. Extract and handle global options
            const global_result = try self.parseGlobalOptions(&context, current_args);
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

        /// Convenient run method that handles process args automatically
        pub fn run(self: *Self, allocator: std.mem.Allocator) !void {
            const args = try std.process.argsAlloc(allocator);
            defer std.process.argsFree(allocator, args);

            try self.run_with_args(allocator, args[1..]);
        }

        pub fn parseGlobalOptions(self: *Self, context: *zcli.Context, args: []const []const u8) !zcli.GlobalOptionsResult {
            var consumed = std.ArrayList(usize).init(context.allocator);
            var remaining = std.ArrayList([]const u8).init(context.allocator);
            defer consumed.deinit();
            defer remaining.deinit();

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
                            try consumed.append(i);

                            var value: []const u8 = "true"; // Default for boolean flags
                            if (global_opt.type != bool and i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                                i += 1;
                                value = args[i];
                                try consumed.append(i);
                            }

                            // Call the plugin's handler
                            inline for (sorted_plugins) |Plugin| {
                                if (@hasDecl(Plugin, "handleGlobalOption") and @hasDecl(Plugin, "global_options")) {
                                    inline for (Plugin.global_options) |plugin_opt| {
                                        if (std.mem.eql(u8, plugin_opt.name, global_opt.name)) {
                                            // Convert value to the appropriate type
                                            const typed_value = try self.convertValue(global_opt.type, value);
                                            try Plugin.handleGlobalOption(context, opt_name, typed_value);
                                            break;
                                        }
                                    }
                                }
                            }

                            handled = true;
                            break;
                        }
                    }
                } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
                    // Handle short options
                    const short_opts = arg[1..];
                    for (short_opts) |short_char| {
                        inline for (global_options) |global_opt| {
                            if (global_opt.short == short_char) {
                                try consumed.append(i);

                                // For short options, assume boolean for now
                                inline for (sorted_plugins) |Plugin| {
                                    if (@hasDecl(Plugin, "handleGlobalOption") and @hasDecl(Plugin, "global_options")) {
                                        inline for (Plugin.global_options) |plugin_opt| {
                                            if (plugin_opt.short == short_char) {
                                                const typed_value = try self.convertValue(global_opt.type, "true");
                                                try Plugin.handleGlobalOption(context, global_opt.name, typed_value);
                                                break;
                                            }
                                        }
                                    }
                                }

                                handled = true;
                                break;
                            }
                        }
                    }
                }

                if (!handled) {
                    try remaining.append(arg);
                }

                i += 1;
            }

            const result = zcli.GlobalOptionsResult{
                .consumed = try consumed.toOwnedSlice(),
                .remaining = try remaining.toOwnedSlice(),
            };
            // Note: Caller is responsible for freeing consumed and remaining arrays
            return result;
        }

        fn convertValue(self: *Self, comptime T: type, value: []const u8) !T {
            _ = self;

            return switch (T) {
                bool => std.mem.eql(u8, value, "true"),
                u16 => try std.fmt.parseInt(u16, value, 10),
                u32 => try std.fmt.parseInt(u32, value, 10),
                []const u8 => value,
                else => @compileError("Unsupported global option type"),
            };
        }

        fn executeCommand(_: *Self, context: *zcli.Context, args: []const []const u8) !void {
            // Handle the case where no command is specified - still run hooks with empty command
            if (args.len == 0) {
                // Run hooks for empty command case
                var parsed_args = zcli.ParsedArgs.init(context.allocator);

                // Run postParse hooks
                inline for (sorted_plugins) |Plugin| {
                    if (@hasDecl(Plugin, "postParse")) {
                        if (try Plugin.postParse(context, parsed_args)) |new_parsed| {
                            parsed_args = new_parsed;
                        }
                    }
                }

                // Run preExecute hooks - this allows help plugin to handle --help with no command
                inline for (sorted_plugins) |Plugin| {
                    if (@hasDecl(Plugin, "preExecute")) {
                        if (try Plugin.preExecute(context, parsed_args)) |new_parsed| {
                            parsed_args = new_parsed;
                        } else {
                            return; // Plugin cancelled execution
                        }
                    }
                }

                // No actual command to execute
                return;
            }

            // Sort commands by path length (longest first) at compile time to ensure longest match wins
            const sorted_commands = comptime blk: {
                var cmds = cmd_entries[0..cmd_entries.len].*;

                // Bubble sort by path length (descending)
                var changed = true;
                while (changed) {
                    changed = false;
                    var i: usize = 0;
                    while (i < cmds.len - 1) : (i += 1) {
                        if (cmds[i].path.len < cmds[i + 1].path.len) {
                            const temp = cmds[i];
                            cmds[i] = cmds[i + 1];
                            cmds[i + 1] = temp;
                            changed = true;
                        }
                    }
                }
                break :blk cmds;
            };

            // Try to find matching command (longest first due to sorting)
            var found = false;
            command_loop: inline for (sorted_commands) |cmd| {

                // Get parts count directly from the path array
                const parts_count: usize = cmd.path.len;

                if (parts_count <= args.len) {
                    // Check if all parts match
                    var parts_match = true;
                    for (cmd.path, 0..) |part, i| {
                        if (i >= args.len or !std.mem.eql(u8, part, args[i])) {
                            parts_match = false;
                            break;
                        }
                    }

                    if (parts_match) {
                        const matched_command = cmd.path;
                        const remaining_args = args[parts_count..];

                        found = true;

                        // Set command_path to the command parts array (already an array)
                        var command_parts = try context.allocator.alloc([]const u8, matched_command.len);
                        for (matched_command, 0..) |part, i| {
                            command_parts[i] = try context.allocator.dupe(u8, part);
                        }
                        context.command_path = command_parts;
                        context.command_path_allocated = true;

                        // Store basic command metadata
                        if (@hasDecl(cmd.module, "meta")) {
                            const meta = cmd.module.meta;
                            context.command_meta = zcli.CommandMeta{
                                .description = if (@hasField(@TypeOf(meta), "description")) meta.description else null,
                                .examples = if (@hasField(@TypeOf(meta), "examples")) meta.examples else null,
                            };
                        }

                        // Extract field info at compile time and allocate for runtime use
                        var args_field_list: []const zcli.FieldInfo = &.{};
                        var options_field_list: []const zcli.FieldInfo = &.{};

                        if (@hasDecl(cmd.module, "Args")) {
                            const ArgsType = cmd.module.Args;
                            const args_type_info = @typeInfo(ArgsType);
                            if (args_type_info == .@"struct") {
                                var field_list = std.ArrayList(zcli.FieldInfo).init(context.allocator);
                                inline for (args_type_info.@"struct".fields) |field| {
                                    const field_type_info = @typeInfo(field.type);
                                    try field_list.append(zcli.FieldInfo{
                                        .name = field.name,
                                        .is_optional = field_type_info == .optional or field.default_value_ptr != null,
                                        .is_array = field_type_info == .pointer and field_type_info.pointer.child != u8,
                                    });
                                }
                                args_field_list = try field_list.toOwnedSlice();
                            }
                        }

                        if (@hasDecl(cmd.module, "Options")) {
                            const OptionsType = cmd.module.Options;
                            const options_type_info = @typeInfo(OptionsType);
                            if (options_type_info == .@"struct") {
                                var field_list = std.ArrayList(zcli.FieldInfo).init(context.allocator);
                                inline for (options_type_info.@"struct".fields) |field| {
                                    const field_type_info = @typeInfo(field.type);
                                    try field_list.append(zcli.FieldInfo{
                                        .name = field.name,
                                        .is_optional = field_type_info == .optional or field.default_value_ptr != null,
                                        .is_array = field_type_info == .pointer and field_type_info.pointer.child != u8,
                                    });
                                }
                                options_field_list = try field_list.toOwnedSlice();
                            }
                        }

                        // Store raw command module info for plugins to introspect
                        context.command_module_info = zcli.CommandModuleInfo{
                            .has_args = @hasDecl(cmd.module, "Args"),
                            .has_options = @hasDecl(cmd.module, "Options"),
                            .raw_meta_ptr = if (@hasDecl(cmd.module, "meta")) &cmd.module.meta else null,
                            .args_fields = args_field_list,
                            .options_fields = options_field_list,
                        };

                        // Run postParse hooks
                        var parsed_args = zcli.ParsedArgs.init(context.allocator);
                        parsed_args.positional = remaining_args;

                        inline for (sorted_plugins) |Plugin| {
                            if (@hasDecl(Plugin, "postParse")) {
                                if (try Plugin.postParse(context, parsed_args)) |new_parsed| {
                                    parsed_args = new_parsed;
                                }
                            }
                        }

                        // Run preExecute hooks
                        inline for (sorted_plugins) |Plugin| {
                            if (@hasDecl(Plugin, "preExecute")) {
                                if (try Plugin.preExecute(context, parsed_args)) |new_parsed| {
                                    parsed_args = new_parsed;
                                } else {
                                    return; // Plugin cancelled execution
                                }
                            }
                        }

                        // Execute the command
                        var success = true;
                        if (@hasDecl(cmd.module, "execute")) {
                            // Use unified parser for mixed arguments and options
                            const full_args = parsed_args.positional;

                            const ArgsType = if (@hasDecl(cmd.module, "Args")) cmd.module.Args else struct {};
                            const OptionsType = if (@hasDecl(cmd.module, "Options")) cmd.module.Options else struct {};
                            const cmd_meta = if (@hasDecl(cmd.module, "meta")) cmd.module.meta else null;

                            // Before parsing, check if this command expects no arguments
                            // but we have arguments that look like subcommands (not options).
                            // This usually means the user was trying to specify a subcommand that doesn't exist.
                            const args_fields = std.meta.fields(ArgsType);
                            if (args_fields.len == 0 and remaining_args.len > 0) {
                                // Check if the first remaining arg looks like a subcommand (doesn't start with -)
                                if (!std.mem.startsWith(u8, remaining_args[0], "-")) {
                                    // Command expects no arguments, but we have what looks like a subcommand
                                    // This looks like a command not found rather than too many arguments
                                    return error.CommandNotFound;
                                }
                            }

                            const parse_result = try command_parser.parseCommandLine(ArgsType, OptionsType, cmd_meta, context.allocator, full_args);
                            defer parse_result.deinit();

                            const args_instance = parse_result.args;
                            const options_instance = parse_result.options;

                            cmd.module.execute(args_instance, options_instance, context) catch |err| {
                                success = false;

                                // Run error hooks
                                inline for (sorted_plugins) |Plugin| {
                                    if (@hasDecl(Plugin, "onError")) {
                                        const handled = try Plugin.onError(context, err);
                                        if (handled) break;
                                    }
                                }

                                return err;
                            };
                        } else {
                            try context.stderr().print("Command '{s}' does not implement execute function\n", .{matched_command});
                            success = false;
                        }

                        // Run postExecute hooks
                        inline for (sorted_plugins) |Plugin| {
                            if (@hasDecl(Plugin, "postExecute")) {
                                try Plugin.postExecute(context, success);
                            }
                        }

                        break :command_loop; // Exit the loop since we found and executed the command
                    }
                }
            }

            // Check plugin commands
            inline for (new_plugins) |Plugin| {
                if (@hasDecl(Plugin, "commands")) {
                    const cmd_info = @typeInfo(Plugin.commands);
                    if (cmd_info == .@"struct") {
                        inline for (cmd_info.@"struct".decls) |decl| {
                            if (std.mem.eql(u8, decl.name, args[0])) {
                                found = true;
                                const plugin_command_name = args[0];
                                const plugin_remaining_args = args[1..];
                                // Set command_path as array with single command
                                var plugin_command_array = try context.allocator.alloc([]const u8, 1);
                                plugin_command_array[0] = try context.allocator.dupe(u8, plugin_command_name);
                                context.command_path = plugin_command_array;
                                context.command_path_allocated = true;

                                // Run postParse hooks
                                var parsed_args = zcli.ParsedArgs.init(context.allocator);
                                parsed_args.positional = plugin_remaining_args;

                                inline for (sorted_plugins) |HookPlugin| {
                                    if (@hasDecl(HookPlugin, "postParse")) {
                                        if (try HookPlugin.postParse(context, parsed_args)) |new_parsed| {
                                            parsed_args = new_parsed;
                                        }
                                    }
                                }

                                // Run preExecute hooks
                                inline for (sorted_plugins) |HookPlugin| {
                                    if (@hasDecl(HookPlugin, "preExecute")) {
                                        if (try HookPlugin.preExecute(context, parsed_args)) |new_parsed| {
                                            parsed_args = new_parsed;
                                        } else {
                                            return; // Plugin cancelled execution
                                        }
                                    }
                                }

                                // Execute the plugin command
                                var success = true;

                                const CommandModule = @field(Plugin.commands, decl.name);

                                // Parse args and options using unified parser
                                const ArgsType = if (@hasDecl(CommandModule, "Args")) CommandModule.Args else struct {};
                                const OptionsType = if (@hasDecl(CommandModule, "Options")) CommandModule.Options else struct {};
                                const cmd_meta = if (@hasDecl(CommandModule, "meta")) CommandModule.meta else null;

                                const parse_result = try command_parser.parseCommandLine(
                                    ArgsType,
                                    OptionsType,
                                    cmd_meta,
                                    context.allocator,
                                    parsed_args.positional,
                                );
                                defer parse_result.deinit();

                                const cmd_args = parse_result.args;
                                const cmd_options = parse_result.options;

                                if (@hasDecl(CommandModule, "execute")) {
                                    CommandModule.execute(cmd_args, cmd_options, context) catch |err| {
                                        success = false;
                                        // Run onError hooks
                                        inline for (sorted_plugins) |HookPlugin| {
                                            if (@hasDecl(HookPlugin, "onError")) {
                                                const handled = try HookPlugin.onError(context, err);
                                                if (handled) break;
                                            }
                                        }
                                        return err;
                                    };
                                } else {
                                    try context.stderr().print("Plugin command '{s}' does not implement execute function\n", .{plugin_command_name});
                                    success = false;
                                }

                                // Run postExecute hooks
                                inline for (sorted_plugins) |HookPlugin| {
                                    if (@hasDecl(HookPlugin, "postExecute")) {
                                        try HookPlugin.postExecute(context, success);
                                    }
                                }

                                return;
                            }
                        }
                    }
                }
            }

            if (!found) {
                // Set command_path to the attempted command parts for error handling
                var attempted_command_array = try context.allocator.alloc([]const u8, 1);
                attempted_command_array[0] = try context.allocator.dupe(u8, args[0]);
                context.command_path = attempted_command_array;
                context.command_path_allocated = true;

                // Run onError hooks for CommandNotFound
                var error_handled = false;
                inline for (sorted_plugins) |Plugin| {
                    if (@hasDecl(Plugin, "onError")) {
                        const handled = try Plugin.onError(context, error.CommandNotFound);
                        if (handled) {
                            error_handled = true;
                            break; // Stop processing further error handlers
                        }
                    }
                }

                // If no plugin handled the error, print a basic message and return error
                if (!error_handled) {
                    const cmd_name = if (context.command_path.len > 0) context.command_path[0] else "unknown";
                    try context.stderr().print("command {s} not found\n", .{cmd_name});
                    return error.CommandNotFound;
                }
                
                // Plugin handled the error, so we don't return an error
                return;
            }
        }

        // Testing/introspection methods for the test suite
        pub fn getGlobalOptions(self: *Self) []const plugin_types.GlobalOption {
            _ = self;
            return global_options;
        }

        pub fn getPluginCommandInfo(self: *Self) []const PluginCommandInfo {
            _ = self;
            return plugin_command_info;
        }

        pub fn transformArgs(self: *Self, context: *zcli.Context, args: []const []const u8) !zcli.TransformResult {
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
