const std = @import("std");

// ============================================================================
// Core Plugin Types
// ============================================================================

/// Global option that can be registered by plugins
pub const GlobalOption = struct {
    name: []const u8,
    short: ?u8 = null,
    type: type,
    default: DefaultValue,
    description: []const u8,
    category: ?[]const u8 = null,
    
    pub fn validate(self: @This(), value: anytype) !void {
        // Default validation - can be overridden
        _ = self;
        _ = value;
    }
    
    pub fn getDefaultAsString(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
        return self.default.toString(allocator);
    }
};

/// Union to store default values of different types
pub const DefaultValue = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    unsigned: u64,
    float: f64,
    none,
    
    pub fn toString(self: DefaultValue, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| s,
            .boolean => |b| if (b) "true" else "false",
            .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
            .unsigned => |u| try std.fmt.allocPrint(allocator, "{d}", .{u}),
            .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
            .none => "",
        };
    }
};

/// Unified helper function for creating GlobalOptions with better ergonomics
pub fn option(comptime name: []const u8, comptime T: type, comptime config: anytype) GlobalOption {
    // Extract fields from config, providing defaults if not present
    const short = if (@hasField(@TypeOf(config), "short")) config.short else null;
    const description = if (@hasField(@TypeOf(config), "description")) config.description else "";
    const category = if (@hasField(@TypeOf(config), "category")) config.category else null;
    const has_default = @hasField(@TypeOf(config), "default");
    const default_value = if (!has_default) blk: {
        // No default provided, create appropriate "zero" value
        break :blk switch (@typeInfo(T)) {
            .bool => DefaultValue{ .boolean = false },
            .int => |int_info| if (int_info.signedness == .signed) 
                DefaultValue{ .integer = 0 }
            else 
                DefaultValue{ .unsigned = 0 },
            .float => DefaultValue{ .float = 0.0 },
            .pointer => |ptr_info| if (ptr_info.size == .slice and ptr_info.child == u8) 
                DefaultValue{ .string = "" }
            else 
                DefaultValue{ .none = {} },
            .optional => DefaultValue{ .none = {} },
            else => DefaultValue{ .none = {} },
        };
    } else blk: {
        // Convert provided default to DefaultValue
        const default_val = config.default;
        break :blk switch (@TypeOf(default_val)) {
            bool => DefaultValue{ .boolean = default_val },
            comptime_int, u8, u16, u32, u64, usize => DefaultValue{ .unsigned = @as(u64, default_val) },
            i8, i16, i32, i64, isize => DefaultValue{ .integer = @as(i64, default_val) },
            f32, f64, comptime_float => DefaultValue{ .float = @as(f64, default_val) },
            []const u8 => DefaultValue{ .string = default_val },
            else => blk_inner: {
                // Handle string literals and other pointer types
                const type_info = @typeInfo(@TypeOf(default_val));
                if (type_info == .pointer) {
                    const ptr_info = type_info.pointer;
                    // Handle both string slices and string literals 
                    if (ptr_info.child == u8 or @typeInfo(ptr_info.child) == .array) {
                        const array_info = @typeInfo(ptr_info.child);
                        if (array_info == .array and array_info.array.child == u8) {
                            break :blk_inner DefaultValue{ .string = default_val };
                        } else if (ptr_info.child == u8) {
                            break :blk_inner DefaultValue{ .string = default_val };
                        } else {
                            @compileError("Unsupported pointer type: " ++ @typeName(@TypeOf(default_val)));
                        }
                    } else {
                        @compileError("Unsupported pointer type: " ++ @typeName(@TypeOf(default_val)));
                    }
                } else {
                    @compileError("Unsupported default value type: " ++ @typeName(@TypeOf(default_val)));
                }
            },
        };
    };
    
    return GlobalOption{
        .name = name,
        .short = short,
        .type = T,
        .default = default_value,
        .description = description,
        .category = category,
    };
}

/// Hook timing for plugin lifecycle events
pub const HookTiming = enum {
    pre_parse,      // Before argument parsing
    post_parse,     // After parsing, before command execution
    pre_execute,    // Right before command execution
    post_execute,   // After command execution
    on_error,       // When an error occurs
};

/// Result of argument transformation
pub const TransformResult = struct {
    args: []const []const u8,
    consumed_indices: []const usize = &.{},
    continue_processing: bool = true,
};


