const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const plugin_types = @import("plugin_types.zig");
const zcli = @import("zcli.zig");

// Re-export for convenience
pub const PluginResult = plugin_types.PluginResult;
pub const OptionEvent = plugin_types.OptionEvent;
pub const ErrorEvent = plugin_types.ErrorEvent;

/// Configuration for the application
pub const Config = struct {
    app_name: []const u8,
    app_version: []const u8,
    app_description: []const u8,
};

/// Command entry for the registry
pub const CommandEntry = struct {
    path: []const u8,
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

        pub fn register(comptime self: @This(), comptime path: []const u8, comptime Module: type) RegistryBuilder(config, commands ++ [_]CommandEntry{.{ .path = path, .module = Module }}, new_plugins) {
            _ = self;
            return RegistryBuilder(config, commands ++ [_]CommandEntry{.{ .path = path, .module = Module }}, new_plugins).init();
        }

        pub fn registerPlugin(comptime self: @This(), comptime Plugin: type) RegistryBuilder(config, commands, new_plugins ++ [_]type{Plugin}) {
            _ = self;
            return RegistryBuilder(config, commands, new_plugins ++ [_]type{Plugin}).init();
        }

        pub fn build(comptime self: @This()) type {
            _ = self;
            return CompiledRegistry(config, commands, new_plugins);
        }
    };
}

