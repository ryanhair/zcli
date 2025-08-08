const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const help_generator = @import("help.zig");
const error_handler = @import("errors.zig");

// ============================================================================
// PUBLIC API - Core functionality for end users
// ============================================================================

/// Parse positional arguments from command-line arguments into a struct.
///
/// **Memory Management**: No cleanup required - references input args directly.
/// Keep `args` parameter alive while using the returned struct.
///
/// 📖 See [MEMORY.md](../../../MEMORY.md) for detailed memory management guide.
pub const parseArgs = args_parser.parseArgs;

/// Parse command-line options into a struct using default field names.
///
/// **Memory Management**: ⚠️ CRITICAL - Array options allocate memory!
/// ```zig
/// const result = try parseOptions(Options, allocator, args);
/// defer cleanupOptions(Options, result.options, allocator);  // REQUIRED!
/// ```
///
/// 📖 See [MEMORY.md](../../../MEMORY.md) for detailed memory management guide.
pub const parseOptions = options_parser.parseOptions;

/// Parse command-line options with custom metadata for option names.
///
/// **Memory Management**: ⚠️ CRITICAL - Array options allocate memory!
/// Always call `cleanupOptions` when done. See `parseOptions` for details.
///
/// 📖 See [MEMORY.md](../../../MEMORY.md) for detailed memory management guide.
pub const parseOptionsWithMeta = options_parser.parseOptionsWithMeta;

/// Clean up memory allocated for array options by parseOptions/parseOptionsWithMeta.
///
/// **When to use**: Required for all direct API usage with array options.
/// **Framework mode**: Cleanup is automatic - don't call this manually.
///
/// 📖 See [MEMORY.md](../../../MEMORY.md) for detailed memory management guide.
pub const cleanupOptions = options_parser.cleanupOptions;

/// Error types for argument parsing failures.
///
/// These errors can occur when parsing positional arguments with `parseArgs`:
/// - `MissingRequiredArgument`: Required argument not provided
/// - `InvalidValue`: Argument cannot be parsed to expected type
/// - `TooManyArguments`: More arguments than expected (unless using varargs)
pub const ParseError = args_parser.ParseError;

/// Error types for command-line option parsing failures.
///
/// These errors can occur when parsing options with `parseOptions`:
/// - `UnknownOption`: Option not defined in Options struct
/// - `MissingOptionValue`: Option requires value but none provided
/// - `InvalidOptionValue`: Option value cannot be parsed to expected type
/// - `DuplicateOption`: Same option specified multiple times
/// - `OutOfMemory`: Memory allocation failed
pub const OptionParseError = options_parser.OptionParseError;

/// General CLI error types for application-level failures.
///
/// These errors represent higher-level CLI application failures:
/// - `CommandNotFound`: Specified command doesn't exist
/// - `SubcommandNotFound`: Specified subcommand doesn't exist
/// - `HelpRequested`: User requested help (not really an error)
/// - `VersionRequested`: User requested version info (not really an error)
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

/// I/O abstraction for command input/output operations.
///
/// This struct groups together all I/O-related functionality that commands need,
/// providing a clean interface for reading input and writing output.
///
/// ## Fields
/// - `stdout`: Standard output writer for normal program output
/// - `stderr`: Standard error writer for error messages and diagnostics
/// - `stdin`: Standard input reader for interactive input
///
/// ## Usage
/// Commands receive this as part of the Context struct and can access I/O operations:
/// ```zig
/// pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
///     try context.io.stdout.print("Hello, world!\n", .{});
///     try context.io.stderr.print("Warning: something happened\n", .{});
/// }
/// ```
pub const IO = struct {
    stdout: std.fs.File.Writer,
    stderr: std.fs.File.Writer,
    stdin: std.fs.File.Reader,
};

/// Environment abstraction for accessing environment variables and system context.
///
/// This struct provides access to environment variables and system context
/// that commands might need during execution.
///
/// ## Fields
/// - `env`: Environment variable map for accessing system environment
///
/// ## Usage
/// Commands can access environment variables through the Context:
/// ```zig
/// pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
///     const home = context.environment.env.get("HOME");
///     if (home) |path| {
///         try context.io.stdout.print("Home: {s}\n", .{path});
///     }
/// }
/// ```
pub const Environment = struct {
    env: std.process.EnvMap,
};

