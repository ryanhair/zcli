const std = @import("std");

/// Test plugin demonstrating all transformer types
/// This plugin adds logging and custom behavior to each pipeline

// Command transformer - adds logging before and after command execution
pub fn transformCommand(comptime next: anytype) type {
    return struct {
        pub fn execute(ctx: anytype, args: anytype) !void {
            // Log before execution
            if (@hasField(@TypeOf(ctx), "io")) {
                try ctx.io.stderr.print("[Plugin] Executing command...\n", .{});
            }
            
            // Call the next executor in the chain
            try next.execute(ctx, args);
            
            // Log after execution
            if (@hasField(@TypeOf(ctx), "io")) {
                try ctx.io.stderr.print("[Plugin] Command completed successfully\n", .{});
            }
        }
    };
}

// Error transformer - adds suggestions for command not found errors
pub fn transformError(comptime next: anytype) type {
    return struct {
        pub fn handle(err: anyerror, ctx: anytype) !void {
            // Add custom handling for specific errors
            switch (err) {
                error.CommandNotFound => {
                    if (@hasField(@TypeOf(ctx), "io")) {
                        try ctx.io.stderr.print("[Plugin] Suggestion: Did you mean 'help'?\n", .{});
                    }
                },
                error.InvalidArgument => {
                    if (@hasField(@TypeOf(ctx), "io")) {
                        try ctx.io.stderr.print("[Plugin] Tip: Check the argument format\n", .{});
                    }
                },
                else => {},
            }
            
            // Call the next error handler in the chain
            try next.handle(err, ctx);
        }
    };
}

// Help transformer - adds plugin information to help output
pub fn transformHelp(comptime next: anytype) type {
    return struct {
        pub fn generate(ctx: anytype, command_name: ?[]const u8) ![]const u8 {
            // Get the base help text
            const base_help = try next.generate(ctx, command_name);
            
            // Add plugin-specific help information
            var buffer = std.ArrayList(u8).init(ctx.allocator);
            defer buffer.deinit();
            
            try buffer.appendSlice(base_help);
            try buffer.appendSlice("\n[Plugin Info] Test transformer plugin is active\n");
            try buffer.appendSlice("This plugin adds logging and suggestions to commands.\n");
            
            // Transfer ownership to caller
            const result = try buffer.toOwnedSlice();
            ctx.allocator.free(base_help);
            return result;
        }
    };
}

// Context extension - adds plugin-specific state
pub const ContextExtension = struct {
    plugin_name: []const u8,
    log_level: LogLevel,
    
    pub const LogLevel = enum {
        debug,
        info,
        warn,
        err, // 'error' is a reserved keyword
    };
    
    pub fn init(allocator: std.mem.Allocator) !@This() {
        _ = allocator;
        return .{
            .plugin_name = "test_transformer_plugin",
            .log_level = .info,
        };
    }
    
    pub fn deinit(self: *@This()) void {
        _ = self;
        // Nothing to clean up in this example
    }
};

// Plugin commands
pub const commands = struct {
    pub const plugin_info = struct {
        pub const meta = .{
            .description = "Show information about the test plugin",
        };
        
        pub fn execute(ctx: anytype, args: anytype) !void {
            _ = args;
            try ctx.io.stdout.print("Test Transformer Plugin v1.0.0\n", .{});
            try ctx.io.stdout.print("This plugin demonstrates transformer capabilities\n", .{});
            
            // Access plugin context if available
            if (@hasField(@TypeOf(ctx), "test_transformer_plugin")) {
                try ctx.io.stdout.print("Plugin context: {s}, log level: {s}\n", .{
                    ctx.test_transformer_plugin.plugin_name,
                    @tagName(ctx.test_transformer_plugin.log_level),
                });
            }
        }
    };
};

// Tests
test "command transformer wraps execution" {
    const BaseExecutor = struct {
        pub fn execute(ctx: anytype, args: anytype) !void {
            _ = ctx;
            _ = args;
            // Base execution
        }
    };
    
    const TransformedExecutor = transformCommand(BaseExecutor);
    
    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    
    const test_ctx = struct {
        io: struct {
            stderr: @TypeOf(stream.writer()),
        },
    }{
        .io = .{
            .stderr = stream.writer(),
        },
    };
    
    try TransformedExecutor.execute(test_ctx, .{});
}

test "error transformer adds suggestions" {
    const BaseHandler = struct {
        pub fn handle(err: anyerror, ctx: anytype) !void {
            _ = ctx;
            return err;
        }
    };
    
    const TransformedHandler = transformError(BaseHandler);
    
    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    
    const test_ctx = struct {
        io: struct {
            stderr: @TypeOf(stream.writer()),
        },
    }{
        .io = .{
            .stderr = stream.writer(),
        },
    };
    
    _ = TransformedHandler.handle(error.CommandNotFound, test_ctx) catch {};
}

test "help transformer adds plugin info" {
    const allocator = std.testing.allocator;
    
    const BaseGenerator = struct {
        pub fn generate(ctx: anytype, command_name: ?[]const u8) ![]const u8 {
            _ = command_name;
            return ctx.allocator.dupe(u8, "Base help text");
        }
    };
    
    const TransformedGenerator = transformHelp(BaseGenerator);
    
    const test_ctx = struct {
        allocator: std.mem.Allocator,
    }{
        .allocator = allocator,
    };
    
    const help = try TransformedGenerator.generate(test_ctx, null);
    defer allocator.free(help);
    
    try std.testing.expect(std.mem.indexOf(u8, help, "Base help text") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "[Plugin Info]") != null);
}

test "context extension initializes correctly" {
    const allocator = std.testing.allocator;
    
    const ext = try ContextExtension.init(allocator);
    try std.testing.expectEqualStrings(ext.plugin_name, "test_transformer_plugin");
    try std.testing.expect(ext.log_level == .info);
}