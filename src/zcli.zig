const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const help_generator = @import("help.zig");
const error_handler = @import("errors.zig");

// ============================================================================
// PUBLIC API - Core functionality for end users
// ============================================================================

// Argument and option parsing
pub const parseArgs = args_parser.parseArgs;
pub const parseOptions = options_parser.parseOptions;
pub const parseOptionsWithMeta = options_parser.parseOptionsWithMeta;
pub const cleanupOptions = options_parser.cleanupOptions;

// Error types
pub const ParseError = args_parser.ParseError;
pub const OptionParseError = options_parser.OptionParseError;
pub const CLIError = error_handler.CLIError;

// Main help generation (for app-level help)
pub const generateAppHelp = help_generator.generateAppHelp;
pub const generateCommandHelp = help_generator.generateCommandHelp;

// ============================================================================
// ADVANCED API - Lower-level functions for advanced use cases
// ============================================================================

// Advanced help generation (for custom help implementations)
pub const generateSubcommandsList = help_generator.generateSubcommandsList;

// Advanced error handling (for custom error handling)
pub const CLIErrors = struct {
    pub const handleCommandNotFound = error_handler.handleCommandNotFound;
    pub const handleSubcommandNotFound = error_handler.handleSubcommandNotFound;
    pub const handleMissingArgument = error_handler.handleMissingArgument;
    pub const handleTooManyArguments = error_handler.handleTooManyArguments;
    pub const handleUnknownOption = error_handler.handleUnknownOption;
    pub const handleInvalidOptionValue = error_handler.handleInvalidOptionValue;
    pub const handleMissingOptionValue = error_handler.handleMissingOptionValue;
    pub const getExitCode = error_handler.getExitCode;
};

// ============================================================================
// INTERNAL API - Used by the App struct, not intended for direct user access
// ============================================================================

// Internal help utilities (used by App struct)
const getAvailableCommands = help_generator.getAvailableCommands;
const getAvailableSubcommands = help_generator.getAvailableSubcommands;

// I/O abstraction for command input/output operations
pub const IO = struct {
    stdout: std.fs.File.Writer,
    stderr: std.fs.File.Writer,
    stdin: std.fs.File.Reader,
};

// Environment abstraction for accessing environment variables and system context
pub const Environment = struct {
    env: std.process.EnvMap,
};

// Core types that commands will use
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: IO,
    environment: Environment,
    
    // Convenience methods for backward compatibility
    pub fn stdout(self: *const Context) std.fs.File.Writer {
        return self.io.stdout;
    }
    
    pub fn stderr(self: *const Context) std.fs.File.Writer {
        return self.io.stderr;
    }
    
    pub fn stdin(self: *const Context) std.fs.File.Reader {
        return self.io.stdin;
    }
    
    pub fn env(self: *const Context) *const std.process.EnvMap {
        return &self.environment.env;
    }
};

// Command metadata structure
pub const CommandMeta = struct {
    description: []const u8,
    usage: ?[]const u8 = null,
    examples: ?[]const []const u8 = null,
};