/// Execution context provided to all command functions.
///
/// The Context struct contains everything a command needs to execute: memory allocation,
/// I/O operations, and environment access. This struct is automatically created and
/// passed to command functions by the zcli framework.
///
/// ## Fields
/// - `allocator`: Memory allocator for command-specific allocations
/// - `io`: I/O operations (stdout, stderr, stdin) grouped together
/// - `environment`: Environment variables and system context
///
/// ## Convenience Methods
/// For backward compatibility and cleaner syntax, Context provides direct access methods:
/// - `context.stdout()` - Returns stdout writer
/// - `context.stderr()` - Returns stderr writer
/// - `context.stdin()` - Returns stdin reader
/// - `context.env()` - Returns environment variable map
///
/// ## Examples
/// ```zig
/// pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
///     // Direct access to I/O
///     try context.stdout().print("Output: {s}\n", .{args.message});
///
///     // Or through the grouped interface
///     try context.io.stderr.print("Warning!\n", .{});
///
///     // Environment access
///     const home = context.env().get("HOME");
///
///     // Memory allocation
///     const buffer = try context.allocator.alloc(u8, 1024);
///     defer context.allocator.free(buffer);
/// }
/// ```
///
/// ## Memory Management
/// The allocator is provided for command-specific allocations. Commands should
/// properly free any memory they allocate, typically using `defer` statements.
///
/// **Framework Guarantee**: Option cleanup (for arrays) is handled automatically.
/// **Your Responsibility**: Free any memory you allocate with `context.allocator`.
///
/// ```zig
/// pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
///     // Framework handles options cleanup automatically
///     for (options.files) |file| { /* use freely */ }
///
///     // You must handle your own allocations
///     const buffer = try context.allocator.alloc(u8, 1024);
///     defer context.allocator.free(buffer);  // Required!
/// }
/// ```
///
/// 📖 See [MEMORY.md](../../../MEMORY.md) for comprehensive memory management guide.
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

/// Metadata structure for providing help text and usage information for commands.
///
/// Commands can optionally export a `meta` constant of this type to provide
/// rich help information that will be displayed when users request help.
///
/// ## Fields
/// - `description`: Brief description of what the command does (required)
/// - `usage`: Optional custom usage string (overrides auto-generated usage)
/// - `examples`: Optional array of example command invocations
///
/// ## Examples
/// ```zig
/// // In your command file (e.g., src/commands/hello.zig):
/// pub const meta = zcli.CommandMeta{
///     .description = "Say hello to someone",
///     .usage = "hello <name> [--loud]",
///     .examples = &.{
///         "hello World",
///         "hello Alice --loud",
///         "hello Bob --greeting 'Hi there'",
///     },
/// };
/// ```
///
/// ## Usage Pattern
/// The zcli framework automatically looks for a `meta` constant in command modules
/// and uses it to generate help text when users pass `--help` or `-h`.
///
/// ## Auto-Generated vs Custom Usage
/// If `usage` is null, zcli will auto-generate usage text based on Args and Options structs.
/// Provide a custom usage string when you need more specific formatting or descriptions.
pub const CommandMeta = struct {
    description: []const u8,
    usage: ?[]const u8 = null,
    examples: ?[]const []const u8 = null,
};

/// Create a CLI application struct with automatic command routing and help generation.
///
/// This function returns a struct type that handles all CLI application logic including
/// argument parsing, command routing, help generation, and error handling. The Registry
/// parameter is typically generated at build time by scanning your commands directory.
///
/// ## Parameters
/// - `Registry`: Command registry type generated by build system from commands directory
///
/// ## Returns
/// Returns a struct type with methods for initializing and running the CLI application.
///
/// ## Examples
/// ```zig
/// // In your main.zig:
/// const registry = @import("command_registry");
/// const MyApp = zcli.App(@TypeOf(registry));
///
/// pub fn main() !void {
///     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
///     defer _ = gpa.deinit();
///
///     const app = MyApp.init(gpa.allocator(), registry, .{
///         .name = "myapp",
///         .version = "1.0.0",
///         .description = "My CLI application",
///     });
///
///     const args = try std.process.argsAlloc(gpa.allocator());
///     defer std.process.argsFree(gpa.allocator(), args);
///
///     try app.run(args[1..]);
/// }
/// ```
///
/// ## Generated Methods
/// The returned struct provides:
/// - `init(allocator, registry, options)` - Create app instance
/// - `run(args)` - Execute the CLI with given arguments
/// - Internal routing and help generation methods
///
/// ## Build Integration
/// Typically used with build-time command registry generation:
/// ```zig
/// // In build.zig:
/// const registry = zcli.generateCommandRegistry(b, target, optimize, zcli_module, .{
///     .commands_dir = "src/commands",
///     .app_name = "myapp",
///     .app_version = "1.0.0",
///     .app_description = "My CLI application",
/// });
/// ```
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
