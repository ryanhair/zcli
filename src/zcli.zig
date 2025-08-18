const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const error_handler = @import("errors.zig");
const execution = @import("execution.zig");

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
/// Returns a `ParseResult` with either successful parsing or structured error details.
///
/// **Memory Management**: ⚠️ CRITICAL - Array options allocate memory!
/// ```zig
/// const result = parseOptions(Options, allocator, args);
/// switch (result) {
///     .ok => |parsed| {
///         defer cleanupOptions(Options, parsed.options, allocator);  // REQUIRED!
///         // Use parsed.options...
///     },
///     .err => |structured_err| {
///         // Handle structured_err with rich context
///     },
/// }
/// ```
///
/// 📖 See [MEMORY.md](../../../MEMORY.md) for detailed memory management guide.
pub const parseOptions = options_parser.parseOptions;

/// Parse command-line options with custom metadata for option names.
///
/// Returns a `ParseResult` with either successful parsing or structured error details.
///
/// **Memory Management**: ⚠️ CRITICAL - Array options allocate memory!
/// Always call `cleanupOptions` when done. See `parseOptions` for details.
///
/// 📖 See [MEMORY.md](../../../MEMORY.md) for detailed memory management guide.
pub const parseOptionsWithMeta = options_parser.parseOptionsWithMeta;

/// Parse options from anywhere in arguments, returning options and remaining positional arguments.
///
/// Returns a `ParseResult` with either successful parsing or structured error details.
/// This function separates options from positional arguments regardless of their order.
///
/// **Memory Management**: ⚠️ CRITICAL - Both array options AND remaining_args allocate memory!
/// ```zig
/// const result = parseOptionsAndArgs(Options, meta, allocator, args);
/// switch (result) {
///     .ok => |parsed| {
///         defer cleanupOptions(Options, parsed.options, allocator);  // REQUIRED!
///         defer parsed.deinit();  // REQUIRED for remaining_args!
///         // Use parsed.options and parsed.remaining_args...
///     },
///     .err => |structured_err| {
///         // Handle structured_err with rich context
///     },
/// }
/// ```
///
/// 📖 See [MEMORY.md](../../../MEMORY.md) for detailed memory management guide.
pub const parseOptionsAndArgs = options_parser.parseOptionsAndArgs;

/// Clean up memory allocated for array options by parseOptions/parseOptionsWithMeta.
///
/// **When to use**: Required for all direct API usage with array options.
/// **Framework mode**: Cleanup is automatic - don't call this manually.
///
/// 📖 See [MEMORY.md](../../../MEMORY.md) for detailed memory management guide.
pub const cleanupOptions = options_parser.cleanupOptions;

/// Error types for argument parsing failures.
///
/// **Note**: This is the legacy error type for backwards compatibility.
/// New code should use `parseArgs()` which returns `ParseResult` with rich structured errors
/// that provide detailed context including field names, positions, and expected types.
///
/// These errors can occur when parsing positional arguments:
/// - `InvalidArgumentType`: Argument cannot be parsed to expected type
/// - `OutOfMemory`: Memory allocation failed
pub const ParseError = args_parser.ParseError;

// Main help generation (removed - now handled by plugins)

// ============================================================================
// ADVANCED API - Lower-level functions for advanced use cases
// ============================================================================

// Advanced help generation (removed - now handled by plugins)

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
// PLUGIN PIPELINE API - Base types for plugin transformers
// ============================================================================

/// Base command executor that plugins can transform.
/// Plugins wrap this to add functionality like logging, auth, metrics, etc.
pub const BaseCommandExecutor = execution.BaseCommandExecutor;

/// Base error handler that plugins can transform.
/// Plugins wrap this to add custom error handling, suggestions, telemetry, etc.
pub const BaseErrorHandler = execution.BaseErrorHandler;

/// Base help generator that plugins can transform.
/// Plugins wrap this to customize help output, add examples, etc.
pub const BaseHelpGenerator = execution.BaseHelpGenerator;

// ============================================================================
// INTERNAL API - Used by the App struct, not intended for direct user access
// ============================================================================

