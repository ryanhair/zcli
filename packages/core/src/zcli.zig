const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const command_parser = @import("command_parser.zig");
const error_handler = @import("errors.zig");
const execution = @import("execution.zig");
pub const plugin_types = @import("plugin_types.zig");
pub const registry = @import("registry.zig");
const diagnostic_errors = @import("diagnostic_errors.zig");
const type_utils = @import("type_utils.zig");
pub const ztheme = @import("ztheme");
pub const markdown_fmt = @import("markdown_fmt");
pub const zprogress = @import("zprogress");
pub const test_utils = @import("test_utils.zig");
const testing = std.testing;

// Re-export error types
pub const ZcliError = diagnostic_errors.ZcliError;
pub const ZcliDiagnostic = diagnostic_errors.ZcliDiagnostic;

// Re-export plugin types for user convenience
pub const Metadata = plugin_types.Metadata;
pub const PluginResult = plugin_types.PluginResult;

// Re-export new plugin system types
pub const GlobalOption = plugin_types.GlobalOption;
pub const TransformResult = plugin_types.TransformResult;
pub const ParsedArgs = plugin_types.ParsedArgs;
pub const GlobalOptionsResult = plugin_types.GlobalOptionsResult;
pub const PluginEntry = plugin_types.PluginEntry;
pub const option = plugin_types.option;

// Re-export standard empty types
pub const NoArgs = type_utils.NoArgs;
pub const NoOptions = type_utils.NoOptions;

// ============================================================================
// Context for Command Execution
// ============================================================================

/// Command metadata for help generation and introspection
pub const CommandMeta = struct {
    description: ?[]const u8 = null,
    examples: ?[]const []const u8 = null,
};

/// Command information available to plugins for introspection
/// Option information for shell completions and introspection
pub const OptionInfo = struct {
    name: []const u8,
    short: ?u8 = null,
    description: ?[]const u8 = null,
    takes_value: bool = false,
};

/// Argument information for introspection and documentation
pub const ArgInfo = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    is_optional: bool = false,
    is_variadic: bool = false,
};

/// Command information for introspection, completions, and documentation
pub const CommandInfo = struct {
    path: []const []const u8,
    description: ?[]const u8 = null,
    examples: ?[]const []const u8 = null,
    args: []const ArgInfo = &.{},
    options: []const OptionInfo = &.{},
    hidden: bool = false,
    aliases: []const []const u8 = &.{},
};

/// Field info that can be stored at runtime
pub const FieldInfo = struct {
    name: []const u8,
    is_optional: bool,
    is_array: bool,
    // Metadata for help generation
    short: ?u8 = null,
    description: ?[]const u8 = null,
};

/// Information about command module structure for plugin introspection
pub const CommandModuleInfo = struct {
    has_args: bool = false,
    has_options: bool = false,
    raw_meta_ptr: ?*const anyopaque = null, // Points to cmd.module.meta
    args_fields: []const FieldInfo = &.{}, // Runtime-safe field info
    options_fields: []const FieldInfo = &.{}, // Runtime-safe field info
};

/// Execution context provided to commands and plugins
/// Base Context type definition.
/// Note: The actual Context type used at runtime is computed by the Registry
/// based on registered plugins. This struct defines the common interface.
/// Use the Context exported from your command_registry module instead.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: *IO,
    environment: Environment,

    // Core zcli command execution context
    app_name: []const u8 = "app",
    app_version: []const u8 = "unknown",
    app_description: []const u8 = "",
    available_commands: []const []const []const u8 = &.{},
    command_path: []const []const u8 = &.{},
    command_path_allocated: bool = false,
    command_meta: ?CommandMeta = null,
    command_module_info: ?CommandModuleInfo = null,

    // Plugin-specific command information for introspection
    plugin_command_info: []const CommandInfo = &.{},
    global_options: []const OptionInfo = &.{},

    const Self = @This();

    /// Initialize a new Context with the provided IO.
    pub fn init(allocator: std.mem.Allocator, io: *IO) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .environment = Environment.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free command_path only if it was allocated
        if (self.command_path_allocated and self.command_path.len > 0) {
            for (self.command_path) |component| {
                self.allocator.free(component);
            }
            self.allocator.free(self.command_path);
        }

        // Free allocated field info arrays
        if (self.command_module_info) |info| {
            if (info.args_fields.len > 0) {
                self.allocator.free(info.args_fields);
            }
            if (info.options_fields.len > 0) {
                self.allocator.free(info.options_fields);
            }
        }

        self.environment.deinit();
    }

    // Convenience methods for I/O
    pub fn stdout(self: *Self) *std.Io.Writer {
        return self.io.stdout();
    }

    pub fn stderr(self: *Self) *std.Io.Writer {
        return self.io.stderr();
    }

    pub fn stdin(self: *Self) *std.Io.Reader {
        return self.io.stdin();
    }

    pub fn exit(_: *Self, code: u8) void {
        std.process.exit(code);
    }

    /// Get command description by path (for plugins)
    /// Returns null if command not found or has no description
    pub fn getCommandDescription(self: *Self, command_path_query: []const []const u8) ?[]const u8 {
        for (self.plugin_command_info) |cmd_info| {
            if (command_path_query.len == cmd_info.path.len) {
                var matches = true;
                for (command_path_query, cmd_info.path) |provided_part, stored_part| {
                    if (!std.mem.eql(u8, provided_part, stored_part)) {
                        matches = false;
                        break;
                    }
                }
                if (matches) {
                    return cmd_info.description;
                }
            }
        }
        return null;
    }

    /// Get all available command information (for plugins)
    pub fn getAvailableCommandInfo(self: *Self) []const CommandInfo {
        return self.plugin_command_info;
    }

    /// Get all global options (for completions)
    pub fn getGlobalOptions(self: *Self) []const OptionInfo {
        return self.global_options;
    }
};