/// Parsed arguments structure
pub const ParsedArgs = struct {
    positional: []const []const u8 = &.{},
    
    pub fn init(_: std.mem.Allocator) @This() {
        return .{
            .positional = &.{},
        };
    }
    
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.positional.len > 0) {
            allocator.free(self.positional);
        }
    }
};

/// Global options parsing result
pub const GlobalOptionsResult = struct {
    consumed: []const usize,
    remaining: []const []const u8,
    errors: []const []const u8 = &.{},
};

// ============================================================================
// Plugin Capability Detection (compile-time introspection)
// ============================================================================

/// Check if a type has global options
pub fn hasGlobalOptions(comptime T: type) bool {
    return @hasDecl(T, "global_options");
}

/// Check if a type has a transformArgs function
pub fn hasTransformArgs(comptime T: type) bool {
    return @hasDecl(T, "transformArgs");
}

/// Check if a type has a handleGlobalOption function
pub fn hasHandleGlobalOption(comptime T: type) bool {
    return @hasDecl(T, "handleGlobalOption");
}

/// Check if a type has lifecycle hooks
pub fn hasPreParse(comptime T: type) bool {
    return @hasDecl(T, "preParse");
}

pub fn hasPostParse(comptime T: type) bool {
    return @hasDecl(T, "postParse");
}

pub fn hasPreExecute(comptime T: type) bool {
    return @hasDecl(T, "preExecute");
}

pub fn hasPostExecute(comptime T: type) bool {
    return @hasDecl(T, "postExecute");
}

pub fn hasOnError(comptime T: type) bool {
    return @hasDecl(T, "onError");
}

/// Check if a type has command extensions
pub fn hasCommands(comptime T: type) bool {
    return @hasDecl(T, "commands");
}

/// Get plugin priority (default 50)
pub fn getPriority(comptime T: type) i32 {
    if (@hasDecl(T, "priority")) {
        return T.priority;
    }
    return 50;
}

// ============================================================================
// Plugin Registry Entry
// ============================================================================

/// Entry in the plugin registry (compile-time)
pub fn PluginEntry(comptime T: type) type {
    return struct {
        const PluginType = T;
        
        pub const has_global_options = hasGlobalOptions(T);
        pub const has_transform_args = hasTransformArgs(T);
        pub const has_handle_global_option = hasHandleGlobalOption(T);
        pub const has_pre_parse = hasPreParse(T);
        pub const has_post_parse = hasPostParse(T);
        pub const has_pre_execute = hasPreExecute(T);
        pub const has_post_execute = hasPostExecute(T);
        pub const has_on_error = hasOnError(T);
        pub const has_commands = hasCommands(T);
        pub const priority = getPriority(T);
        
        pub const global_options = if (has_global_options) T.global_options else [_]GlobalOption{};
        pub const commands = if (has_commands) T.commands else struct {};
    };
}

// ============================================================================
// Context Extensions for Plugin Support
// ============================================================================

