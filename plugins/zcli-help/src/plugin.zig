const std = @import("std");
const zcli = @import("zcli");

/// zcli-help Plugin
/// 
/// Provides help functionality for CLI applications using the event-based plugin system.

/// Handle option events - specifically --help and -h flags
/// Unified interface: always receives command module type for introspection
pub fn handleOption(context: anytype, event: zcli.OptionEvent, comptime command_module: type) !?zcli.PluginResult {
    if (std.mem.eql(u8, event.option, "--help") or std.mem.eql(u8, event.option, "-h")) {
        const help_text = try generateHelpWithModule(context, event.plugin_context, command_module);
        return zcli.PluginResult{
            .handled = true,
            .output = help_text,
            .stop_execution = true,
        };
    }
    return null; // Not handled
}


/// Generate help text for a command with comptime module introspection
fn generateHelpWithModule(context: anytype, plugin_context: zcli.PluginContext, comptime command_module: type) ![]const u8 {
    const allocator = context.allocator;
    var help_text = std.ArrayList(u8).init(allocator);
    const writer = help_text.writer();
    
    // Command name as title
    try writer.print("{s}\n\n", .{plugin_context.command_path});
    
    // Description
    if (plugin_context.metadata.description) |desc| {
        try writer.print("DESCRIPTION:\n    {s}\n\n", .{desc});
    }
    
    // Usage
    if (plugin_context.metadata.usage) |usage| {
        try writer.print("USAGE:\n    {s}\n\n", .{usage});
    } else {
        try writer.print("USAGE:\n    <app> {s} [options]\n\n", .{plugin_context.command_path});
    }
    
    // Examples
    if (plugin_context.metadata.examples) |examples| {
        if (examples.len > 0) {
            try writer.writeAll("EXAMPLES:\n");
            for (examples) |example| {
                try writer.print("    {s}\n", .{example});
            }
            try writer.writeAll("\n");
        }
    }
    
    // Options - introspect from command module at comptime
    try writer.writeAll("OPTIONS:\n");
    
    // Show actual command options if available
    if (@hasDecl(command_module, "Options")) {
        const options_fields = std.meta.fields(command_module.Options);
        try generateOptionsHelp(writer, options_fields);
    }
    
    // Always show help option
    try writer.writeAll("    --help, -h    Show this help message\n\n");
    
    return help_text.toOwnedSlice();
}

/// Generate help text for command options using comptime introspection
fn generateOptionsHelp(writer: anytype, comptime fields: []const std.builtin.Type.StructField) !void {
    inline for (fields) |field| {
        // Format: "    --option-name    Description"
        // Convert snake_case to kebab-case on the fly
        try writer.writeAll("    --");
        for (field.name) |c| {
            if (c == '_') {
                try writer.writeAll("-");
            } else {
                try writer.writeByte(c);
            }
        }
        
        // Add type info (simplified - no default value introspection for now)
        switch (field.type) {
            bool => {
                try writer.writeAll("    Boolean flag");
            },
            []const u8 => {
                try writer.writeAll(" <value>    String parameter");
            },
            [][]const u8 => {
                try writer.writeAll(" <values...>    Multiple string parameters");
            },
            else => {
                try writer.print("    Parameter of type {s}", .{@typeName(field.type)});
            },
        }
        
        try writer.writeAll("\n");
    }
}

// Context extension - optional configuration for the help plugin
pub const ContextExtension = struct {
    show_examples: bool = true,
    show_tips: bool = true,
    color_output: bool = true,
    max_width: usize = 80,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        _ = allocator;
        return .{
            .show_examples = true,
            .show_tips = true,
            .color_output = std.io.tty.detectConfig(std.io.getStdErr()) != .no_color,
            .max_width = 80,
        };
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
        // No cleanup needed for this simple extension
    }
};

// Tests
test "help plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "handleOption"));
    try std.testing.expect(@hasDecl(@This(), "ContextExtension"));
}

test "handleOption handles help flags" {
    const allocator = std.testing.allocator;
    
    // Mock context
    const MockContext = struct {
        allocator: std.mem.Allocator,
    };
    const context = MockContext{ .allocator = allocator };
    
    // Test --help flag
    const event = zcli.OptionEvent{
        .option = "--help",
        .plugin_context = zcli.PluginContext{
            .command_path = "test",
            .metadata = zcli.Metadata{
                .description = "Test command",
            },
        },
    };
    
    // Test command module type (create a simple mock)
    const MockCommand = struct {
        pub const Options = struct {
            verbose: bool = false,
        };
    };
    
    const result = try handleOption(context, event, MockCommand);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.handled);
    try std.testing.expect(result.?.stop_execution);
    try std.testing.expect(result.?.output != null);
    
    // Clean up
    if (result.?.output) |output| {
        allocator.free(output);
    }
}