// Main application structure
pub fn App(comptime Registry: type) type {
    return struct {
        allocator: std.mem.Allocator,
        registry: Registry,
        name: []const u8,
        version: []const u8,
        description: []const u8,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, registry: Registry, options: struct {
            name: []const u8,
            version: []const u8,
            description: []const u8,
        }) Self {
            return .{
                .allocator = allocator,
                .registry = registry,
                .name = options.name,
                .version = options.version,
                .description = options.description,
            };
        }

        pub fn run(self: *Self, args: []const []const u8) !void {
            // Parse global options first
            const parsed = try self.parseGlobalOptions(args);

            // Handle --help
            if (parsed.help) {
                try self.showHelp();
                return;
            }

            // Handle --version
            if (parsed.version) {
                try self.showVersion();
                return;
            }

            // Route to appropriate command
            if (parsed.remaining_args.len == 0) {
                // No command specified, run root command if it exists
                try self.runRootCommand();
            } else {
                // Route to subcommand
                try self.routeCommand(parsed.remaining_args);
            }
        }

        fn parseGlobalOptions(self: *Self, args: []const []const u8) !struct {
            help: bool,
            version: bool,
            remaining_args: []const []const u8,
        } {
            _ = self;
            // Simple parsing for --help and --version only
            var help = false;
            var version = false;
            var first_non_option: usize = 0;

            for (args, 0..) |arg, i| {
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    help = true;
                } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                    version = true;
                } else if (!std.mem.startsWith(u8, arg, "-")) {
                    first_non_option = i;
                    break;
                }
            }

            return .{
                .help = help,
                .version = version,
                .remaining_args = args[first_non_option..],
            };
        }

        fn showHelp(self: *Self) !void {
            const stdout = std.io.getStdOut().writer();
            try generateAppHelp(
                self.registry,
                stdout,
                self.name,
                self.version,
                self.description,
            );
        }

        fn showVersion(self: *Self) !void {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("{s} v{s}\n", .{ self.name, self.version });
        }

        fn runRootCommand(self: *Self) !void {
            // Check if root command exists in registry
            if (@hasField(@TypeOf(self.registry.commands), "root")) {
                const root_cmd = @field(self.registry.commands, "root");
                try self.executeCommand(root_cmd, &.{});
            } else {
                try self.showHelp();
            }
        }

        fn routeCommand(self: *Self, args: []const []const u8) !void {
            if (args.len == 0) {
                try self.runRootCommand();
                return;
            }

            const command_name = args[0];
            const remaining_args = args[1..];

            // Use comptime to generate routing logic
            try self.routeCommandComptime(self.registry.commands, command_name, remaining_args);
        }

        fn routeCommandComptime(self: *Self, commands: anytype, command_name: []const u8, args: []const []const u8) !void {
            const CommandsType = @TypeOf(commands);

            // Generate comptime switch for all available commands
            inline for (@typeInfo(CommandsType).@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, command_name)) {
                    const cmd = @field(commands, field.name);

                    // Check if it's a command group (check if it has _is_group field)
                    const type_info = @typeInfo(@TypeOf(cmd));
                    if (type_info == .@"struct") {
                        const struct_info = type_info.@"struct";
                        var is_group = false;
                        inline for (struct_info.fields) |struct_field| {
                            if (std.mem.eql(u8, struct_field.name, "_is_group")) {
                                is_group = true;
                                break;
                            }
                        }
                        if (is_group) {
                            try self.routeSubcommandComptime(cmd, args, command_name);
                        } else {
                            try self.executeCommand(cmd, args);
                        }
                    } else {
                        try self.executeCommand(cmd, args);
                    }
                    return;
                }
            }

            // Command not found
            try self.showCommandNotFound(command_name);
        }

        fn routeSubcommandComptime(self: *Self, group: anytype, args: []const []const u8, group_name: []const u8) !void {
            if (args.len == 0) {
                // No subcommand given, try to run the index command
                if (@hasField(@TypeOf(group), "_index")) {
                    const index_cmd = @field(group, "_index");
                    try self.executeCommand(index_cmd, &.{});
                } else {
                    try self.showSubcommandHelp(group_name, group);
                }
                return;
            }

            // Check for help flag before routing to subcommands
            if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
                try self.showSubcommandHelp(group_name, group);
                return;
            }

            const subcommand_name = args[0];
            const remaining_args = args[1..];

            // Generate comptime switch for all available subcommands
            const GroupType = @TypeOf(group);
            inline for (@typeInfo(GroupType).@"struct".fields) |field| {
                comptime if (std.mem.startsWith(u8, field.name, "_")) continue; // Skip metadata fields

                if (std.mem.eql(u8, field.name, subcommand_name)) {
                    const subcmd = @field(group, field.name);

                    // Check if it's a nested command group
                    const subcmd_type_info = @typeInfo(@TypeOf(subcmd));
                    if (subcmd_type_info == .@"struct") {
                        const subcmd_struct_info = subcmd_type_info.@"struct";
                        var is_nested_group = false;
                        inline for (subcmd_struct_info.fields) |subcmd_field| {
                            if (std.mem.eql(u8, subcmd_field.name, "_is_group")) {
                                is_nested_group = true;
                                break;
                            }
                        }
                        if (is_nested_group) {
                            try self.routeSubcommandComptime(subcmd, remaining_args, subcommand_name);
                        } else {
                            try self.executeCommand(subcmd, remaining_args);
                        }
                    } else {
                        try self.executeCommand(subcmd, remaining_args);
                    }
                    return;
                }
            }

            // Subcommand not found
            try self.showSubcommandNotFound(group_name, subcommand_name);
        }

        fn executeCommand(self: *Self, command_entry: anytype, args: []const []const u8) !void {
            // Check if this is a help request first
            for (args) |arg| {
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    try self.showCommandHelp(command_entry);
                    return;
                }
            }

            // Create context for command execution
            var env = std.process.EnvMap.init(self.allocator);
            defer env.deinit();

            var context = Context{
                .allocator = self.allocator,
                .io = IO{
                    .stdout = std.io.getStdOut().writer(),
                    .stderr = std.io.getStdErr().writer(),
                    .stdin = std.io.getStdIn().reader(),
                },
                .environment = Environment{
                    .env = env,
                },
            };

            // Check if this is a command entry struct with .execute field
            const TypeInfo = @typeInfo(@TypeOf(command_entry));
            if (TypeInfo == .@"struct" and @hasField(@TypeOf(command_entry), "execute")) {
                // This is a proper command entry with .execute field - use the generated wrapper
                try command_entry.execute(args, self.allocator, &context);
            }
        }

        fn showCommandNotFound(self: *Self, command: []const u8) !void {
            const stderr = std.io.getStdErr().writer();

            // Get list of available commands for better error messages
            const available_commands = getAvailableCommands(self.registry, self.allocator) catch {
                // Fallback to simple error if we can't get commands
                try stderr.print("Error: Unknown command '{s}'\n\n", .{command});
                try stderr.print("Run '{s} --help' to see available commands.\n", .{self.name});
                return;
            };
            defer self.allocator.free(available_commands);

            try CLIErrors.handleCommandNotFound(stderr, command, available_commands, self.name, self.allocator);
        }

        fn showSubcommandNotFound(self: *Self, group: []const u8, subcommand: []const u8) !void {
            const stderr = std.io.getStdErr().writer();

            // Find the group to get available subcommands
            // This requires generating the lookup dynamically
            try self.showSubcommandNotFoundComptime(self.registry.commands, group, subcommand, stderr);
        }

        fn showSubcommandNotFoundComptime(self: *Self, commands: anytype, group_name: []const u8, subcommand: []const u8, stderr: anytype) !void {
            const CommandsType = @TypeOf(commands);

            // Find the group to get its subcommands
            inline for (@typeInfo(CommandsType).@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, group_name)) {
                    const cmd = @field(commands, field.name);

                    // Check if it's a command group
                    const type_info = @typeInfo(@TypeOf(cmd));
                    if (type_info == .@"struct") {
                        const struct_info = type_info.@"struct";
                        var is_group = false;
                        inline for (struct_info.fields) |struct_field| {
                            if (std.mem.eql(u8, struct_field.name, "_is_group")) {
                                is_group = true;
                                break;
                            }
                        }
                        if (is_group) {
                            // Get available subcommands for better error messages
                            const available_subcommands = getAvailableSubcommands(cmd, self.allocator) catch {
                                // Fallback to simple error if we can't get subcommands
                                try stderr.print("Error: Unknown subcommand '{s}' for '{s}'\n\n", .{ subcommand, group_name });
                                try stderr.print("Run '{s} {s} --help' to see available subcommands.\n", .{ self.name, group_name });
                                return;
                            };
                            defer self.allocator.free(available_subcommands);

                            try CLIErrors.handleSubcommandNotFound(stderr, group_name, subcommand, available_subcommands, self.name, self.allocator);
                            return;
                        }
                    }
                }
            }

            // Fallback if group not found or not a group
            try stderr.print("Error: Unknown subcommand '{s}' for '{s}'\n\n", .{ subcommand, group_name });
            try stderr.print("Run '{s} {s} --help' to see available subcommands.\n", .{ self.name, group_name });
        }

        fn showSubcommandHelp(self: *Self, group_name: []const u8, group: anytype) !void {
            const stdout = std.io.getStdOut().writer();

            // Check if group has an index command with meta information
            if (@hasField(@TypeOf(group), "_index")) {
                const index_cmd = @field(group, "_index");
                if (@hasField(@TypeOf(index_cmd), "module")) {
                    const module = index_cmd.module;
                    if (@hasDecl(module, "meta")) {
                        const meta = module.meta;
                        if (@hasField(@TypeOf(meta), "description")) {
                            try stdout.print("{s}\n\n", .{meta.description});
                        }
                    }
                }
            } else {
                try stdout.print("Command group: {s}\n\n", .{group_name});
            }

            try stdout.print("USAGE:\n", .{});
            try stdout.print("    {s} {s} <SUBCOMMAND>\n\n", .{ self.name, group_name });

            try stdout.print("SUBCOMMANDS:\n", .{});
            try generateSubcommandsList(group, stdout);
            try stdout.print("\n", .{});

            try stdout.print("Run '{s} {s} <subcommand> --help' for more information on a subcommand.\n", .{ self.name, group_name });
        }

        fn showCommandHelp(self: *Self, command_entry: anytype) !void {
            const stdout = std.io.getStdOut().writer();

            // For now, provide a simple fallback help message
            // TODO: Implement proper help extraction from command modules
            _ = command_entry;
            try stdout.print("Command-specific help for '{s}' (detailed help not yet implemented)\n", .{self.name});
            try stdout.print("Use '{s} --help' to see all available commands.\n", .{self.name});
        }
    };
}