/// Create a test context type with plugin data support.
/// Use this when testing code that accesses `context.plugins.{plugin_id}`.
///
/// ```zig
/// const TestCtx = zcli.TestContext(&.{ MyPlugin });
/// var io = zcli.IO.init();
/// io.finalize();
/// var ctx = TestCtx.init(testing.allocator, &io);
/// defer ctx.deinit();
/// ctx.plugins.my_plugin.some_field = true;
/// ```
pub fn TestContext(comptime test_plugins: []const type) type {
    // Build the plugins struct type from the provided plugins
    const PluginsType = comptime blk: {
        var field_count: usize = 0;
        for (test_plugins) |Plugin| {
            if (@hasDecl(Plugin, "ContextData")) {
                field_count += 1;
            }
        }

        if (field_count == 0) {
            break :blk struct {};
        }

        var fields: [field_count]std.builtin.Type.StructField = undefined;
        var idx: usize = 0;

        for (test_plugins) |Plugin| {
            if (@hasDecl(Plugin, "ContextData")) {
                if (!@hasDecl(Plugin, "plugin_id")) {
                    @compileError("Plugins with ContextData must declare 'pub const plugin_id'.");
                }

                const DataType = Plugin.ContextData;
                const default_val: DataType = .{};

                // Sanitize plugin_id to valid identifier
                const id: []const u8 = Plugin.plugin_id;
                var name_buf: [256]u8 = undefined;
                var name_len: usize = 0;
                for (id) |c| {
                    if (name_len >= name_buf.len - 1) break;
                    name_buf[name_len] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
                    name_len += 1;
                }
                name_buf[name_len] = 0;

                fields[idx] = .{
                    .name = name_buf[0..name_len :0],
                    .type = DataType,
                    .default_value_ptr = @ptrCast(&default_val),
                    .is_comptime = false,
                    .alignment = @alignOf(DataType),
                };
                idx += 1;
            }
        }

        break :blk @Type(.{
            .@"struct" = .{
                .fields = &fields,
                .layout = .auto,
                .decls = &.{},
                .is_tuple = false,
            },
        });
    };

    return struct {
        allocator: std.mem.Allocator,
        io: *IO,
        environment: Environment,
        theme: ztheme.Theme = .{ .capability = .true_color, .is_tty = true, .color_enabled = true },

        app_name: []const u8 = "test-app",
        app_version: []const u8 = "0.0.0",
        app_description: []const u8 = "",
        available_commands: []const []const []const u8 = &.{},
        command_path: []const []const u8 = &.{},
        command_path_allocated: bool = false,
        command_meta: ?CommandMeta = null,
        command_module_info: ?CommandModuleInfo = null,
        plugin_command_info: []const CommandInfo = &.{},
        global_options: []const OptionInfo = &.{},

        plugins: PluginsType = .{},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, io: *IO) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .environment = Environment.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.command_path_allocated and self.command_path.len > 0) {
                for (self.command_path) |component| {
                    self.allocator.free(component);
                }
                self.allocator.free(self.command_path);
            }
            if (self.command_module_info) |info| {
                if (info.args_fields.len > 0) self.allocator.free(info.args_fields);
                if (info.options_fields.len > 0) self.allocator.free(info.options_fields);
            }
            self.environment.deinit();
        }

        pub fn stdout(self: *Self) *std.Io.Writer {
            return self.io.stdout();
        }

        pub fn stderr(self: *Self) *std.Io.Writer {
            return self.io.stderr();
        }

        pub fn stdin(self: *Self) *std.Io.Reader {
            return self.io.stdin();
        }

        pub fn getCommandDescription(self: *Self, command_path_query: []const []const u8) ?[]const u8 {
            for (self.plugin_command_info) |cmd_info| {
                if (command_path_query.len == cmd_info.path.len) {
                    var matches = true;
                    for (command_path_query, cmd_info.path) |provided_part, stored_part| {
                        if (!std.mem.eql(u8, provided_part, stored_part)) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) return cmd_info.description;
                }
            }
            return null;
        }

        pub fn getAvailableCommandInfo(self: *Self) []const CommandInfo {
            return self.plugin_command_info;
        }

        pub fn getGlobalOptions(self: *Self) []const OptionInfo {
            return self.global_options;
        }
    };
}

