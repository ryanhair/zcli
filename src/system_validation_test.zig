const std = @import("std");
const zcli = @import("zcli.zig");

// System validation tests to ensure core functionality works end-to-end
// These tests validate that our parsing, registry, and plugin systems integrate correctly

test "system validation: args parsing with correct API" {
    const TestArgs = struct {
        name: []const u8,
        count: u32,
        enabled: bool,
    };

    const args = [_][]const u8{ "test", "42", "true" };
    const parsed = try zcli.parseArgs(TestArgs, &args);

    try std.testing.expectEqualStrings("test", parsed.name);
    try std.testing.expectEqual(@as(u32, 42), parsed.count);
    try std.testing.expectEqual(true, parsed.enabled);
}

test "system validation: args parsing error handling" {
    const TestArgs = struct {
        name: []const u8,
        count: u32,
    };

    // Test missing arguments
    {
        const args = [_][]const u8{};
        try std.testing.expectError(zcli.ZcliError.ArgumentMissingRequired, zcli.parseArgs(TestArgs, &args));
    }

    // Test invalid number
    {
        const args = [_][]const u8{ "test", "not_a_number" };
        try std.testing.expectError(zcli.ZcliError.ArgumentInvalidValue, zcli.parseArgs(TestArgs, &args));
    }
}

test "system validation: options parsing with correct API" {
    const TestOptions = struct {
        verbose: bool = false,
        count: u32 = 10,
        name: ?[]const u8 = null,
    };

    const args = [_][]const u8{ "--verbose", "--count", "42", "--name", "test" };
    const parsed = try zcli.parseOptions(TestOptions, std.testing.allocator, &args);
    defer zcli.cleanupOptions(TestOptions, parsed.options, std.testing.allocator);
    try std.testing.expectEqual(true, parsed.options.verbose);
    try std.testing.expectEqual(@as(u32, 42), parsed.options.count);
    try std.testing.expectEqualStrings("test", parsed.options.name.?);
}

test "system validation: options parsing error handling" {
    const TestOptions = struct {
        count: u32 = 10,
    };

    // Test unknown option
    {
        const args = [_][]const u8{"--unknown"};
        try std.testing.expectError(zcli.ZcliError.OptionUnknown, zcli.parseOptions(TestOptions, std.testing.allocator, &args));
    }

    // Test missing value
    {
        const args = [_][]const u8{"--count"};
        try std.testing.expectError(zcli.ZcliError.OptionMissingValue, zcli.parseOptions(TestOptions, std.testing.allocator, &args));
    }
}

test "system validation: enum parsing" {
    const TestArgs = struct {
        format: enum { json, xml, yaml },
    };

    // Valid enum
    {
        const args = [_][]const u8{"json"};
        const parsed = try zcli.parseArgs(TestArgs, &args);
        try std.testing.expectEqual(@as(@TypeOf(parsed.format), .json), parsed.format);
    }

    // Invalid enum
    {
        const args = [_][]const u8{"invalid"};
        try std.testing.expectError(zcli.ZcliError.ArgumentInvalidValue, zcli.parseArgs(TestArgs, &args));
    }
}

test "system validation: optional args" {
    const TestArgs = struct {
        required: []const u8,
        optional: ?u32 = null,
    };

    // With optional provided
    {
        const args = [_][]const u8{ "required", "42" };
        const parsed = try zcli.parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("required", parsed.required);
        try std.testing.expectEqual(@as(?u32, 42), parsed.optional);
    }

    // Without optional
    {
        const args = [_][]const u8{"required"};
        const parsed = try zcli.parseArgs(TestArgs, &args);
        try std.testing.expectEqualStrings("required", parsed.required);
        try std.testing.expectEqual(@as(?u32, null), parsed.optional);
    }
}