// Tests
test "App initialization" {
    const allocator = std.testing.allocator;

    const TestRegistry = struct {
        commands: struct {} = .{},
    };

    const app = App(TestRegistry).init(allocator, TestRegistry{ .commands = .{} }, .{
        .name = "testapp",
        .version = "0.1.0",
        .description = "Test application",
    });

    try std.testing.expectEqualStrings("testapp", app.name);
    try std.testing.expectEqualStrings("0.1.0", app.version);
    try std.testing.expectEqualStrings("Test application", app.description);
}

test "parseGlobalOptions help flag" {
    const TestRegistry = struct {
        commands: struct {} = .{},
    };

    const allocator = std.testing.allocator;
    var app = App(TestRegistry).init(allocator, TestRegistry{ .commands = .{} }, .{
        .name = "testapp",
        .version = "1.0.0",
        .description = "Test",
    });

    // Test --help
    {
        const args = [_][]const u8{"--help"};
        const result = try app.parseGlobalOptions(&args);
        try std.testing.expectEqual(true, result.help);
        try std.testing.expectEqual(false, result.version);
    }

    // Test -h
    {
        const args = [_][]const u8{"-h"};
        const result = try app.parseGlobalOptions(&args);
        try std.testing.expectEqual(true, result.help);
    }
}