/// I/O abstraction for testing
pub const IO = struct {
    stdout_writer: std.fs.File.Writer = undefined,
    stderr_writer: std.fs.File.Writer = undefined,
    stdin_reader: std.fs.File.Reader = undefined,

    /// Initialize the IO struct with default (uninitialized) values.
    /// IMPORTANT: You must call finalize() after the struct is in its final location
    /// to properly initialize the writers. This is necessary because File.Writer
    /// contains self-referential pointers that become invalid when the struct is copied.
    pub fn init() @This() {
        return .{};
    }

    /// Finalize the IO struct by creating writers in-place.
    /// This MUST be called after the IO struct is in its final memory location
    /// (i.e., after it's been assigned to Context.io).
    ///
    /// This prevents the issue where copying the struct invalidates the
    /// self-referential pointers in File.Writer.interface.
    pub fn finalize(self: *@This()) void {
        self.stdout_writer = std.fs.File.stdout().writer(&.{});
        self.stderr_writer = std.fs.File.stderr().writer(&.{});
        self.stdin_reader = std.fs.File.stdin().reader(&.{});
    }

    pub fn stdout(self: *@This()) *std.Io.Writer {
        return &self.stdout_writer.interface;
    }

    pub fn stderr(self: *@This()) *std.Io.Writer {
        return &self.stderr_writer.interface;
    }

    pub fn stdin(self: *@This()) *std.Io.Reader {
        return &self.stdin_reader.interface;
    }

    pub fn stdinReader(self: *@This()) *std.fs.File.Reader {
        return &self.stdin_reader;
    }
};