/// Compiled registry with all command and plugin information
fn CompiledRegistry(comptime config: Config, comptime commands: []const CommandEntry, comptime new_plugins: []const type) type {
    // Validate plugin conflicts at compile time
    comptime {
        // Use arrays to check for conflicts since ComptimeStringMap may not be available
        var global_option_names: []const []const u8 = &.{};
        var command_paths: []const []const u8 = &.{};

        // Check for command path conflicts among regular commands
        for (commands) |cmd| {
            for (command_paths) |existing_path| {
                if (std.mem.eql(u8, existing_path, cmd.path)) {
                    @compileError("Duplicate command path: " ++ cmd.path);
                }
            }
            command_paths = command_paths ++ .{cmd.path};
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
                        if (std.mem.eql(u8, existing_path, plugin_cmd_path)) {
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
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            const allocator = gpa.allocator();

            // Build list of available commands at compile time
            const available_commands = comptime blk: {
                var cmd_list: []const []const u8 = &.{};
                // Add regular commands
                for (commands) |cmd| {
                    cmd_list = cmd_list ++ .{cmd.path};
                }
                // Add plugin commands
                for (plugin_command_info) |plugin_cmd| {
                    cmd_list = cmd_list ++ .{plugin_cmd.name};
                }
                break :blk cmd_list;
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
                .current_command = null,
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

        fn executeCommand(self: *Self, context: *zcli.Context, args: []const []const u8) !void {
            // Handle the case where no command is specified - still run hooks with empty command
            if (args.len == 0) {
                // Run hooks for empty command case
                var parsed_args = zcli.ParsedArgs.init(context.allocator);
                
                // Run postParse hooks
                inline for (sorted_plugins) |Plugin| {
                    if (@hasDecl(Plugin, "postParse")) {
                        if (try Plugin.postParse(context, "", parsed_args)) |new_parsed| {
                            parsed_args = new_parsed;
                        }
                    }
                }
                
                // Run preExecute hooks - this allows help plugin to handle --help with no command
                inline for (sorted_plugins) |Plugin| {
                    if (@hasDecl(Plugin, "preExecute")) {
                        if (try Plugin.preExecute(context, "", parsed_args)) |new_parsed| {
                            parsed_args = new_parsed;
                        } else {
                            return; // Plugin cancelled execution
                        }
                    }
                }
                
                // No actual command to execute
                return;
            }

            // Try to find matching command
            const command_name = args[0];
            const remaining_args = args[1..];

            // Check regular commands first
            var found = false;
            inline for (commands) |cmd| {
                if (std.mem.eql(u8, cmd.path, command_name)) {
                    found = true;

                    // Run postParse hooks
                    var parsed_args = zcli.ParsedArgs.init(context.allocator);
                    parsed_args.positional = remaining_args;

                    inline for (sorted_plugins) |Plugin| {
                        if (@hasDecl(Plugin, "postParse")) {
                            if (try Plugin.postParse(context, command_name, parsed_args)) |new_parsed| {
                                parsed_args = new_parsed;
                            }
                        }
                    }

                    // Run preExecute hooks
                    inline for (sorted_plugins) |Plugin| {
                        if (@hasDecl(Plugin, "preExecute")) {
                            if (try Plugin.preExecute(context, command_name, parsed_args)) |new_parsed| {
                                parsed_args = new_parsed;
                            } else {
                                return; // Plugin cancelled execution
                            }
                        }
                    }

                    // Execute the command
                    var success = true;
                    if (@hasDecl(cmd.module, "execute")) {
                        // Use the original remaining_args for parsing both args and options
                        // This ensures options are available to parseOptions
                        const final_args = parsed_args.positional;

                        const args_instance = if (@hasDecl(cmd.module, "Args"))
                            try self.parseArgs(cmd.module.Args, final_args)
                        else
                            struct {}{};

                        const options_instance = if (@hasDecl(cmd.module, "Options"))
                            try self.parseOptions(cmd.module.Options, final_args, context.allocator)
                        else
                            struct {}{};

                        cmd.module.execute(args_instance, options_instance, context) catch |err| {
                            success = false;

                            // Run error hooks
                            inline for (sorted_plugins) |Plugin| {
                                if (@hasDecl(Plugin, "onError")) {
                                    try Plugin.onError(context, err, command_name);
                                }
                            }

                            return err;
                        };
                    } else {
                        try context.stderr().print("Command '{s}' does not implement execute function\n", .{cmd.path});
                        success = false;
                    }

                    // Run postExecute hooks
                    inline for (sorted_plugins) |Plugin| {
                        if (@hasDecl(Plugin, "postExecute")) {
                            try Plugin.postExecute(context, command_name, success);
                        }
                    }

                    return;
                }
            }

            // Check plugin commands
            inline for (new_plugins) |Plugin| {
                if (@hasDecl(Plugin, "commands")) {
                    const cmd_info = @typeInfo(Plugin.commands);
                    if (cmd_info == .@"struct") {
                        inline for (cmd_info.@"struct".decls) |decl| {
                            if (std.mem.eql(u8, decl.name, command_name)) {
                                found = true;

                                // Run postParse hooks
                                var parsed_args = zcli.ParsedArgs.init(context.allocator);
                                parsed_args.positional = remaining_args;

                                inline for (sorted_plugins) |HookPlugin| {
                                    if (@hasDecl(HookPlugin, "postParse")) {
                                        if (try HookPlugin.postParse(context, command_name, parsed_args)) |new_parsed| {
                                            parsed_args = new_parsed;
                                        }
                                    }
                                }

                                // Run preExecute hooks
                                inline for (sorted_plugins) |HookPlugin| {
                                    if (@hasDecl(HookPlugin, "preExecute")) {
                                        if (try HookPlugin.preExecute(context, command_name, parsed_args)) |new_parsed| {
                                            parsed_args = new_parsed;
                                        } else {
                                            return; // Plugin cancelled execution
                                        }
                                    }
                                }

                                // Execute the plugin command
                                var success = true;

                                const CommandModule = @field(Plugin.commands, decl.name);

                                // Parse args and options like regular commands
                                const cmd_args = if (@hasDecl(CommandModule, "Args"))
                                    try self.parseArgs(CommandModule.Args, parsed_args.positional)
                                else
                                    struct {}{};

                                const cmd_options = if (@hasDecl(CommandModule, "Options"))
                                    try self.parseOptions(CommandModule.Options, parsed_args.positional, context.allocator)
                                else
                                    struct {}{};

                                if (@hasDecl(CommandModule, "execute")) {
                                    CommandModule.execute(cmd_args, cmd_options, context) catch |err| {
                                        success = false;
                                        // Run onError hooks
                                        inline for (sorted_plugins) |HookPlugin| {
                                            if (@hasDecl(HookPlugin, "onError")) {
                                                try HookPlugin.onError(context, err, command_name);
                                            }
                                        }
                                        return err;
                                    };
                                } else {
                                    try context.stderr().print("Plugin command '{s}' does not implement execute function\n", .{command_name});
                                    success = false;
                                }

                                // Run postExecute hooks
                                inline for (sorted_plugins) |HookPlugin| {
                                    if (@hasDecl(HookPlugin, "postExecute")) {
                                        try HookPlugin.postExecute(context, command_name, success);
                                    }
                                }

                                return;
                            }
                        }
                    }
                }
            }

            if (!found) {
                // Store the command name for error handling
                context.current_command = command_name;
                
                // Run onError hooks for CommandNotFound
                var error_handled = false;
                inline for (sorted_plugins) |Plugin| {
                    if (@hasDecl(Plugin, "onError")) {
                        try Plugin.onError(context, error.CommandNotFound, command_name);
                        error_handled = true; // If any plugin has onError, consider it handled
                    }
                }
                
                // If no plugin handled the error, print a basic message
                if (!error_handled) {
                    try context.stderr().print("command {s} not found\n", .{command_name});
                }
                
                // Return the error regardless
                return error.CommandNotFound;
            }
        }

        /// Parse arguments for a command (fixed use-after-free bug)
        fn parseArgs(self: *Self, comptime ArgsType: type, raw_args: []const []const u8) !ArgsType {
            _ = self;

            const fields = std.meta.fields(ArgsType);
            if (fields.len == 0) {
                return ArgsType{};
            }

            var result: ArgsType = undefined;

            // Work directly with raw_args to find positional arguments
            // No dynamic allocation needed - fixes use-after-free bug
            
            // Assign positional arguments to fields directly from raw_args
            inline for (fields, 0..) |field, field_idx| {
                switch (field.type) {
                    []const u8 => {
                        // Find the field_idx-th positional argument in raw_args
                        var found_count: usize = 0;
                        var found = false;
                        
                        var i: usize = 0;
                        while (i < raw_args.len) {
                            const arg = raw_args[i];
                            if (std.mem.startsWith(u8, arg, "-")) {
                                // Skip option
                                i += 1;
                                // Skip option value if it doesn't start with -
                                if (i < raw_args.len and !std.mem.startsWith(u8, raw_args[i], "-")) {
                                    i += 1;
                                }
                            } else {
                                // This is a positional argument
                                if (found_count == field_idx) {
                                    @field(result, field.name) = arg;
                                    found = true;
                                    break;
                                }
                                found_count += 1;
                                i += 1;
                            }
                        }
                        
                        if (!found) {
                            // Required field missing
                            try std.io.getStdErr().writer().print("Error: Missing required argument '{s}'\n", .{field.name});
                            return error.MissingArgument;
                        }
                    },
                    ?[]const u8 => {
                        // Find the field_idx-th positional argument in raw_args (optional)
                        var found_count: usize = 0;
                        var found = false;
                        
                        var i: usize = 0;
                        while (i < raw_args.len) {
                            const arg = raw_args[i];
                            if (std.mem.startsWith(u8, arg, "-")) {
                                // Skip option
                                i += 1;
                                // Skip option value if it doesn't start with -
                                if (i < raw_args.len and !std.mem.startsWith(u8, raw_args[i], "-")) {
                                    i += 1;
                                }
                            } else {
                                // This is a positional argument
                                if (found_count == field_idx) {
                                    @field(result, field.name) = arg;
                                    found = true;
                                    break;
                                }
                                found_count += 1;
                                i += 1;
                            }
                        }
                        
                        if (!found) {
                            @field(result, field.name) = null;
                        }
                    },
                    else => {
                        // Initialize other types with default/undefined values
                        @field(result, field.name) = @as(field.type, undefined);
                    },
                }
            }

            return result;
        }

        /// Parse options for a command (using the real options parser)
        fn parseOptions(self: *Self, comptime OptionsType: type, raw_args: []const []const u8, allocator: std.mem.Allocator) !OptionsType {
            _ = self;
            const parse_result = options_parser.parseOptions(OptionsType, allocator, raw_args);

            if (parse_result.isError()) {
                return OptionsType{};
            }

            const parsed = parse_result.unwrap();
            return parsed.options;
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