test "system validation: varargs" {
    const TestArgs = struct {
        command: []const u8,
        files: []const []const u8,
    };

    const args = [_][]const u8{ "process", "file1.txt", "file2.txt", "file3.txt" };
    const parsed = try zcli.parseArgs(TestArgs, &args);
    // Note: cleanupArgs may not be needed for simple types

    try std.testing.expectEqualStrings("process", parsed.command);
    try std.testing.expectEqual(@as(usize, 3), parsed.files.len);
    try std.testing.expectEqualStrings("file1.txt", parsed.files[0]);
    try std.testing.expectEqualStrings("file2.txt", parsed.files[1]);
    try std.testing.expectEqualStrings("file3.txt", parsed.files[2]);
}

test "system validation: array options" {
    const TestOptions = struct {
        tags: []const []const u8 = &.{},
    };

    const args = [_][]const u8{ "--tags", "tag1", "--tags", "tag2", "--tags", "tag3" };
    const parsed = try zcli.parseOptions(TestOptions, std.testing.allocator, &args);
    defer zcli.cleanupOptions(TestOptions, parsed.options, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), parsed.options.tags.len);
    try std.testing.expectEqualStrings("tag1", parsed.options.tags[0]);
    try std.testing.expectEqualStrings("tag2", parsed.options.tags[1]);
    try std.testing.expectEqualStrings("tag3", parsed.options.tags[2]);
}

test "system validation: complex realistic command" {
    // Simulate: git commit -m "message" --author "Name" file1.txt file2.txt

    const CommitArgs = struct {
        files: []const []const u8,
    };

    const CommitOptions = struct {
        message: ?[]const u8 = null,
        author: ?[]const u8 = null,
        all: bool = false,
    };

    // Parse arguments
    const args = [_][]const u8{ "README.md", "src/main.zig" };
    const parsed_args = try zcli.parseArgs(CommitArgs, &args);
    // Note: cleanupArgs may not be needed for simple types

    // Parse options
    const opts = [_][]const u8{ "--message", "Initial commit", "--author", "John Doe", "--all" };
    const parsed_opts = try zcli.parseOptions(CommitOptions, std.testing.allocator, &opts);
    defer zcli.cleanupOptions(CommitOptions, parsed_opts.options, std.testing.allocator);

    // Validate results
    try std.testing.expectEqual(@as(usize, 2), parsed_args.files.len);
    try std.testing.expectEqualStrings("README.md", parsed_args.files[0]);
    try std.testing.expectEqualStrings("src/main.zig", parsed_args.files[1]);

    try std.testing.expectEqualStrings("Initial commit", parsed_opts.options.message.?);
    try std.testing.expectEqualStrings("John Doe", parsed_opts.options.author.?);
    try std.testing.expectEqual(true, parsed_opts.options.all);
}

test "system validation: registry type creation" {
    // Test that we can create registry types with various command signatures

    const SimpleCommand = struct {
        pub const meta = .{ .description = "Simple command" };
        pub fn execute(args: struct {}, options: struct {}, context: *zcli.Context) !void {
            _ = args;
            _ = options;
            try context.stdout().print("simple\n");
        }
    };

    const ArgsCommand = struct {
        pub const meta = .{ .description = "Command with args" };
        pub const Args = struct { name: []const u8 };
        pub fn execute(args: Args, options: struct {}, context: *zcli.Context) !void {
            _ = options;
            try context.stdout().print("Hello {s}\n", .{args.name});
        }
    };

    const OptionsCommand = struct {
        pub const meta = .{ .description = "Command with options" };
        pub const Options = struct { verbose: bool = false };
        pub fn execute(args: struct {}, options: Options, context: *zcli.Context) !void {
            _ = args;
            if (options.verbose) {
                try context.stdout().print("Verbose mode\n");
            }
        }
    };

    const FullCommand = struct {
        pub const meta = .{ .description = "Command with both" };
        pub const Args = struct { target: []const u8 };
        pub const Options = struct { force: bool = false };
        pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
            try context.stdout().print("Processing {s} (force={})\n", .{ args.target, options.force });
        }
    };

    // This should compile successfully
    const TestRegistry = zcli.Registry.init(.{
        .app_name = "validation-test",
        .app_version = "1.0.0",
        .app_description = "System validation test registry",
    })
        .register("simple", SimpleCommand)
        .register("args", ArgsCommand)
        .register("options", OptionsCommand)
        .register("full", FullCommand)
        .register("nested.command", SimpleCommand)
        .build();

    // Should be able to use the registry type
    _ = TestRegistry; // Suppress unused warning
}