/// Environment abstraction for testing
pub const Environment = struct {
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) @This() {
        // For now, create an empty environment
        // In the future, we could populate this from std.process.getEnvMap()
        return .{
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.map.deinit();
    }

    pub fn get(self: *@This(), key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn put(self: *@This(), key: []const u8, value: []const u8) !void {
        try self.map.put(key, value);
    }
};

// Re-export registry types for user convenience
pub const Registry = registry.Registry;
pub const Config = registry.Config;

// ============================================================================
// CONTEXT VALIDATION
// ============================================================================

// ============================================================================
// PUBLIC API - Core functionality for end users
// ============================================================================

/// Parse command line with mixed arguments and options in a single pass.
///
/// This unified parser handles both positional arguments and options together,
/// supporting mixed syntax like `cmd arg1 --option value arg2 --flag`.
///
/// **Memory Management**: ⚠️ CRITICAL - Call `result.deinit()` to cleanup!
/// ```zig
/// const result = try parseCommandLine(Args, Options, null, allocator, args);
/// defer result.deinit(); // REQUIRED!
/// // Use result.args and result.options...
/// ```
///
/// 📖 See command_parser.zig for detailed documentation and examples.
pub const parseCommandLine = command_parser.parseCommandLine;
pub const CommandParseResult = command_parser.CommandParseResult;

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
/// (Note: BaseHelpGenerator moved to plugin system)

// ============================================================================
// INTERNAL API - Used by the App struct, not intended for direct user access
// ============================================================================

// Internal help utilities (minimal fallback implementations when plugins aren't available)
fn getAvailableCommands(comptime reg: anytype, allocator: std.mem.Allocator) ![][]const []const u8 {
    const commands = reg.commands;
    const commands_count = commands.len;

    // Allocate array for hierarchical command paths
    var result = try allocator.alloc([]const []const u8, commands_count);

    // Convert each command path to an array of command parts
    for (commands, 0..) |cmd, i| {
        // Split command path by spaces to get hierarchical parts
        var parts_list = std.ArrayList([]const u8).init(allocator);
        defer parts_list.deinit();

        var parts_iter = std.mem.splitScalar(u8, cmd.path, ' ');
        while (parts_iter.next()) |part| {
            try parts_list.append(allocator, part);
        }

        // Convert to owned slice
        result[i] = try parts_list.toOwnedSlice(allocator);
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

// Error handling using standard Zig error patterns

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
/// Metadata structure for providing help text and usage information for commands.
///
/// Commands can optionally export a `meta` constant of this type to provide
/// rich help information that will be displayed when users request help.
///
/// ## Fields
/// - `description`: Brief description of what the command does (required)
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
/// const registry = zcli.generate(b, exe, zcli_module, .{
///     .commands_dir = "src/commands",
///     .app_name = "myapp",
///     .app_version = "1.0.0",
///     .app_description = "My CLI application",
/// });
/// ```
pub fn App(comptime RegistryType: type, comptime RegistryModule: anytype) type {
    const ContextType = if (@TypeOf(RegistryModule) != @TypeOf(null))
        RegistryModule.Context
    else
        Context;

    return struct {
        allocator: std.mem.Allocator,
        registry: RegistryType,
        name: []const u8,
        version: []const u8,
        description: []const u8,

        const Self = @This();

        /// Dispatch an event to all registered plugins
        fn dispatchEvent(comptime event_name: []const u8, context: anytype, event_data: anytype) !?PluginResult {
            if (@TypeOf(RegistryModule) != @TypeOf(null) and @hasDecl(RegistryModule, "plugins")) {
                const plugin_info = @typeInfo(@TypeOf(RegistryModule.plugins));
                if (plugin_info == .@"struct") {
                    inline for (plugin_info.@"struct".fields) |field| {
                        const plugin = @field(RegistryModule.plugins, field.name);
                        if (@hasDecl(@TypeOf(plugin), event_name)) {
                            const handler = @field(plugin, event_name);
                            if (try handler(context, event_data)) |result| {
                                if (result.handled) return result;
                            }
                        }
                    }
                }
            }
            return null;
        }

        /// Get metadata for a command by parsing its path and extracting from module
        fn getCommandMetadata(self: *Self, command_path: []const u8) Metadata {
            // For now, return empty metadata - we'll implement proper extraction
            _ = self;
            _ = command_path;
            return Metadata{};
        }

        pub fn init(allocator: std.mem.Allocator, reg: RegistryType, options: struct {
            name: []const u8,
            version: []const u8,
            description: []const u8,
        }) Self {
            return .{
                .allocator = allocator,
                .registry = reg,
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

            // Route to appropriate command
            if (parsed.remaining_args.len == 0) {
                // No command specified, run root command if it exists
                try self.runRootCommand();
            } else if (std.mem.eql(u8, parsed.remaining_args[0], "--help") or
                std.mem.eql(u8, parsed.remaining_args[0], "-h"))
            {
                // Global help request - route to root command with help flag
                try self.runRootCommandWithArgs(parsed.remaining_args);
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

        fn runRootCommand(self: *Self) !void {
            try self.runRootCommandWithArgs(&.{});
        }

        fn runRootCommandWithArgs(self: *Self, args: []const []const u8) !void {
            // Check if root command exists in registry
            if (@hasField(@TypeOf(self.registry.commands), "root")) {
                const root_cmd = @field(self.registry.commands, "root");
                try self.executeCommand(root_cmd, args);
            } else {
                // No root command available - route help through command pipeline anyway
                // This allows help plugins to provide help even without a root command
                if (@TypeOf(RegistryModule) != @TypeOf(null) and @hasDecl(RegistryModule, "CommandPipeline")) {
                    // Create a minimal context for help generation
                    var env = std.process.EnvMap.init(self.allocator);
                    defer env.deinit();

                    var context = try RegistryModule.initContext(self.allocator);
                    defer if (@hasDecl(@TypeOf(context), "deinit")) context.deinit();

                    // Set app info
                    if (@hasField(@TypeOf(context), "app_name")) context.app_name = self.name;
                    if (@hasField(@TypeOf(context), "app_version")) context.app_version = self.version;
                    if (@hasField(@TypeOf(context), "app_description")) context.app_description = self.description;

                    // Try to use command pipeline for help
                    RegistryModule.CommandPipeline.execute(context, args) catch {
                        // If that fails, show minimal help
                        const stderr = std.io.getStdErr().writer();
                        try stderr.print("No root command available. Use '--help' for assistance.\n", .{});
                    };
                } else {
                    // No command pipeline available
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("No root command available. Use '--help' for assistance.\n", .{});
                }
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
            try self.routeCommandComptime(self.registry.commands, command_name, remaining_args, command_name);
        }

        fn routeCommandComptime(self: *Self, commands: anytype, command_name: []const u8, args: []const []const u8, command_path: []const u8) !void {
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
                            try self.routeSubcommandComptime(cmd, args, command_name, command_path);
                        } else {
                            try self.executeCommandWithPath(cmd, args, command_path);
                        }
                    } else {
                        try self.executeCommandWithPath(cmd, args, command_path);
                    }
                    return;
                }
            }

            // Command not found
            try self.showCommandNotFound(command_name);
        }

        fn routeSubcommandComptime(self: *Self, group: anytype, args: []const []const u8, group_name: []const u8, current_path: []const u8) !void {
            if (args.len == 0) {
                // No subcommand given, try to run the index command
                if (@hasField(@TypeOf(group), "_index")) {
                    const index_cmd = @field(group, "_index");
                    try self.executeCommandWithPath(index_cmd, &.{}, current_path);
                } else {
                    // No index command, show basic error
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("No subcommand specified for '{s}'. Run '{s} {s} --help' for assistance.\n", .{ group_name, self.name, group_name });
                }
                return;
            }

            // Check if the first argument is an option (starts with -)
            // If so, route to index command with all arguments
            if (std.mem.startsWith(u8, args[0], "-")) {
                if (@hasField(@TypeOf(group), "_index")) {
                    const index_cmd = @field(group, "_index");
                    try self.executeCommandWithPath(index_cmd, args, current_path);
                    return;
                } else {
                    // No index command to handle options, show error
                    const stderr = std.io.getStdErr().writer();
                    try stderr.print("Options not supported for '{s}' (no index command). Run '{s} {s} <subcommand> --help' for subcommand help.\n", .{ group_name, self.name, group_name });
                    return;
                }
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
                            // Build nested command path
                            const nested_path = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ current_path, subcommand_name });
                            defer self.allocator.free(nested_path);
                            try self.routeSubcommandComptime(subcmd, remaining_args, subcommand_name, nested_path);
                        } else {
                            // Build command path for leaf command
                            const command_path = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ current_path, subcommand_name });
                            defer self.allocator.free(command_path);
                            try self.executeCommandWithPath(subcmd, remaining_args, command_path);
                        }
                    } else {
                        // Build command path for leaf command
                        const command_path = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ current_path, subcommand_name });
                        defer self.allocator.free(command_path);
                        try self.executeCommandWithPath(subcmd, remaining_args, command_path);
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
                    .io = IO.init(),
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

        fn executeCommandWithPath(self: *Self, command_entry: anytype, args: []const []const u8, command_path: []const u8) !void {
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
                    .io = IO.init(),
                    .environment = Environment{
                        .env = env,
                    },
                };

            // Set command path in context
            if (@hasField(@TypeOf(context), "command_path")) {
                context.command_path = command_path;
            }

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
            if (@TypeOf(RegistryModule) != @TypeOf(null) and @hasDecl(RegistryModule, "error_pipeline")) {
                // Create context for error handling
                var env = std.process.EnvMap.init(self.allocator);
                defer env.deinit();

                // Use the appropriate context type based on registry module
                var context = if (@TypeOf(RegistryModule) != @TypeOf(null))
                    try RegistryModule.initContext(self.allocator)
                else
                    ContextType{
                        .allocator = self.allocator,
                        .io = IO.init(),
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
                    context.available_commands = getAvailableCommands(self.registry, self.allocator) catch &[_][]const []const u8{};
                }

                if (@hasField(@TypeOf(context), "app_name")) {
                    context.app_name = self.name;
                }

                // Use the error pipeline
                try RegistryModule.ErrorPipeline.handle(error.CommandNotFound, context);

                // Clean up available_commands after error pipeline completes
                if (@hasField(@TypeOf(context), "available_commands") and context.available_commands.len > 0) {
                    for (context.available_commands) |cmd_parts| {
                        self.allocator.free(cmd_parts);
                    }
                    self.allocator.free(context.available_commands);
                }
            } else {
                // Fallback to direct error handling for backwards compatibility
                const stderr = std.io.getStdErr().writer();

                // Try to get available commands for suggestions
                const hierarchical_commands = getAvailableCommands(self.registry, self.allocator) catch {
                    try stderr.print("Error: Unknown command '{s}'\n\n", .{command});
                    try stderr.print("Run '{s} --help' to see available commands.\n", .{self.name});
                    return;
                };
                defer {
                    for (hierarchical_commands) |cmd_parts| {
                        self.allocator.free(cmd_parts);
                    }
                    self.allocator.free(hierarchical_commands);
                }

                // Convert hierarchical commands to flat strings for error handler
                var available_commands = try self.allocator.alloc([]const u8, hierarchical_commands.len);
                defer self.allocator.free(available_commands);

                for (hierarchical_commands, 0..) |cmd_parts, i| {
                    // Join command parts with spaces
                    const joined_cmd = try std.mem.join(self.allocator, " ", cmd_parts);
                    available_commands[i] = joined_cmd;
                }
                defer {
                    for (available_commands) |cmd| {
                        self.allocator.free(cmd);
                    }
                }

                // Use the error handler module for suggestions
                try error_handler.handleCommandNotFound(stderr, command, available_commands, self.name, self.allocator);
            }
        }

        fn showSubcommandNotFound(self: *Self, group: []const u8, subcommand: []const u8) !void {
            const stderr = std.io.getStdErr().writer();

            // Display the error and available subcommands
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
                                // Fallback to simple error display
                                try stderr.print("Error: Unknown subcommand '{s}' for '{s}'\n\n", .{ subcommand, group_name });
                                try stderr.print("Run '{s} {s} --help' to see available subcommands.\n", .{ self.name, group_name });
                                return;
                            };
                            defer self.allocator.free(available_subcommands);

                            // Display main error message
                            try stderr.print("Error: Unknown subcommand '{s}' for '{s}'\n\n", .{ subcommand, group_name });

                            // Try to get suggestions
                            const suggestions = error_handler.findSimilarCommands(subcommand, available_subcommands, self.allocator) catch null;
                            if (suggestions) |sug| {
                                defer self.allocator.free(sug);
                                // Show suggestions
                                try stderr.print("Did you mean:\n", .{});
                                for (sug[0..@min(3, sug.len)]) |suggestion| {
                                    try stderr.print("    {s}\n", .{suggestion});
                                }
                                try stderr.print("\n", .{});
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
            try stderr.print("Error: Unknown subcommand '{s}' for '{s}'\n\n", .{ subcommand, group_name });
            try stderr.print("Run '{s} {s} --help' to see available subcommands.\n", .{ self.name, group_name });
        }
    };
}