// Internal help utilities (minimal fallback implementations when plugins aren't available)
fn getAvailableCommands(comptime registry: anytype, allocator: std.mem.Allocator) ![][]const u8 {
    const commands = registry.commands;
    const CommandsType = @TypeOf(commands);

    // Count available commands (excluding metadata fields)
    comptime var count: usize = 0;
    inline for (@typeInfo(CommandsType).@"struct".fields) |field| {
        comptime if (std.mem.startsWith(u8, field.name, "_")) continue;
        count += 1;
    }

    // Allocate and fill array
    var result = try allocator.alloc([]const u8, count);
    var i: usize = 0;
    inline for (@typeInfo(CommandsType).@"struct".fields) |field| {
        comptime if (std.mem.startsWith(u8, field.name, "_")) continue;
        result[i] = field.name;
        i += 1;
    }

    return result;
}

fn getAvailableSubcommands(comptime group: anytype, allocator: std.mem.Allocator) ![][]const u8 {
    const GroupType = @TypeOf(group);

    // Count available subcommands (excluding metadata fields)
    comptime var count: usize = 0;
    inline for (@typeInfo(GroupType).@"struct".fields) |field| {
        comptime if (std.mem.startsWith(u8, field.name, "_")) continue;
        count += 1;
    }

    // Allocate and fill array
    var result = try allocator.alloc([]const u8, count);
    var i: usize = 0;
    inline for (@typeInfo(GroupType).@"struct".fields) |field| {
        comptime if (std.mem.startsWith(u8, field.name, "_")) continue;
        result[i] = field.name;
        i += 1;
    }

    return result;
}