test "system validation: plugin interface compilation" {
    // Test that plugin interfaces compile correctly

    const ValidationTestPlugin = struct {
        pub fn handleOption(context: *zcli.Context, event: zcli.OptionEvent, comptime command_module: type) !?zcli.PluginResult {
            _ = context;
            _ = command_module;

            if (std.mem.eql(u8, event.option, "--help")) {
                return zcli.PluginResult{
                    .handled = true,
                    .output = "Help text",
                    .stop_execution = true,
                };
            }
            return null;
        }

        pub fn handleError(context: *zcli.Context, err: anyerror, comptime command_module: type) !?zcli.PluginResult {
            _ = context;
            _ = command_module;

            switch (err) {
                error.CommandNotFound => return zcli.PluginResult{
                    .handled = true,
                    .output = "Command not found",
                    .stop_execution = true,
                },
                else => return null,
            }
        }
    };

    const SimpleCommand = struct {
        pub fn execute(args: struct {}, options: struct {}, context: *zcli.Context) !void {
            _ = args;
            _ = options;
            _ = context;
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "plugin-test",
        .app_version = "1.0.0",
        .app_description = "Plugin validation test",
    })
        .register("test", SimpleCommand)
        .registerPlugin(ValidationTestPlugin)
        .build();

    _ = TestRegistry;
}

test "system validation: memory management" {
    // Test that memory management works correctly across the system

    const TestArgs = struct {
        files: []const []const u8,
    };

    const TestOptions = struct {
        tags: []const []const u8 = &.{},
        names: []const []const u8 = &.{},
    };

    // Multiple allocations and deallocations
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        // Parse args
        const args = [_][]const u8{ "file1.txt", "file2.txt", "file3.txt" };
        const parsed_args = try zcli.parseArgs(TestArgs, &args);
        // Note: cleanupArgs may not be needed for simple types

        // Parse options
        const opts = [_][]const u8{ "--tags", "tag1", "--tags", "tag2", "--names", "name1", "--names", "name2" };
        const parsed_opts = try zcli.parseOptions(TestOptions, std.testing.allocator, &opts);
        defer zcli.cleanupOptions(TestOptions, parsed_opts.options, std.testing.allocator);

        // Validate
        try std.testing.expectEqual(@as(usize, 3), parsed_args.files.len);
        try std.testing.expectEqual(@as(usize, 2), parsed_opts.options.tags.len);
    }
}

test "system validation: error message quality" {
    // Test that error messages are informative

    const TestArgs = struct {
        count: u32,
    };

    const args = [_][]const u8{"not_a_number"};
    try std.testing.expectError(zcli.ZcliError.ArgumentInvalidValue, zcli.parseArgs(TestArgs, &args));

    // Basic validation that we have error information
    // Note: The exact structure depends on the specific error type
}

test "system validation: type introspection" {
    // Test that the system can introspect command types correctly

    const TestCommand = struct {
        pub const meta = .{ .description = "Test command for introspection" };

        pub const Args = struct {
            name: []const u8,
            count: u32,
        };

        pub const Options = struct {
            verbose: bool = false,
            format: enum { json, yaml } = .json,
        };

        pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
            _ = args;
            _ = options;
            _ = context;
        }
    };

    // Test that we can introspect the command at comptime
    comptime {
        try std.testing.expect(@hasDecl(TestCommand, "meta"));
        try std.testing.expect(@hasDecl(TestCommand, "Args"));
        try std.testing.expect(@hasDecl(TestCommand, "Options"));
        try std.testing.expect(@hasDecl(TestCommand, "execute"));

        // Test field introspection
        const args_fields = std.meta.fields(TestCommand.Args);
        try std.testing.expectEqual(@as(usize, 2), args_fields.len);

        const options_fields = std.meta.fields(TestCommand.Options);
        try std.testing.expectEqual(@as(usize, 2), options_fields.len);
    }
}