// ============================================================================
// Metadata Validation - Compile-time validation for command metadata
// ============================================================================

/// Validate command metadata at compile time to catch typos and invalid fields.
/// This function checks:
/// - Top-level meta fields (description, examples, args, options, hidden)
/// - Options metadata fields (description, short, name)
/// - That option/arg meta field names match actual struct fields
///
/// Call this in the registry when processing commands to get compile-time errors
/// for invalid metadata.
pub fn validateMeta(
    comptime meta: anytype,
    comptime ArgsType: type,
    comptime OptionsType: type,
) void {
    @setEvalBranchQuota(10000);

    const MetaType = @TypeOf(meta);
    const meta_info = @typeInfo(MetaType);

    if (meta_info != .@"struct") {
        @compileError("meta must be a struct");
    }

    // Valid top-level meta fields
    const valid_top_level = .{ "description", "examples", "args", "options", "hidden", "aliases" };

    // Validate top-level fields
    inline for (meta_info.@"struct".fields) |field| {
        const is_valid = comptime blk: {
            for (valid_top_level) |valid| {
                if (std.mem.eql(u8, field.name, valid)) {
                    break :blk true;
                }
            }
            break :blk false;
        };
        if (!is_valid) {
            @compileError("Unknown meta field: '" ++ field.name ++ "'. Valid fields are: description, examples, args, options, hidden, aliases");
        }
    }

    // Validate 'options' metadata if present
    if (@hasField(MetaType, "options")) {
        const options_meta = meta.options;
        const options_meta_info = @typeInfo(@TypeOf(options_meta));

        if (options_meta_info != .@"struct") {
            @compileError("meta.options must be a struct");
        }

        const options_fields = @typeInfo(OptionsType).@"struct".fields;

        // Check each field in options metadata
        inline for (options_meta_info.@"struct".fields) |field| {
            // Verify this field exists in Options struct
            var field_exists = false;
            inline for (options_fields) |opt_field| {
                if (std.mem.eql(u8, field.name, opt_field.name)) {
                    field_exists = true;
                    break;
                }
            }

            if (!field_exists) {
                @compileError("Option metadata field '" ++ field.name ++ "' does not exist in Options struct");
            }

            // Validate the metadata for this option
            const option_meta = @field(options_meta, field.name);
            const option_meta_info = @typeInfo(@TypeOf(option_meta));

            if (option_meta_info == .@"struct") {
                const valid_option_fields = .{ "description", "short", "name", "env" };

                inline for (option_meta_info.@"struct".fields) |opt_field| {
                    const opt_is_valid = comptime blk: {
                        for (valid_option_fields) |valid| {
                            if (std.mem.eql(u8, opt_field.name, valid)) {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    };
                    if (!opt_is_valid) {
                        @compileError("Unknown option metadata field: '" ++ opt_field.name ++ "' in option '" ++ field.name ++ "'. Valid fields are: description, short, name, env");
                    }
                }
            }
        }
    }

    // Validate 'args' metadata if present
    if (@hasField(MetaType, "args")) {
        const args_meta = meta.args;
        const args_meta_info = @typeInfo(@TypeOf(args_meta));

        if (args_meta_info != .@"struct") {
            @compileError("meta.args must be a struct");
        }

        const args_fields = @typeInfo(ArgsType).@"struct".fields;

        // Check each field in args metadata
        inline for (args_meta_info.@"struct".fields) |field| {
            // Verify this field exists in Args struct
            var field_exists = false;
            inline for (args_fields) |arg_field| {
                if (std.mem.eql(u8, field.name, arg_field.name)) {
                    field_exists = true;
                    break;
                }
            }

            if (!field_exists) {
                @compileError("Args metadata field '" ++ field.name ++ "' does not exist in Args struct");
            }

            // Args metadata should be simple strings (descriptions)
            const arg_meta = @field(args_meta, field.name);
            const arg_meta_type = @TypeOf(arg_meta);
            const arg_meta_info = @typeInfo(arg_meta_type);

            // Allow string literals (*const [N:0]u8) or string slices ([]const u8)
            const is_valid_type = blk: {
                if (arg_meta_info == .pointer) {
                    const ptr_info = arg_meta_info.pointer;
                    // Check for slice of u8: []const u8
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        break :blk true;
                    }
                    // Check for pointer to array of u8: *const [N:0]u8 or *const [N]u8
                    if (ptr_info.size == .one) {
                        const child_info = @typeInfo(ptr_info.child);
                        if (child_info == .array and child_info.array.child == u8) {
                            break :blk true;
                        }
                    }
                }
                break :blk false;
            };

            if (!is_valid_type) {
                @compileError("Args metadata for field '" ++ field.name ++ "' must be a string description");
            }
        }
    }
}

// Tests
test "App initialization" {
    const allocator = testing.allocator;

    const TestRegistry = struct {
        commands: struct {} = .{},
    };

    const app = App(TestRegistry, null).init(allocator, TestRegistry{ .commands = .{} }, .{
        .name = "testapp",
        .version = "0.1.0",
        .description = "Test application",
    });

    try testing.expectEqualStrings("testapp", app.name);
    try testing.expectEqualStrings("0.1.0", app.version);
    try testing.expectEqualStrings("Test application", app.description);
}

test "parseGlobalOptions help flag" {
    const TestRegistry = struct {
        commands: struct {} = .{},
    };

    const allocator = testing.allocator;
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
        try testing.expectEqual(false, result.version);
        try testing.expectEqual(@as(usize, 1), result.remaining_args.len);
        try testing.expectEqualStrings("--help", result.remaining_args[0]);
    }

    // Test -h
    {
        const args = [_][]const u8{"-h"};
        const result = try app.parseGlobalOptions(&args);
        try testing.expectEqual(@as(usize, 1), result.remaining_args.len);
        try testing.expectEqualStrings("-h", result.remaining_args[0]);
    }
}