// Import structured error types
const StructuredError = @import("structured_errors.zig").StructuredError;
const CommandErrorContext = @import("structured_errors.zig").CommandErrorContext;

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
    
    pub fn init() IO {
        return IO{
            .stdout = std.io.getStdOut().writer(),
            .stderr = std.io.getStdErr().writer(),
            .stdin = std.io.getStdIn().reader(),
        };
    }
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
    
    pub fn init() Environment {
        // Note: This returns a placeholder environment
        // The env field will be properly initialized by the caller
        const placeholder_env = std.process.EnvMap.init(std.heap.page_allocator);
        return Environment{
            .env = placeholder_env,
        };
    }
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
pub fn App(comptime Registry: type, comptime RegistryModule: anytype) type {
    const ContextType = if (@TypeOf(RegistryModule) != @TypeOf(null)) 
        RegistryModule.Context 
    else 
        Context;
    
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

            // Handle --version (this stays in core as it's app metadata)
            if (parsed.version) {
                try self.showVersion();
                return;
            }

            // Check for global help flag and use help pipeline if available
            if (parsed.remaining_args.len > 0 and 
                (std.mem.eql(u8, parsed.remaining_args[0], "--help") or 
                 std.mem.eql(u8, parsed.remaining_args[0], "-h"))) {
                try self.showGlobalHelp();
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

        fn parseGlobalOptions(_: *Self, args: []const []const u8) !struct {
            version: bool,
            remaining_args: []const []const u8,
        } {
            // Simple parsing for --version only
            // Help flags are handled by the help plugin
            var version = false;
            var first_non_option: usize = 0;

            for (args, 0..) |arg, i| {
                if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                    version = true;
                } else if (!std.mem.startsWith(u8, arg, "-")) {
                    first_non_option = i;
                    break;
                }
            }

            return .{
                .version = version,
                .remaining_args = args[first_non_option..],
            };
        }


        fn showVersion(self: *Self) !void {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("{s} v{s}\n", .{ self.name, self.version });
        }

        fn showGlobalHelp(self: *Self) !void {
            // Use the help pipeline if available, otherwise show minimal help
            if (@TypeOf(RegistryModule) != @TypeOf(null) and @hasDecl(RegistryModule, "help_pipeline")) {
                // Create context for help generation
                var env = std.process.EnvMap.init(self.allocator);
                defer env.deinit();

                // Use the appropriate context type based on registry module
                var context = if (@TypeOf(RegistryModule) != @TypeOf(null)) 
                    try RegistryModule.initContext(self.allocator)
                else
                    ContextType{
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
                
                // Cleanup context if it has deinit
                defer if (@hasDecl(@TypeOf(context), "deinit")) context.deinit();

                // Add app information to context
                if (@hasField(@TypeOf(context), "app_name")) {
                    context.app_name = self.name;
                }
                if (@hasField(@TypeOf(context), "app_version")) {
                    context.app_version = self.version;
                }
                if (@hasField(@TypeOf(context), "app_description")) {
                    context.app_description = self.description;
                }

                // Use the help pipeline
                const help_text = try RegistryModule.HelpPipeline.generate(context, null);
                defer self.allocator.free(help_text);
                
                const stdout = std.io.getStdOut().writer();
                try stdout.print("{s}\n", .{help_text});
            } else {
                // Fallback to minimal help when no help pipeline is available
                const stdout = std.io.getStdOut().writer();
                try stdout.print("{s} v{s} - {s}\n\n", .{ self.name, self.version, self.description });
                try stdout.print("USAGE:\n", .{});
                try stdout.print("    {s} [command] [options]\n\n", .{self.name});
                try stdout.print("Install zcli-help plugin for detailed help information.\n", .{});
            }
        }

        fn runRootCommand(self: *Self) !void {
            // Check if root command exists in registry
            if (@hasField(@TypeOf(self.registry.commands), "root")) {
                const root_cmd = @field(self.registry.commands, "root");
                try self.executeCommand(root_cmd, &.{});
            } else {
                // No root command available and no help plugin
                const stderr = std.io.getStdErr().writer();
                try stderr.print("No root command available. Use '--help' for assistance.\n", .{});
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

            // Check for help flags and use help pipeline if available
            if (args.len > 0 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) {
                try self.showSubcommandGroupHelp(group_name);
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
            // Help flags are now handled by the help plugin via command transformation

            // Create context for command execution
            var env = std.process.EnvMap.init(self.allocator);
            defer env.deinit();

            // Use the appropriate context type based on registry module
            var context = if (@TypeOf(RegistryModule) != @TypeOf(null)) 
                try RegistryModule.initContext(self.allocator)
            else
                ContextType{
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
            
            // Cleanup context if it has deinit
            defer if (@hasDecl(@TypeOf(context), "deinit")) context.deinit();

            // Check if this is a command entry struct with .execute field
            const TypeInfo = @typeInfo(@TypeOf(command_entry));
            if (TypeInfo == .@"struct" and @hasField(@TypeOf(command_entry), "execute")) {
                // Use the command pipeline if available, otherwise fall back to direct execution
                if (@TypeOf(RegistryModule) != @TypeOf(null) and @hasDecl(RegistryModule, "CommandPipeline")) {
                    // Create a command wrapper that delegates to the registry execution function
                    const CommandWrapper = struct {
                        entry: @TypeOf(command_entry),
                        args: []const []const u8,
                        allocator: std.mem.Allocator,
                        context_ptr: *@TypeOf(context),
                        
                        pub fn execute(ctx: anytype, wrapper: @This()) !void {
                            _ = ctx; // Context is already in wrapper.context_ptr
                            try wrapper.entry.execute(wrapper.args, wrapper.allocator, wrapper.context_ptr);
                        }
                    };
                    
                    const wrapper = CommandWrapper{
                        .entry = command_entry,
                        .args = args,
                        .allocator = self.allocator,
                        .context_ptr = &context,
                    };
                    
                    try RegistryModule.CommandPipeline.execute(context, wrapper);
                } else {
                    // Fallback to direct execution for backwards compatibility
                    try command_entry.execute(args, self.allocator, &context);
                }
            }
        }

        fn showCommandNotFound(self: *Self, command: []const u8) !void {
            // Use the error pipeline if available, otherwise fall back to direct error handling
            if (@hasDecl(@TypeOf(self.registry), "error_pipeline")) {
                // Create context for error handling
                var env = std.process.EnvMap.init(self.allocator);
                defer env.deinit();

                // Use the appropriate context type based on registry module
                var context = if (@TypeOf(RegistryModule) != @TypeOf(null)) 
                    try RegistryModule.initContext(self.allocator)
                else
                    ContextType{
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
                
                // Cleanup context if it has deinit
                defer if (@hasDecl(@TypeOf(context), "deinit")) context.deinit();

                // Add error-specific information to context
                if (@hasField(@TypeOf(context), "attempted_command")) {
                    context.attempted_command = command;
                }
                
                if (@hasField(@TypeOf(context), "available_commands")) {
                    context.available_commands = getAvailableCommands(self.registry, self.allocator) catch &[_][]const u8{};
                    defer if (context.available_commands.len > 0) self.allocator.free(context.available_commands);
                }
                
                if (@hasField(@TypeOf(context), "app_name")) {
                    context.app_name = self.name;
                }

                // Use the error pipeline
                try @TypeOf(self.registry).error_pipeline.handle(error.CommandNotFound, context);
            } else {
                // Fallback to direct error handling for backwards compatibility
                const stderr = std.io.getStdErr().writer();

                // Try to get available commands for suggestions
                const available_commands = getAvailableCommands(self.registry, self.allocator) catch {
                    try stderr.print("Error: Unknown command '{s}'\n\n", .{command});
                    try stderr.print("Run '{s} --help' to see available commands.\n", .{self.name});
                    return;
                };
                defer self.allocator.free(available_commands);

                // Use the error handler module for suggestions
                try error_handler.handleCommandNotFound(stderr, command, available_commands, self.name, self.allocator);
            }
        }

        fn showSubcommandNotFound(self: *Self, group: []const u8, subcommand: []const u8) !void {
            const stderr = std.io.getStdErr().writer();

            // Create structured error
            const structured_error = StructuredError{ .subcommand_not_found = CommandErrorContext.unknownSubcommand(subcommand, &[_][]const u8{group}) };

            // Display the structured error and available subcommands
            try self.showSubcommandNotFoundComptime(self.registry.commands, group, subcommand, stderr, structured_error);
        }

        fn showSubcommandNotFoundComptime(self: *Self, commands: anytype, group_name: []const u8, subcommand: []const u8, stderr: anytype, structured_error: StructuredError) !void {
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
                                // Fallback to simple error display
                                const description = try structured_error.description(self.allocator);
                                defer self.allocator.free(description);
                                try stderr.print("Error: {s}\n\n", .{description});
                                try stderr.print("Run '{s} {s} --help' to see available subcommands.\n", .{ self.name, group_name });
                                return;
                            };
                            defer self.allocator.free(available_subcommands);

                            // Try to get suggestions
                            const suggestions = error_handler.findSimilarCommands(subcommand, available_subcommands, self.allocator) catch null;
                            if (suggestions) |sug| {
                                defer self.allocator.free(sug);
                                // Create error with suggestions
                                var error_with_suggestions = structured_error;
                                error_with_suggestions.subcommand_not_found.suggested_commands = sug;

                                const description = try error_with_suggestions.description(self.allocator);
                                defer self.allocator.free(description);
                                try stderr.print("Error: {s}\n\n", .{description});

                                // Show suggestions
                                if (error_with_suggestions.suggestions()) |cmd_suggestions| {
                                    try stderr.print("Did you mean:\n", .{});
                                    for (cmd_suggestions[0..@min(3, cmd_suggestions.len)]) |suggestion| {
                                        try stderr.print("    {s}\n", .{suggestion});
                                    }
                                    try stderr.print("\n", .{});
                                }
                            } else {
                                // Display without suggestions
                                const description = try structured_error.description(self.allocator);
                                defer self.allocator.free(description);
                                try stderr.print("Error: {s}\n\n", .{description});
                            }

                            // Show available subcommands
                            try stderr.print("Available subcommands for '{s}':\n", .{group_name});
                            for (available_subcommands) |subcmd| {
                                try stderr.print("    {s}\n", .{subcmd});
                            }
                            try stderr.print("\n", .{});
                            try stderr.print("Run '{s} {s} --help' for more information.\n", .{ self.name, group_name });
                            return;
                        }
                    }
                }
            }

            // Fallback if group not found or not a group
            const description = try structured_error.description(self.allocator);
            defer self.allocator.free(description);
            try stderr.print("Error: {s}\n\n", .{description});
            try stderr.print("Run '{s} {s} --help' to see available subcommands.\n", .{ self.name, group_name });
        }

        fn showSubcommandHelp(self: *Self, group_name: []const u8, group: anytype) !void {
            _ = self;
            _ = group; // No longer used
            const stderr = std.io.getStdErr().writer();
            try stderr.print("No subcommand specified for '{s}'. Install zcli-help plugin for assistance.\n", .{group_name});
        }

        fn showSubcommandGroupHelp(self: *Self, group_name: []const u8) !void {
            // Use the help pipeline if available, otherwise show minimal help
            if (@TypeOf(RegistryModule) != @TypeOf(null) and @hasDecl(RegistryModule, "HelpPipeline")) {
                // Create context for help generation
                var env = std.process.EnvMap.init(self.allocator);
                defer env.deinit();

                // Use the appropriate context type based on registry module
                var context = if (@TypeOf(RegistryModule) != @TypeOf(null)) 
                    try RegistryModule.initContext(self.allocator)
                else
                    ContextType{
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
                
                // Cleanup context if it has deinit
                defer if (@hasDecl(@TypeOf(context), "deinit")) context.deinit();

                // Add app information to context
                if (@hasField(@TypeOf(context), "app_name")) {
                    context.app_name = self.name;
                }
                if (@hasField(@TypeOf(context), "app_version")) {
                    context.app_version = self.version;
                }
                if (@hasField(@TypeOf(context), "app_description")) {
                    context.app_description = self.description;
                }

                // Use the help pipeline with group name as command name
                const help_text = try RegistryModule.HelpPipeline.generate(context, group_name);
                defer self.allocator.free(help_text);
                
                const stdout = std.io.getStdOut().writer();
                try stdout.print("{s}\n", .{help_text});
            } else {
                // Fallback to minimal help when no help pipeline is available
                const stdout = std.io.getStdOut().writer();
                try stdout.print("{s} {s} - subcommand group\n\n", .{ self.name, group_name });
                try stdout.print("USAGE:\n", .{});
                try stdout.print("    {s} {s} <subcommand> [options]\n\n", .{ self.name, group_name });
                try stdout.print("Install zcli-help plugin for detailed subcommand information.\n", .{});
            }
        }

    };
}

