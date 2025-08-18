const std = @import("std");
const help = @import("help.zig");

/// zcli-help Plugin
/// 
/// Provides comprehensive help functionality for CLI applications built with zcli.
/// This plugin demonstrates how to extract core functionality into reusable plugins.

// Command transformer - intercepts --help and -h flags to provide help
pub fn transformCommand(comptime next: anytype) type {
    return struct {
        pub fn execute(ctx: anytype, args: anytype) !void {
            // Debug: Let's see what we're getting
            // Check if help flag is present in the arguments
            if (hasHelpFlag(ctx, args)) {
                try showHelpForCurrentCommand(ctx, args);
                return;
            }
            
            // No help flag, continue with normal execution
            try next.execute(ctx, args);
        }
    };
}

// Help transformer - enhances help output with plugin-specific information
pub fn transformHelp(comptime next: anytype) type {
    return struct {
        pub fn generate(ctx: anytype, command_name: ?[]const u8) ![]const u8 {
            // Get base help from the next generator in chain
            const base_help = try next.generate(ctx, command_name);
            
            // Enhance with zcli-help plugin information
            const enhanced = try enhanceHelpWithExamples(ctx, base_help, command_name);
            
            // Clean up base help since we're replacing it
            ctx.allocator.free(base_help);
            
            return enhanced;
        }
    };
}

// Context extension - stores help-related configuration and state
pub const ContextExtension = struct {
    show_examples: bool,
    show_tips: bool,
    color_output: bool,
    max_width: usize,
    
    pub fn init(allocator: std.mem.Allocator) !@This() {
        _ = allocator;
        return .{
            .show_examples = true,
            .show_tips = true,
            .color_output = true,
            .max_width = 80,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        _ = self;
        // No cleanup needed for this simple extension
    }
};

// No plugin commands - this plugin only provides help enhancement functionality

// Private helper functions

fn hasHelpFlag(ctx: anytype, args: anytype) bool {
    _ = ctx;
    
    // Check if args contains help flags
    const ArgsType = @TypeOf(args);
    
    // If args is a command wrapper with an args field, check that
    if (@hasField(ArgsType, "args")) {
        for (args.args) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return true;
            }
        }
    }
    
    return false;
}

fn getCommandName(ctx: anytype, args: anytype) []const u8 {
    // Try to get the command path from the context if available
    if (@hasField(@TypeOf(ctx), "command_path")) {
        return ctx.command_path;
    }
    
    // Try to get from args if it has a name field
    if (@hasField(@TypeOf(args), "name")) {
        return args.name;
    }
    
    // Try to get from entry metadata
    if (@hasField(@TypeOf(args), "entry")) {
        if (@hasField(@TypeOf(args.entry), "name")) {
            return args.entry.name;
        }
    }
    
    // Fallback to app name from context if available
    if (@hasField(@TypeOf(ctx), "app_name")) {
        return ctx.app_name;
    }
    
    return "command";
}

