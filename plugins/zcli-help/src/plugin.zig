const std = @import("std");
const zcli = @import("zcli");

/// zcli-help Plugin
/// 
/// Provides help functionality for CLI applications using the lifecycle hook plugin system.

/// Global options provided by this plugin
pub const global_options = [_]zcli.GlobalOption{
    zcli.option("help", bool, .{ 
        .short = 'h', 
        .default = false, 
        .description = "Show help message" 
    }),
};

/// Handle global options - specifically the --help flag
pub fn handleGlobalOption(
    context: *zcli.Context,
    option_name: []const u8,
    value: anytype,
) !void {
    if (std.mem.eql(u8, option_name, "help")) {
        const bool_val = if (@TypeOf(value) == bool) value else false;
        if (bool_val) {
            try context.setGlobalData("help_requested", "true");
        }
    }
}

/// Pre-execute hook to show help if requested
pub fn preExecute(
    context: *zcli.Context,
    command_path: []const u8,
    args: zcli.ParsedArgs,
) !?zcli.ParsedArgs {
    const help_requested = context.getGlobalData([]const u8, "help_requested") orelse "false";
    if (std.mem.eql(u8, help_requested, "true")) {
        // If command_path is empty, show app help; otherwise show command help
        if (command_path.len == 0) {
            try showAppHelp(context);
        } else {
            try showCommandHelp(context, command_path);
        }
        
        // Return null to stop execution
        return null;
    }
    
    // Continue normal execution
    return args;
}


/// Commands provided by this plugin
pub const commands = struct {
    /// The help command itself
    pub const help = struct {
        pub const Args = struct {
            command: ?[]const u8 = null,
        };
        
        pub const Options = struct {};
        
        pub const meta = .{
            .description = "Show help for commands",
        };
        
        pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
            _ = options;
            if (args.command) |cmd| {
                try showCommandHelp(context, cmd);
            } else {
                try showAppHelp(context);
            }
        }
    };
};

/// Show help for the entire application
fn showAppHelp(context: *zcli.Context) !void {
    const writer = context.stderr();
    
    // Get app metadata from context
    const app_name = context.app_name;
    const app_version = context.app_version;
    const app_description = context.app_description;
    
    try writer.print("{s} v{s}\n", .{ app_name, app_version });
    if (app_description.len > 0) {
        try writer.print("{s}\n", .{app_description});
    }
    try writer.writeAll("\n");
    
    try writer.writeAll("USAGE:\n");
    try writer.print("    {s} [command] [options]\n\n", .{app_name});
    
    try writer.writeAll("COMMANDS:\n");
    try writer.writeAll("    help    Show help for commands\n");
    // TODO: List other available commands when we have registry access
    try writer.writeAll("\n");
    
    try writer.writeAll("GLOBAL OPTIONS:\n");
    try writer.writeAll("    --help, -h    Show help message\n");
    try writer.writeAll("\n");
}

/// Show help for a specific command  
fn showCommandHelp(context: *zcli.Context, command: []const u8) !void {
    const writer = context.stderr();
    
    try writer.print("Help for command: {s}\n\n", .{command});
    
    // TODO: When we have access to command metadata, show:
    // - Command description
    // - Usage
    // - Arguments
    // - Options
    // - Examples
    
    try writer.writeAll("OPTIONS:\n");
    try writer.writeAll("    --help, -h    Show this help message\n");
    try writer.writeAll("\n");
}

// Context extension - optional configuration for the help plugin
pub const ContextExtension = struct {
    show_examples: bool = true,
    show_tips: bool = true,
    color_output: bool = true,
    max_width: usize = 80,
    // Store command metadata for help generation
    command_metadata: std.StringHashMap(CommandMetadata),

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .show_examples = true,
            .show_tips = true,
            .color_output = std.io.tty.detectConfig(std.io.getStdErr()) != .no_color,
            .max_width = 80,
            .command_metadata = std.StringHashMap(CommandMetadata).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.command_metadata.deinit();
    }
};

/// Metadata about a command for help generation
const CommandMetadata = struct {
    description: ?[]const u8 = null,
    usage: ?[]const u8 = null,
    examples: ?[]const []const u8 = null,
};

// Tests
test "help plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "global_options"));
    try std.testing.expect(@hasDecl(@This(), "handleGlobalOption"));
    try std.testing.expect(@hasDecl(@This(), "preExecute"));
    try std.testing.expect(@hasDecl(@This(), "commands"));
    try std.testing.expect(@hasDecl(@This(), "ContextExtension"));
}

test "handleGlobalOption handles help flag" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    var context = zcli.Context.init(gpa.allocator());
    defer context.deinit();
    
    // Test handling --help flag
    try handleGlobalOption(&context, "help", true);
    
    const help_requested = context.getGlobalData([]const u8, "help_requested") orelse "false";
    try std.testing.expectEqualStrings("true", help_requested);
}

test "help command execution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    var context = zcli.Context.init(gpa.allocator());
    defer context.deinit();
    
    // Test help command with no arguments (shows app help)
    const args = commands.help.Args{ .command = null };
    const options = commands.help.Options{};
    
    try commands.help.execute(args, options, &context);
    // Test passes if it doesn't crash
}