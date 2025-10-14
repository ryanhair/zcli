const std = @import("std");

/// Base command executor that plugins can transform
/// This is the foundation of the command pipeline system
pub const BaseCommandExecutor = struct {
    /// Execute a command with the given context and arguments
    /// This is the core execution function that plugins can wrap
    pub fn execute(ctx: anytype, args: anytype) !void {
        // Compile-time validation of context interface
        comptime {
            if (!@hasField(@TypeOf(ctx), "io")) {
                @compileError("Context must have 'io' field");
            }
        }

        // Get the command type from args
        const CommandType = @TypeOf(args);

        // Look for an execute function on the command
        if (@hasDecl(CommandType, "execute")) {
            // Call the command's execute function
            try CommandType.execute(ctx, args);
        } else {
            // If no execute function, this is an error
            try ctx.io.stderr.print("Error: Command does not implement execute function\n", .{});
            return error.CommandNotImplemented;
        }
    }
};

/// Base error handler that plugins can transform
/// This handles errors that occur during command execution
pub const BaseErrorHandler = struct {
    /// Handle an error with the given context
    pub fn handle(err: anyerror, ctx: anytype) !void {
        // Compile-time validation of context interface
        comptime {
            if (!@hasField(@TypeOf(ctx), "io")) {
                @compileError("Context must have 'io' field");
            }
        }

        // Default error handling - just print the error
        const error_name = @errorName(err);

        // Try to provide helpful error messages for common errors
        switch (err) {
            error.CommandNotFound => {
                try ctx.io.stderr.print("Error: Command not found\n", .{});
                if (@hasField(@TypeOf(ctx), "attempted_command")) {
                    try ctx.io.stderr.print("Unknown command: '{s}'\n", .{ctx.attempted_command});
                }
            },
            error.InvalidArgument => {
                try ctx.io.stderr.print("Error: Invalid argument provided\n", .{});
            },
            error.MissingArgument => {
                try ctx.io.stderr.print("Error: Required argument missing\n", .{});
            },
            error.InvalidOption => {
                try ctx.io.stderr.print("Error: Invalid option provided\n", .{});
            },
            error.PermissionDenied => {
                try ctx.io.stderr.print("Error: Permission denied\n", .{});
            },
            error.FileNotFound => {
                try ctx.io.stderr.print("Error: File not found\n", .{});
            },
            error.OutOfMemory => {
                try ctx.io.stderr.print("Error: Out of memory\n", .{});
            },
            else => {
                // Generic error message for unknown errors
                try ctx.io.stderr.print("Error: {s}\n", .{error_name});
            },
        }

        // Propagate the original error after handling
        return err;
    }
};

// Help functionality is provided entirely by plugins
// No base help generator in zcli core

// Helper types for tests - wraps AnyWriter/AnyReader but provides IO-compatible interface
const TestIO = struct {
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
    stdin: std.io.AnyReader,

    // Provide methods that match Context's expectations
    // Note: This works because the methods just return the stored values
    pub fn stdoutPtr(self: *@This()) std.io.AnyWriter {
        return self.stdout;
    }

    pub fn stderrPtr(self: *@This()) std.io.AnyWriter {
        return self.stderr;
    }

    pub fn stdinPtr(self: *@This()) std.io.AnyReader {
        return self.stdin;
    }
};

const TestContext = struct {
    allocator: std.mem.Allocator,
    stdout_buffer: std.ArrayList(u8),
    stderr_buffer: std.ArrayList(u8),
    stdin_buffer: []const u8,
    stdin_stream: std.io.FixedBufferStream([]const u8),
    io: TestIO,

    pub fn init(allocator: std.mem.Allocator) TestContext {
        const stdin_data = "";
        var self = TestContext{
            .allocator = allocator,
            .stdout_buffer = .empty,
            .stderr_buffer = .empty,
            .stdin_buffer = stdin_data,
            .stdin_stream = std.io.fixedBufferStream(stdin_data),
            .io = undefined,
        };

        // Set up the IO wrapper
        self.io = .{
            .stdout = self.stdout_buffer.writer(allocator).any(),
            .stderr = self.stderr_buffer.writer(allocator).any(),
            .stdin = self.stdin_stream.reader().any(),
        };

        return self;
    }

    pub fn deinit(self: *TestContext) void {
        self.stdout_buffer.deinit(self.allocator);
        self.stderr_buffer.deinit(self.allocator);
    }

    pub fn getStdoutContents(self: *const TestContext) []const u8 {
        return self.stdout_buffer.items;
    }

    pub fn getStderrContents(self: *const TestContext) []const u8 {
        return self.stderr_buffer.items;
    }

    pub fn clearBuffers(self: *TestContext) void {
        self.stdout_buffer.clearRetainingCapacity();
        self.stderr_buffer.clearRetainingCapacity();
    }
};

// Tests
test "BaseCommandExecutor executes commands" {
    const TestCommand = struct {
        pub fn execute(ctx: anytype, args: anytype) !void {
            _ = ctx;
            _ = args;
            // Test command execution
        }
    };

    var test_ctx = TestContext.init(std.testing.allocator);
    defer test_ctx.deinit();

    const test_args = TestCommand{};

    try BaseCommandExecutor.execute(test_ctx, test_args);
}

test "BaseErrorHandler handles common errors" {
    // Use fixed buffers for testing
    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    const stdin_data = "";

    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);
    var stdin_stream = std.io.fixedBufferStream(stdin_data);

    const test_ctx = struct {
        io: struct {
            stdout: std.io.AnyWriter,
            stderr: std.io.AnyWriter,
            stdin: std.io.AnyReader,
        },
        attempted_command: []const u8 = "test",
    }{
        .io = .{
            .stdout = stdout_stream.writer().any(),
            .stderr = stderr_stream.writer().any(),
            .stdin = stdin_stream.reader().any(),
        },
    };

    // Test handling CommandNotFound
    _ = BaseErrorHandler.handle(error.CommandNotFound, test_ctx) catch {};

    // Verify the error message was written to stderr
    const stderr_output = stderr_stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, stderr_output, "Error: Command not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_output, "Unknown command: 'test'") != null);

    // Reset the stream for the next test
    stderr_stream.reset();

    // Test handling InvalidArgument
    _ = BaseErrorHandler.handle(error.InvalidArgument, test_ctx) catch {};

    // Verify InvalidArgument error message
    const stderr_output2 = stderr_stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, stderr_output2, "Error: Invalid argument provided") != null);
}

// Help generation tests are provided by help plugins