// Tests
test "App initialization" {
    const allocator = std.testing.allocator;

    const TestRegistry = struct {
        commands: struct {} = .{},
    };

    const app = App(TestRegistry, null).init(allocator, TestRegistry{ .commands = .{} }, .{
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
    var app = App(TestRegistry, null).init(allocator, TestRegistry{ .commands = .{} }, .{
        .name = "testapp",
        .version = "1.0.0",
        .description = "Test",
    });

    // Help flags are now handled by the help plugin, not in parseGlobalOptions
    // Test that help flags are passed through as remaining args
    {
        const args = [_][]const u8{"--help"};
        const result = try app.parseGlobalOptions(&args);
        try std.testing.expectEqual(false, result.version);
        try std.testing.expectEqual(@as(usize, 1), result.remaining_args.len);
        try std.testing.expectEqualStrings("--help", result.remaining_args[0]);
    }

    // Test -h
    {
        const args = [_][]const u8{"-h"};
        const result = try app.parseGlobalOptions(&args);
        try std.testing.expectEqual(@as(usize, 1), result.remaining_args.len);
        try std.testing.expectEqualStrings("-h", result.remaining_args[0]);
    }
}

test "parseGlobalOptions version flag" {
    const TestRegistry = struct {
        commands: struct {} = .{},
    };

    const allocator = std.testing.allocator;
    var app = App(TestRegistry, null).init(allocator, TestRegistry{ .commands = .{} }, .{
        .name = "testapp",
        .version = "1.0.0",
        .description = "Test",
    });

    // Test --version
    {
        const args = [_][]const u8{"--version"};
        const result = try app.parseGlobalOptions(&args);
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
    var app = App(TestRegistry, null).init(allocator, TestRegistry{ .commands = .{} }, .{
        .name = "testapp",
        .version = "1.0.0",
        .description = "Test",
    });

    const args = [_][]const u8{ "build", "--verbose", "src/" };
    const result = try app.parseGlobalOptions(&args);

    try std.testing.expectEqual(false, result.version);
    try std.testing.expectEqual(@as(usize, 3), result.remaining_args.len);
    try std.testing.expectEqualStrings("build", result.remaining_args[0]);
}

test "Context creation" {
    const allocator = std.testing.allocator;

    // Just verify the Context struct can be created
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    _ = Context{
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
}