test "parseGlobalOptions version flag" {
    const TestRegistry = struct {
        commands: struct {} = .{},
    };

    const allocator = testing.allocator;
    var app = App(TestRegistry, null).init(allocator, TestRegistry{ .commands = .{} }, .{
        .name = "testapp",
        .version = "1.0.0",
        .description = "Test",
    });

    // Test --version
    {
        const args = [_][]const u8{"--version"};
        const result = try app.parseGlobalOptions(&args);
        try testing.expectEqual(true, result.version);
    }

    // Test -V (capital V for version)
    {
        const args = [_][]const u8{"-V"};
        const result = try app.parseGlobalOptions(&args);
        try testing.expectEqual(true, result.version);
    }
}

test "parseGlobalOptions with commands" {
    const TestRegistry = struct {
        commands: struct {} = .{},
    };

    const allocator = testing.allocator;
    var app = App(TestRegistry, null).init(allocator, TestRegistry{ .commands = .{} }, .{
        .name = "testapp",
        .version = "1.0.0",
        .description = "Test",
    });

    const args = [_][]const u8{ "build", "--verbose", "src/" };
    const result = try app.parseGlobalOptions(&args);

    try testing.expectEqual(false, result.version);
    try testing.expectEqual(@as(usize, 3), result.remaining_args.len);
    try testing.expectEqualStrings("build", result.remaining_args[0]);
}