fn showHelpForCurrentCommand(ctx: anytype, args: anytype) !void {
    // Get the command name from context and args
    const command_name = getCommandName(ctx, args);
    
    const stdout = if (@hasField(@TypeOf(ctx), "io")) 
        ctx.io.stdout 
    else if (@hasField(@TypeOf(ctx), "stdout")) 
        ctx.stdout() 
    else 
        std.io.getStdOut().writer();
    
    // Extract metadata from the command module if available
    var description: []const u8 = "No description available";
    var usage: []const u8 = "";
    
    if (@hasField(@TypeOf(args), "entry")) {
        if (@hasField(@TypeOf(args.entry), "module")) {
            const module = args.entry.module;
            
            // Get description from metadata
            if (@hasDecl(module, "meta")) {
                const meta = module.meta;
                if (@hasField(@TypeOf(meta), "description")) {
                    description = meta.description;
                }
                if (@hasField(@TypeOf(meta), "usage")) {
                    usage = meta.usage;
                }
            }
        }
    }
    
    // Generate help output - only show command name if it's meaningful
    if (command_name.len > 0 and !std.mem.eql(u8, command_name, "command")) {
        try stdout.print("{s}\n\n", .{command_name});
    }
    
    try stdout.print("DESCRIPTION:\n", .{});
    try stdout.print("    {s}\n\n", .{description});
    
    try stdout.print("USAGE:\n", .{});
    if (usage.len > 0) {
        try stdout.print("    {s}\n\n", .{usage});
    } else {
        // Build usage from app context if available
        const app_name = if (@hasField(@TypeOf(ctx), "app_name")) ctx.app_name else "command";
        try stdout.print("    {s} [arguments] [options]\n\n", .{app_name});
    }
    
    // Extract arguments and options from the command's Args and Options types if available
    if (@hasField(@TypeOf(args), "entry")) {
        if (@hasField(@TypeOf(args.entry), "module")) {
            const module = args.entry.module;
            
            // Show arguments if the command has an Args type
            if (@hasDecl(module, "Args")) {
                const ArgsType = module.Args;
                const args_info = @typeInfo(ArgsType);
                
                if (args_info == .@"struct" and args_info.@"struct".fields.len > 0) {
                    try stdout.print("ARGUMENTS:\n", .{});
                    inline for (args_info.@"struct".fields) |field| {
                        // TODO: Extract field descriptions from doc comments or metadata
                        try stdout.print("    <{s}>    {s}\n", .{ field.name, field.name });
                    }
                    try stdout.print("\n", .{});
                }
            }
            
            // Show options if the command has an Options type
            if (@hasDecl(module, "Options")) {
                const OptionsType = module.Options;
                const options_info = @typeInfo(OptionsType);
                
                if (options_info == .@"struct" and options_info.@"struct".fields.len > 0) {
                    try stdout.print("OPTIONS:\n", .{});
                    inline for (options_info.@"struct".fields) |field| {
                        const flag_name = if (field.name.len == 1) 
                            try std.fmt.allocPrint(ctx.allocator, "-{s}", .{field.name})
                        else 
                            try std.fmt.allocPrint(ctx.allocator, "--{s}", .{field.name});
                        defer ctx.allocator.free(flag_name);
                        
                        // TODO: Extract field descriptions from doc comments or metadata
                        try stdout.print("    {s}    {s}\n", .{ flag_name, field.name });
                    }
                    try stdout.print("\n", .{});
                }
            }
        }
    }
    
    try stdout.print("Use --help with any command for more information.\n", .{});
}

fn enhanceHelpWithExamples(ctx: anytype, base_help: []const u8, command_name: ?[]const u8) ![]const u8 {
    // For now, just return the base help without any visible plugin branding
    // Future enhancements could add examples or tips based on command metadata
    _ = command_name;
    
    // Simply return a copy of the base help
    return try ctx.allocator.dupe(u8, base_help);
}

// Tests for the plugin
test "help plugin structure" {
    // Verify the plugin has the expected structure
    try std.testing.expect(@hasDecl(@This(), "transformCommand"));
    try std.testing.expect(@hasDecl(@This(), "transformHelp"));
    try std.testing.expect(@hasDecl(@This(), "ContextExtension"));
    // No commands exported by this plugin
}

test "context extension lifecycle" {
    const allocator = std.testing.allocator;
    
    // Test initialization
    var ext = try ContextExtension.init(allocator);
    try std.testing.expect(ext.show_examples == true);
    try std.testing.expect(ext.show_tips == true);
    try std.testing.expect(ext.color_output == true);
    try std.testing.expect(ext.max_width == 80);
    
    // Test deinit (should not crash)
    ext.deinit();
}

test "help enhancement" {
    const allocator = std.testing.allocator;
    
    const ctx = struct {
        allocator: std.mem.Allocator,
    }{
        .allocator = allocator,
    };
    
    const base_help = "Base help text";
    const enhanced = try enhanceHelpWithExamples(ctx, base_help, "test");
    defer allocator.free(enhanced);
    
    try std.testing.expect(std.mem.indexOf(u8, enhanced, "Base help text") != null);
    try std.testing.expect(std.mem.indexOf(u8, enhanced, "zcli-help plugin") != null);
    try std.testing.expect(std.mem.indexOf(u8, enhanced, "Examples for 'test'") != null);
}