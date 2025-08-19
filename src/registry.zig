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

/// Plugin entry for the registry
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
fn RegistryBuilder(comptime config: Config, comptime commands: []const CommandEntry, comptime plugins: []const PluginEntry) type {
    return struct {
        pub fn init() @This() {
            return @This(){};
        }
        
        pub fn register(comptime self: @This(), comptime path: []const u8, comptime Module: type) RegistryBuilder(config, commands ++ [_]CommandEntry{.{ .path = path, .module = Module }}, plugins) {
            _ = self;
            return RegistryBuilder(config, commands ++ [_]CommandEntry{.{ .path = path, .module = Module }}, plugins).init();
        }
        
        pub fn registerPlugin(comptime self: @This(), comptime Plugin: type) RegistryBuilder(config, commands, plugins ++ [_]PluginEntry{.{ .plugin = Plugin }}) {
            _ = self;
            return RegistryBuilder(config, commands, plugins ++ [_]PluginEntry{.{ .plugin = Plugin }}).init();
        }
        
        pub fn build(comptime self: @This()) CompiledRegistry(config, commands, plugins) {
            _ = self;
            return CompiledRegistry(config, commands, plugins).init();
        }
    };
}

/// Compiled registry with all command and plugin information
fn CompiledRegistry(comptime config: Config, comptime commands: []const CommandEntry, comptime plugins: []const PluginEntry) type {
    return struct {
        const Self = @This();
        
        /// Context type expected by zcli.App
        pub const Context = struct {
            allocator: std.mem.Allocator,
            
            pub fn init(allocator: std.mem.Allocator) @This() {
                return .{ .allocator = allocator };
            }
            
            pub fn deinit(self: *@This()) void {
                _ = self;
            }
        };
        
        pub fn init() Self {
            return Self{};
        }
        
        pub fn execute(self: *Self, args: []const []const u8) !void {
            try std.io.getStdOut().writer().print("{s} v{s}\n", .{ config.app_name, config.app_version });
            try std.io.getStdOut().writer().print("{s}\n\n", .{config.app_description});
            
            if (args.len == 0) {
                try std.io.getStdOut().writer().print("Available commands:\n", .{});
                inline for (commands) |cmd| {
                    try std.io.getStdOut().writer().print("  {s}\n", .{cmd.path});
                }
                return;
            }
            
            // Route to the appropriate command with hierarchical resolution
            return self.executeCommand(args);
        }
        
        fn executeCommand(self: *Self, args_input: []const []const u8) !void {
            
            // Try to find the best matching command by building command paths
            // For "users search", try:
            // 1. "users.search" (exact match)
            // 2. "users" (fallback to group command)
            
            var path_buffer: [256]u8 = undefined; // Buffer for command path building
            
            // Try different command path combinations, starting with longest match
            var arg_count = args_input.len;
            while (arg_count > 0) : (arg_count -= 1) {
                const command_path = self.buildCommandPath(args_input[0..arg_count], &path_buffer);
                
                inline for (commands) |cmd| {
                    if (std.mem.eql(u8, cmd.path, command_path)) {
                        const remaining_args = args_input[arg_count..];
                        try self.executeMatchedCommand(cmd, remaining_args);
                        return;
                    }
                }
            }
            
            // If no exact match found, try the first argument as command name
            const command_name = args_input[0];
            inline for (commands) |cmd| {
                if (std.mem.eql(u8, cmd.path, command_name)) {
                    const remaining_args = args_input[1..];
                    try self.executeMatchedCommand(cmd, remaining_args);
                    return;
                }
            }
            
            try std.io.getStdOut().writer().print("Unknown command: {s}\n", .{args_input[0]});
        }
        
        fn buildCommandPath(self: *Self, args: []const []const u8, buffer: []u8) []const u8 {
            _ = self;
            if (args.len == 0) return "";
            if (args.len == 1) return args[0];
            
            // Join arguments with dots: ["users", "search"] -> "users.search"
            var pos: usize = 0;
            for (args, 0..) |arg, i| {
                if (i > 0) {
                    if (pos < buffer.len) {
                        buffer[pos] = '.';
                        pos += 1;
                    }
                }
                for (arg) |c| {
                    if (pos < buffer.len) {
                        buffer[pos] = c;
                        pos += 1;
                    }
                }
            }
            
            return buffer[0..pos];
        }
        
        fn executeMatchedCommand(self: *Self, cmd: CommandEntry, remaining_args: []const []const u8) !void {
            
            if (@hasDecl(cmd.module, "execute")) {
                var cmd_context = zcli.Context{
                    .allocator = std.heap.page_allocator, // TODO: pass proper allocator
                    .io = zcli.IO.init(),
                    .environment = zcli.Environment.init(),
                };
                
                // 1. Run plugin pipeline on all raw arguments
                const unhandled_args = try self.runPluginPipeline(cmd, remaining_args, &cmd_context);
                
                // If plugins handled everything and stopped execution, we're done
                if (unhandled_args == null) {
                    return;
                }
                
                // 2. Parse remaining args and options for this command  
                const args_instance = if (@hasDecl(cmd.module, "Args"))
                    try self.parseArgs(cmd.module.Args, unhandled_args.?)
                else
                    struct{}{};
                    
                const options_instance = if (@hasDecl(cmd.module, "Options"))
                    try self.parseOptions(cmd.module.Options, unhandled_args.?)
                else
                    struct{}{};
                
                // 3. Execute the command with remaining args/options
                try cmd.module.execute(args_instance, options_instance, &cmd_context);
            } else {
                try std.io.getStdOut().writer().print("Command '{s}' does not implement execute function\n", .{cmd.path});
            }
        }
        
        /// Run the plugin pipeline on raw arguments, allowing plugins to consume options
        /// Returns null if plugins handled everything and want to stop execution
        /// Returns the remaining unhandled args otherwise
        fn runPluginPipeline(self: *Self, cmd: CommandEntry, raw_args: []const []const u8, context: *zcli.Context) !?[]const []const u8 {
            
            // Create plugin context with command metadata
            const metadata = if (@hasDecl(cmd.module, "meta"))
                convertCommandMeta(cmd.module.meta)
            else
                zcli.plugin_types.Metadata{};
                
            const plugin_context = zcli.plugin_types.PluginContext{
                .command_path = cmd.path,
                .metadata = metadata,
            };
            
            // Run each option through the plugin pipeline
            for (raw_args) |arg| {
                if (std.mem.startsWith(u8, arg, "-")) {
                    // This is an option, run it through plugins
                    const event = zcli.OptionEvent{
                        .option = arg,
                        .plugin_context = plugin_context,
                    };
                    
                    // Call each plugin with the command module type for introspection
                    const result = try self.callPluginPipeline(context, event, cmd.module);
                    if (result != null and result.?.handled) {
                        // Plugin handled this option
                        if (result.?.output) |output| {
                            try context.stdout().print("{s}", .{output});
                            context.allocator.free(output);
                        }
                        
                        if (result.?.stop_execution) {
                            return null; // Stop execution
                        }
                        
                        // TODO: For now, if any plugin handles an option, we stop execution
                        // Later we can implement more sophisticated option consumption
                        if (result.?.stop_execution) {
                            return null;
                        }
                    }
                }
            }
            
            // No plugins stopped execution, return all args for normal parsing
            return raw_args;
        }
        
        /// Generic plugin pipeline caller - gives plugins access to command module type for introspection
        fn callPluginPipeline(self: *Self, context: *zcli.Context, event: zcli.OptionEvent, comptime command_module: type) !?zcli.PluginResult {
            _ = self;
            
            // Call each plugin in sequence, always providing command module type for introspection
            inline for (plugins) |plugin_info| {
                if (@hasDecl(plugin_info.plugin, "handleOption")) {
                    const result = try plugin_info.plugin.handleOption(context, event, command_module);
                    if (result != null) {
                        return result;
                    }
                }
            }
            
            return null;
        }
        
        /// Convert command module meta to plugin metadata (simplified)
        fn convertCommandMeta(module_meta: anytype) zcli.plugin_types.Metadata {
            var metadata = zcli.plugin_types.Metadata{};
            
            if (@hasField(@TypeOf(module_meta), "description")) {
                metadata.description = module_meta.description;
            }
            if (@hasField(@TypeOf(module_meta), "usage")) {
                metadata.usage = module_meta.usage;
            }
            if (@hasField(@TypeOf(module_meta), "examples")) {
                metadata.examples = module_meta.examples;
            }
            
            return metadata;
        }
        
        /// Parse arguments for a command
        fn parseArgs(self: *Self, comptime ArgsType: type, raw_args: []const []const u8) !ArgsType {
            _ = self;
            
            const fields = std.meta.fields(ArgsType);
            if (fields.len == 0) {
                return ArgsType{};
            }
            
            // Simple implementation: for now just handle basic cases
            var result: ArgsType = undefined;
            
            // Filter out options (anything starting with -)
            var positional_args = std.ArrayList([]const u8).init(std.heap.page_allocator);
            defer positional_args.deinit();
            
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
                    try positional_args.append(arg);
                    i += 1;
                }
            }
            
            // Assign positional arguments to fields
            inline for (fields, 0..) |field, idx| {
                switch (field.type) {
                    []const u8 => {
                        if (idx < positional_args.items.len) {
                            @field(result, field.name) = positional_args.items[idx];
                        } else {
                            // Required field missing
                            try std.io.getStdErr().writer().print("Error: Missing required argument '{s}'\n", .{field.name});
                            return error.MissingArgument;
                        }
                    },
                    [][]const u8 => {
                        // Collect remaining arguments
                        const remaining = positional_args.items[idx..];
                        @field(result, field.name) = remaining;
                    },
                    else => {
                        @field(result, field.name) = @as(field.type, undefined);
                    },
                }
            }
            
            return result;
        }
        
        /// Parse options for a command
        fn parseOptions(self: *Self, comptime OptionsType: type, raw_args: []const []const u8) !OptionsType {
            _ = self;
            
            const fields = std.meta.fields(OptionsType);
            if (fields.len == 0) {
                return OptionsType{};
            }
            
            // Manually initialize each field with defaults
            var result: OptionsType = undefined;
            inline for (fields) |field| {
                switch (field.type) {
                    bool => @field(result, field.name) = false,
                    [][]const u8 => @field(result, field.name) = &[_][]const u8{},
                    else => @field(result, field.name) = @as(field.type, undefined),
                }
            }
            
            // Simple implementation: look for options in raw_args
            var i: usize = 0;
            while (i < raw_args.len) {
                const arg = raw_args[i];
                
                if (std.mem.startsWith(u8, arg, "--")) {
                    // Long option
                    const option_name = arg[2..];
                    
                    inline for (fields) |field| {
                        // Convert snake_case to kebab-case for matching
                        const kebab_name = comptime blk: {
                            var name: []const u8 = "";
                            for (field.name) |c| {
                                if (c == '_') {
                                    name = name ++ "-";
                                } else {
                                    name = name ++ [_]u8{c};
                                }
                            }
                            break :blk name;
                        };
                        
                        if (std.mem.eql(u8, option_name, kebab_name)) {
                            switch (field.type) {
                                bool => {
                                    @field(result, field.name) = true;
                                },
                                else => {
                                    // For other types, would need value parsing
                                    // For now, skip
                                },
                            }
                        }
                    }
                } else if (std.mem.startsWith(u8, arg, "-") and arg.len == 2) {
                    // Short option like -h
                    const option_char = arg[1];
                    
                    // Handle common short options
                    if (option_char == 'h') {
                        try std.io.getStdOut().writer().print("Help for command - options parsing not yet complete\n", .{});
                        return result;
                    }
                }
                
                i += 1;
            }
            
            return result;
        }
    };
}

