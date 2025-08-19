const std = @import("std");

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

/// Metadata about command arguments
pub const ArgumentMetadata = struct {
    // Information about positional arguments
    // e.g. .{ .name = "Required name parameter" }
    
    pub fn getDescription(self: @This(), arg_name: []const u8) ?[]const u8 {
        _ = self;
        _ = arg_name;
        // TODO: Implement argument description lookup
        return null;
    }
};

/// Result returned by plugin event handlers
pub const PluginResult = struct {
    handled: bool,
    output: ?[]const u8 = null,
    stop_execution: bool = false,
};

/// Generic plugin context that provides access to command information
pub const PluginContext = struct {
    command_path: []const u8,
    metadata: Metadata,
};

/// Event data for handleOption
pub const OptionEvent = struct {
    option: []const u8,
    plugin_context: PluginContext,
};

/// Event data for handleError  
pub const ErrorEvent = struct {
    err: anyerror,
    command_path: ?[]const u8,
    available_commands: ?[]const []const u8 = null,
};

/// Event data for handlePreCommand
pub const PreCommandEvent = struct {
    command_path: []const u8,
    args: []const []const u8,
    metadata: Metadata,
};

/// Event data for handlePostCommand
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
        
        // TODO: Extract options and arguments metadata
        // This requires more complex parsing of the meta.options structure
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