test "parseGlobalOptions version flag" {
    const TestRegistry = struct {
        commands: struct {} = .{},
    };

    const allocator = std.testing.allocator;
    var app = App(TestRegistry).init(allocator, TestRegistry{ .commands = .{} }, .{
        .name = "testapp",
        .version = "1.0.0",
        .description = "Test",
    });

    // Test --version
    {
        const args = [_][]const u8{"--version"};
        const result = try app.parseGlobalOptions(&args);
        try std.testing.expectEqual(false, result.help);
        try std.testing.expectEqual(true, result.version);
    }

    // Test -V (capital V for version)
    {
        const args = [_][]const u8{"-V"};
        const result = try app.parseGlobalOptions(&args);
        try std.testing.expectEqual(true, result.version);
    }
}

test "parseGlobalOptions with commands" {
    const TestRegistry = struct {
        commands: struct {} = .{},
    };

    const allocator = std.testing.allocator;
    var app = App(TestRegistry).init(allocator, TestRegistry{ .commands = .{} }, .{
        .name = "testapp",
        .version = "1.0.0",
        .description = "Test",
    });

    const args = [_][]const u8{ "build", "--verbose", "src/" };
    const result = try app.parseGlobalOptions(&args);

    try std.testing.expectEqual(false, result.help);
    try std.testing.expectEqual(false, result.version);
    try std.testing.expectEqual(@as(usize, 3), result.remaining_args.len);
    try std.testing.expectEqualStrings("build", result.remaining_args[0]);
}

test "Context creation" {
    const allocator = std.testing.allocator;

    // Just verify the Context struct can be created
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    const ctx = Context{
        .allocator = allocator,
        .io = IO{
            .stdout = std.io.getStdOut().writer(),
            .stderr = std.io.getStdErr().writer(),
            .stdin = std.io.getStdIn().reader(),
        },
        .environment = Environment{
            .env = env,
        },
    };

    _ = ctx;
}