test "Context creation" {
    const allocator = testing.allocator;

    // Just verify the Context struct can be created
    var io = IO.init();
    io.finalize();

    var context = Context.init(allocator, &io);
    defer context.deinit();

    // Test that convenience methods work
    _ = context.stdout();
    _ = context.stderr();
    _ = context.stdin();
}

test "TestContext with plugins" {
    const allocator = testing.allocator;

    const MockPlugin = struct {
        pub const plugin_id = "mock";
        pub const ContextData = struct {
            value: bool = false,
            count: u32 = 0,
        };
    };

    const Ctx = TestContext(&.{MockPlugin});
    var io = IO.init();
    io.finalize();

    var ctx = Ctx.init(allocator, &io);
    defer ctx.deinit();

    // Verify plugin data is accessible and mutable
    try testing.expectEqual(false, ctx.plugins.mock.value);
    try testing.expectEqual(@as(u32, 0), ctx.plugins.mock.count);

    ctx.plugins.mock.value = true;
    ctx.plugins.mock.count = 42;

    try testing.expectEqual(true, ctx.plugins.mock.value);
    try testing.expectEqual(@as(u32, 42), ctx.plugins.mock.count);
}

test "TestContext without plugins" {
    const allocator = testing.allocator;

    const Ctx = TestContext(&.{});
    var io = IO.init();
    io.finalize();

    var ctx = Ctx.init(allocator, &io);
    defer ctx.deinit();

    _ = ctx.stdout();
    _ = ctx.stderr();
}

// Include tests from all imported modules
test {
    testing.refAllDecls(@This());
}

// Test that global options can be registered and work with different types
test "global options with different types" {
    const GlobalTypesPlugin = struct {
        pub const global_options = [_]GlobalOption{
            option("verbose", bool, .{ .short = 'v', .default = false, .description = "Enable verbose output" }),
            option("count", u32, .{ .short = 'c', .default = 1, .description = "Count value" }),
            option("output", []const u8, .{ .short = 'o', .default = "stdout", .description = "Output destination" }),
        };

        pub fn handleGlobalOption(
            _: anytype,
            _: []const u8,
            _: anytype,
        ) !void {}
    };

    const TestCommand = struct {
        pub const Args = NoArgs;
        pub const Options = NoOptions;

        pub fn execute(args: Args, options: Options, context: anytype) !void {
            _ = args;
            _ = options;
            _ = context;
            // Command execution
        }
    };

    const TestRegistry = registry.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(GlobalTypesPlugin)
        .register("global-test", TestCommand)
        .build();

    var app = TestRegistry.init();

    // Test parsing and handling of different option types
    const args = [_][]const u8{ "--verbose", "--count", "42", "--output", "file.txt", "global-test" };
    try app.execute(testing.allocator, &args);

    // Note: Since execute() creates its own context, we can't easily verify the option values.
    // The test passes if it completes without hanging, confirming static state conflicts are resolved.
}

// Test short option flags
test "global options short flags" {
    const GlobalShortPlugin = struct {
        pub const global_options = [_]GlobalOption{
            option("verbose", bool, .{ .short = 'v', .default = false, .description = "Verbose output" }),
            option("quiet", bool, .{ .short = 'q', .default = false, .description = "Quiet output" }),
        };

        pub fn handleGlobalOption(
            _: anytype,
            _: []const u8,
            _: anytype,
        ) !void {}
    };

    const TestCommand = struct {
        pub const Args = NoArgs;
        pub const Options = NoOptions;

        pub fn execute(args: Args, options: Options, context: anytype) !void {
            _ = args;
            _ = options;
            _ = context;
        }
    };

    const TestRegistry = registry.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(GlobalShortPlugin)
        .register("global-test", TestCommand)
        .build();

    var app = TestRegistry.init();

    // Test short flags
    const args = [_][]const u8{ "-v", "-q", "global-test" };
    try app.execute(testing.allocator, &args);

    // Note: Since execute() creates its own context, we can't verify the option values.
    // The test passes if it completes without hanging.
}

