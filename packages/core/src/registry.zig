const std = @import("std");
const command_parser = @import("command_parser.zig");
const plugin_types = @import("plugin_types.zig");
const zcli = @import("zcli.zig");
const testing = std.testing;

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

        pub fn execute(self: *Self, args: []const []const u8) !void {
            const allocator = std.heap.page_allocator;

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
                // Add plugin commands (they are single names)
                for (plugin_command_info) |plugin_cmd| {
                    cmd_list = cmd_list ++ .{&.{plugin_cmd.name}};
                }
                break :blk cmd_list;
            };

            // Build command info for plugins at compile time
            const plugin_command_info_list = comptime blk: {
                var cmd_info_list: []const zcli.CommandInfo = &.{};
                // Add regular commands with their metadata, but skip "root"
                for (cmd_entries) |cmd| {
                    // Skip root command from the visible commands list
                    if (cmd.path.len == 1 and std.mem.eql(u8, cmd.path[0], "root")) {
                        continue;
                    }

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

            try self.execute(args[1..]);
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

        fn executeCommand(_: *Self, context: *zcli.Context, args_input: []const []const u8) !void {
            // Check if we should use the root command
            // Root command is executed when:
            // 1. No arguments provided, OR
            // 2. First argument starts with '-' (it's an option, not a command)
            const use_root_command = blk: {
                if (args_input.len == 0) {
                    break :blk true;
                }
                // Check if first arg is an option (starts with -)
                if (args_input.len > 0 and std.mem.startsWith(u8, args_input[0], "-")) {
                    break :blk true;
                }
                break :blk false;
            };

            // Determine which args to use
            const args = if (use_root_command) blk: {
                // Check if there's a root command
                const root_exists = comptime check: {
                    for (cmd_entries) |cmd| {
                        if (cmd.path.len == 1 and std.mem.eql(u8, cmd.path[0], "root")) {
                            break :check true;
                        }
                    }
                    break :check false;
                };

                if (root_exists) {
                    // Create args array with "root" prepended (but this is internal only)
                    // We'll still pass the original args to the command for option parsing
                    const root_args = [_][]const u8{"root"};
                    break :blk &root_args;
                } else {
                    break :blk args_input;
                }
            } else args_input;

            // Handle the case where no command is specified and no root command exists
            if (args.len == 0) {
                // No root command - run hooks for empty command case
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

                // No actual command to execute - trigger CommandNotFound so help plugin can handle it
                var error_handled = false;
                inline for (sorted_plugins) |Plugin| {
                    if (@hasDecl(Plugin, "onError")) {
                        error_handled = try Plugin.onError(context, error.CommandNotFound) or error_handled;
                    }
                }

                if (!error_handled) {
                    try context.stderr().print("No command specified. Use --help for usage information.\n", .{});
                    return error.CommandNotFound;
                }
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
                        // For root command, use original args (they're all options/args for root)
                        // For other commands, skip the command parts
                        const remaining_args = if (use_root_command and std.mem.eql(u8, cmd.path[0], "root"))
                            args_input // Use original args for root command
                        else
                            args[parts_count..]; // Skip command parts for regular commands

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

                                    // Extract metadata from meta.options
                                    var short: ?u8 = null;
                                    var description: ?[]const u8 = null;

                                    // Extract from meta.options in module
                                    if (@hasDecl(cmd.module, "meta")) {
                                        const meta = cmd.module.meta;
                                        if (@hasField(@TypeOf(meta), "options")) {
                                            const options_meta = meta.options;
                                            if (@hasField(@TypeOf(options_meta), field.name)) {
                                                const field_meta = @field(options_meta, field.name);
                                                if (@hasField(@TypeOf(field_meta), "short")) {
                                                    short = field_meta.short;
                                                }
                                                if (@hasField(@TypeOf(field_meta), "desc")) {
                                                    description = field_meta.desc;
                                                }
                                            }
                                        }
                                    }

                                    try field_list.append(zcli.FieldInfo{
                                        .name = field.name,
                                        .is_optional = field_type_info == .optional or field.default_value_ptr != null,
                                        .is_array = field_type_info == .pointer and field_type_info.pointer.child != u8,
                                        .short = short,
                                        .description = description,
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
        pub fn getGlobalOptions() []const plugin_types.GlobalOption {
            return global_options;
        }

        pub fn getPluginCommandInfo() []const PluginCommandInfo {
            return plugin_command_info;
        }

        pub fn transformArgs(self: @This(), context: *zcli.Context, args: []const []const u8) !zcli.TransformResult {
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

fn createTestCommands(allocator: std.mem.Allocator) !build_utils.DiscoveredCommands {
    var commands = build_utils.DiscoveredCommands.init(allocator);

    // Create a pure command group (no index.zig)
    var network_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);

    // Create path array properly
    var network_ls_path = try allocator.alloc([]const u8, 2);
    network_ls_path[0] = try allocator.dupe(u8, "network");
    network_ls_path[1] = try allocator.dupe(u8, "ls");

    const network_ls = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "ls"),
        .path = network_ls_path,
        .file_path = try allocator.dupe(u8, "network/ls.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try network_subcommands.put(try allocator.dupe(u8, "ls"), network_ls);

    var network_path = try allocator.alloc([]const u8, 1);
    network_path[0] = try allocator.dupe(u8, "network");

    const network_group = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "network"),
        .path = network_path,
        .file_path = try allocator.dupe(u8, "network"), // No index.zig
        .command_type = .pure_group,
        .subcommands = network_subcommands,
    };
    try commands.root.put(try allocator.dupe(u8, "network"), network_group);

    // Create an optional command group (with index.zig)
    var container_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);
    var container_run_path = try allocator.alloc([]const u8, 2);
    container_run_path[0] = try allocator.dupe(u8, "container");
    container_run_path[1] = try allocator.dupe(u8, "run");

    const container_run = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "run"),
        .path = container_run_path,
        .file_path = try allocator.dupe(u8, "container/run.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try container_subcommands.put(try allocator.dupe(u8, "run"), container_run);

    var container_path = try allocator.alloc([]const u8, 1);
    container_path[0] = try allocator.dupe(u8, "container");

    const container_group = build_utils.CommandInfo{
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

    const version_cmd = build_utils.CommandInfo{
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

    const config = build_utils.BuildConfig{
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

    const config = build_utils.BuildConfig{
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
    var commands = build_utils.DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // Create nested structure: docker -> compose (pure) -> up (leaf)
    var compose_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);

    var compose_up_path = try allocator.alloc([]const u8, 3);
    compose_up_path[0] = try allocator.dupe(u8, "docker");
    compose_up_path[1] = try allocator.dupe(u8, "compose");
    compose_up_path[2] = try allocator.dupe(u8, "up");

    const compose_up = build_utils.CommandInfo{
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

    const compose_group = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "compose"),
        .path = compose_path,
        .file_path = try allocator.dupe(u8, "docker/compose"),
        .command_type = .pure_group,
        .subcommands = compose_subcommands,
    };

    // Docker is an optional group
    var docker_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);
    try docker_subcommands.put(try allocator.dupe(u8, "compose"), compose_group);

    var docker_path = try allocator.alloc([]const u8, 1);
    docker_path[0] = try allocator.dupe(u8, "docker");

    const docker_group = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "docker"),
        .path = docker_path,
        .file_path = try allocator.dupe(u8, "docker/index.zig"),
        .command_type = .optional_group,
        .subcommands = docker_subcommands,
    };
    try commands.root.put(try allocator.dupe(u8, "docker"), docker_group);

    // Generate code
    const config = build_utils.BuildConfig{
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
    var commands = build_utils.DiscoveredCommands.init(allocator);
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
    var commands = build_utils.DiscoveredCommands.init(allocator);
    defer commands.deinit();

    // Create a structure with both pure and optional groups at same level
    var app_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);

    // Pure group
    var pure_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);

    var pure_cmd_path = try allocator.alloc([]const u8, 2);
    pure_cmd_path[0] = try allocator.dupe(u8, "pure");
    pure_cmd_path[1] = try allocator.dupe(u8, "list");

    const pure_cmd = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "list"),
        .path = pure_cmd_path,
        .file_path = try allocator.dupe(u8, "pure/list.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try pure_subcommands.put(try allocator.dupe(u8, "list"), pure_cmd);

    var pure_path = try allocator.alloc([]const u8, 1);
    pure_path[0] = try allocator.dupe(u8, "pure");

    const pure_group = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "pure"),
        .path = pure_path,
        .file_path = try allocator.dupe(u8, "pure"),
        .command_type = .pure_group,
        .subcommands = pure_subcommands,
    };
    try app_subcommands.put(try allocator.dupe(u8, "pure"), pure_group);

    // Optional group
    var optional_subcommands = std.StringHashMap(build_utils.CommandInfo).init(allocator);

    var optional_cmd_path = try allocator.alloc([]const u8, 2);
    optional_cmd_path[0] = try allocator.dupe(u8, "optional");
    optional_cmd_path[1] = try allocator.dupe(u8, "exec");

    const optional_cmd = build_utils.CommandInfo{
        .name = try allocator.dupe(u8, "exec"),
        .path = optional_cmd_path,
        .file_path = try allocator.dupe(u8, "optional/exec.zig"),
        .command_type = .leaf,
        .subcommands = null,
    };
    try optional_subcommands.put(try allocator.dupe(u8, "exec"), optional_cmd);

    var optional_path = try allocator.alloc([]const u8, 1);
    optional_path[0] = try allocator.dupe(u8, "optional");

    const optional_group = build_utils.CommandInfo{
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

    pub fn execute(_: Args, _: Options, context: *zcli.Context) !void {
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

    pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
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

    // Test command path sorting - longer paths should come first (simulating registry logic)
    const sorted_commands = comptime blk: {
        var cmds = commands[0..commands.len].*;

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
    pub fn execute(_: Args, _: Options, context: *zcli.Context) !void {
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

    pub fn onError(context: *zcli.Context, err: anyerror) !bool {
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

    // Test 1: Pure command group without --help should show help and succeed
    TestHelpPlugin.reset();
    try app.execute(&.{"network"});

    // Should have triggered CommandNotFound -> help showing -> error handled
    try testing.expect(TestHelpPlugin.help_shown);
    try testing.expect(TestHelpPlugin.command_found_error);

    // Test 2: Pure command group with --help should also show help and succeed
    TestHelpPlugin.reset();
    try app.execute(&.{ "network", "--help" });

    // Should have triggered help showing (same behavior regardless of --help)
    try testing.expect(TestHelpPlugin.help_shown);
}

test "pure command group: subcommands execute normally" {
    const TestApp = createPureCommandTestRegistry();
    var app = TestApp.init();

    // Subcommand should execute normally without help plugin intervention
    TestHelpPlugin.reset();
    try app.execute(&.{ "network", "ls" });
    try testing.expect(!TestHelpPlugin.command_found_error); // Should not hit CommandNotFound
}

test "error handling: plugin returns true prevents error propagation" {
    const TestApp = createPureCommandTestRegistry();
    var app = TestApp.init();

    // This tests the fix - when a plugin handles CommandNotFound by returning true,
    // the registry should not propagate the error
    TestHelpPlugin.reset();
    try app.execute(&.{"nonexistent"});

    // Plugin should have handled the error
    try testing.expect(TestHelpPlugin.command_found_error);
    try testing.expect(TestHelpPlugin.help_shown);
}