/// Extensions to Context for plugin support
pub const ContextExtensions = struct {
    global_data: std.StringHashMap([]const u8),
    verbosity: bool = false,
    
    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .global_data = std.StringHashMap([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *@This()) void {
        self.global_data.deinit();
    }
    
    pub fn setVerbosity(self: *@This(), verbose: bool) void {
        self.verbosity = verbose;
    }
    
    pub fn setGlobalData(self: *@This(), key: []const u8, value: []const u8) !void {
        try self.global_data.put(key, value);
    }
    
    pub fn getGlobalData(self: *@This(), comptime T: type, key: []const u8) ?T {
        const value = self.global_data.get(key) orelse return null;
        
        // Simple type conversion - extend as needed
        if (T == []const u8) {
            return @as(T, value);
        } else if (T == bool) {
            return std.mem.eql(u8, value, "true");
        } else if (T == u32) {
            return std.fmt.parseInt(u32, value, 10) catch null;
        }
        
        return null;
    }
    
    pub fn setLogLevel(self: *@This(), level: []const u8) !void {
        try self.setGlobalData("log-level", level);
    }
};

// ============================================================================
// Legacy Types (for compatibility during migration)
// ============================================================================

/// Standardized metadata structure for commands
pub const Metadata = struct {
    description: ?[]const u8 = null,
    usage: ?[]const u8 = null,
    examples: ?[]const []const u8 = null,
    options: ?OptionMetadata = null,
    arguments: ?ArgumentMetadata = null,
};

/// Information about a single option
pub const OptionInfo = struct {
    name: []const u8,
    type_name: []const u8,
    has_default: bool,
    default_value: ?[]const u8 = null,
    description: ?[]const u8 = null,
    short: ?u8 = null,
};

/// Metadata about command options/flags
pub const OptionMetadata = struct {
    options: []const OptionInfo = &.{},
    
    pub fn getDescription(self: @This(), option_name: []const u8) ?[]const u8 {
        for (self.options) |opt| {
            if (std.mem.eql(u8, opt.name, option_name)) {
                return opt.description;
            }
        }
        return null;
    }
};

/// Information about a single argument
pub const ArgumentInfo = struct {
    name: []const u8,
    type_name: []const u8,
    required: bool = true,
    description: ?[]const u8 = null,
};

/// Metadata about command arguments
pub const ArgumentMetadata = struct {
    arguments: []const ArgumentInfo = &.{},
    
    pub fn getDescription(self: @This(), arg_name: []const u8) ?[]const u8 {
        for (self.arguments) |arg| {
            if (std.mem.eql(u8, arg.name, arg_name)) {
                return arg.description;
            }
        }
        return null;
    }
};

/// Result returned by plugin event handlers (legacy)
pub const PluginResult = struct {
    handled: bool,
    output: ?[]const u8 = null,
    stop_execution: bool = false,
};

/// Generic plugin context that provides access to command information (legacy)
pub const PluginContext = struct {
    command_path: []const u8,
    metadata: Metadata,
};

/// Event data for handleOption (legacy)
pub const OptionEvent = struct {
    option: []const u8,
    plugin_context: PluginContext,
};

/// Event data for handleError (legacy)
pub const ErrorEvent = struct {
    err: anyerror,
    command_path: ?[]const u8,
    available_commands: ?[]const []const u8 = null,
};

/// Event data for handlePreCommand (legacy)
pub const PreCommandEvent = struct {
    command_path: []const u8,
    args: []const []const u8,
    metadata: Metadata,
};

/// Event data for handlePostCommand (legacy)
pub const PostCommandEvent = struct {
    command_path: []const u8,
    args: []const []const u8,
    metadata: Metadata,
    success: bool,
};

/// Convert command module meta to standardized Metadata (runtime version)
pub fn convertToStandardMetadata(module_meta: anytype) Metadata {
    var metadata = Metadata{};
    
    const meta_type_info = @typeInfo(@TypeOf(module_meta));
    if (meta_type_info == .@"struct") {
        // Extract description
        if (@hasField(@TypeOf(module_meta), "description")) {
            metadata.description = module_meta.description;
        }
        
        // Extract usage
        if (@hasField(@TypeOf(module_meta), "usage")) {
            metadata.usage = module_meta.usage;
        }
        
        // Extract examples
        if (@hasField(@TypeOf(module_meta), "examples")) {
            metadata.examples = module_meta.examples;
        }
        
        // Extract options metadata
        if (@hasField(@TypeOf(module_meta), "options")) {
            const options_meta = module_meta.options;
            if (@TypeOf(options_meta) == OptionMetadata) {
                metadata.options = options_meta;
            } else if (@typeInfo(@TypeOf(options_meta)) == .@"struct") {
                // If it's a custom struct, try to extract option info
                if (@hasField(@TypeOf(options_meta), "options")) {
                    metadata.options = OptionMetadata{
                        .options = options_meta.options,
                    };
                }
            }
        }
        
        // Extract arguments metadata
        if (@hasField(@TypeOf(module_meta), "arguments")) {
            const args_meta = module_meta.arguments;
            if (@TypeOf(args_meta) == ArgumentMetadata) {
                metadata.arguments = args_meta;
            } else if (@typeInfo(@TypeOf(args_meta)) == .@"struct") {
                // If it's a custom struct, try to extract argument info
                if (@hasField(@TypeOf(args_meta), "arguments")) {
                    metadata.arguments = ArgumentMetadata{
                        .arguments = args_meta.arguments,
                    };
                }
            }
        }
    }
    
    return metadata;
}

/// Extract metadata from a command module
pub fn extractMetadataFromModule(comptime ModuleType: type) Metadata {
    comptime {
        // Use type info to check for meta declaration
        const type_info = @typeInfo(ModuleType);
        if (type_info == .@"struct") {
            // Look for meta declaration in the struct
            for (type_info.@"struct".decls) |decl| {
                if (std.mem.eql(u8, decl.name, "meta")) {
                    const meta = @field(ModuleType, decl.name);
                    return convertToStandardMetadata(meta);
                }
            }
        }
        
        return Metadata{}; // Empty metadata if none found
    }
}