// Test that global options from plugins are available to all commands
test "commands inherit global options" {
    _ = testing.allocator;

    const GlobalInheritPlugin = struct {
        pub const global_options = [_]GlobalOption{
            option("config", []const u8, .{ .short = 'c', .default = "~/.config", .description = "Config file path" }),
            option("debug", bool, .{ .short = 'd', .default = false, .description = "Enable debug mode" }),
        };

        pub fn handleGlobalOption(
            _: anytype,
            _: []const u8,
            _: anytype,
        ) !void {}
    };

    const TestCommand = struct {
        pub const Args = NoArgs;
        pub const Options = struct {
            local: bool = false,
        };

        pub fn execute(args: Args, options: Options, context: anytype) !void {
            _ = args;
            _ = options;
            _ = context;
            // Command execution - global options would be available via context
        }
    };

    const TestRegistry = registry.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(GlobalInheritPlugin)
        .register("global-test", TestCommand)
        .build();

    var app = TestRegistry.init();

    // Test that command sees global options
    const args = [_][]const u8{ "--config", "/custom/path", "--debug", "global-test", "--local" };
    try app.execute(testing.allocator, &args);

    // Note: Since execute() creates its own context, we can't verify the global option values.
    // The test passes if it completes without hanging.
}

// Test global option validation and defaults
test "global option defaults" {
    _ = testing.allocator;

    const GlobalDefaultsPlugin = struct {
        pub const global_options = [_]GlobalOption{
            option("port", u16, .{ .short = 'p', .default = 8080, .description = "Port number" }),
            option("host", []const u8, .{ .default = "localhost", .description = "Host address" }),
        };

        pub fn handleGlobalOption(
            context: anytype,
            option_name: []const u8,
            value: anytype,
        ) !void {
            _ = context;
            _ = option_name;
            _ = value;
            // In a real implementation, we'd store these values in context
        }
    };

    const TestCommand = struct {
        pub const Args = NoArgs;
        pub const Options = NoOptions;

        pub fn execute(args: Args, options: Options, context: anytype) !void {
            _ = args;
            _ = options;
            _ = context;
            // Command would use the default values if not overridden
        }
    };

    const TestRegistry = registry.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(GlobalDefaultsPlugin)
        .register("global-test", TestCommand)
        .build();

    var app = TestRegistry.init();

    // Execute without providing the options (should use defaults)
    const args = [_][]const u8{"global-test"};
    try app.execute(testing.allocator, &args);

    // Note: Test passes if it completes without hanging (defaults would be handled internally).
}

// Test multiple plugins with global options
test "multiple plugins with global options" {
    _ = testing.allocator;

    const GlobalMultiPlugin1 = struct {
        pub const global_options = [_]GlobalOption{
            option("plugin1-opt", bool, .{ .default = false, .description = "Plugin 1 option" }),
        };

        pub fn handleGlobalOption(
            _: anytype,
            _: []const u8,
            _: anytype,
        ) !void {}
    };

    const GlobalMultiPlugin2 = struct {
        pub const global_options = [_]GlobalOption{
            option("plugin2-opt", bool, .{ .default = false, .description = "Plugin 2 option" }),
        };

        pub fn handleGlobalOption(
            _: anytype,
            _: []const u8,
            _: anytype,
        ) !void {}
    };

    const TestCommand = struct {
        pub const Args = NoArgs;
        pub const Options = NoOptions;

        pub fn execute(args: Args, options: Options, context: anytype) !void {
            _ = args;
            _ = options;
            _ = context;
        }
    };

    const TestRegistry = registry.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(GlobalMultiPlugin1)
        .registerPlugin(GlobalMultiPlugin2)
        .register("global-test", TestCommand)
        .build();

    var app = TestRegistry.init();

    // Test that both plugins' options work
    const args = [_][]const u8{ "--plugin1-opt", "--plugin2-opt", "global-test" };
    try app.execute(testing.allocator, &args);

    // Note: Since execute() creates its own context, we can't verify the called states.
    // The test passes if it completes without hanging.
}

// Test that plugin global options are removed from args before command execution
test "global options consumed before command" {
    _ = testing.allocator;

    const GlobalConsumePlugin = struct {
        pub const global_options = [_]GlobalOption{
            option("global", bool, .{ .short = 'g', .default = false, .description = "Global option" }),
        };

        pub fn handleGlobalOption(
            context: anytype,
            option_name: []const u8,
            value: anytype,
        ) !void {
            _ = context;
            _ = option_name;
            _ = value;
        }
    };

    const TestCommand = struct {
        pub const Args = struct {
            arg1: []const u8,
        };
        pub const Options = struct {
            local: bool = false,
        };

        pub fn execute(args: Args, options: Options, context: anytype) !void {
            _ = context;
            _ = args.arg1;
            _ = options.local;
            // Would process the arguments and options as needed
        }
    };

    const TestRegistry = registry.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(GlobalConsumePlugin)
        .register("global-test", TestCommand)
        .build();

    var app = TestRegistry.init();

    // Global options should be consumed and not passed to command
    const args = [_][]const u8{ "--global", "global-test", "myarg", "--local" };
    try app.execute(testing.allocator, &args);

    // Note: Since execute() creates its own context, we can't verify the argument processing.
    // The test passes if it completes without hanging, confirming global options are handled.
}
