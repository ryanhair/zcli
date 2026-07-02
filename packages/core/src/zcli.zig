const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const command_parser = @import("command_parser.zig");
const error_handler = @import("errors.zig");
pub const plugin_types = @import("plugin_types.zig");
pub const registry = @import("registry.zig");
const diagnostic_errors = @import("diagnostic_errors.zig");
const type_utils = @import("type_utils.zig");
const option_utils = @import("options/utils.zig");
pub const ztheme = @import("ztheme");
pub const markdown_fmt = @import("markdown_fmt");
pub const zprogress = @import("zprogress");
pub const zinput = @import("zinput");
pub const serde = @import("serde");

/// HTTP client with safe defaults (TLS verification on, bounded response body)
/// over `std.http.Client`. See http.zig.
pub const http = @import("http.zig");

/// Filesystem command discovery — the same scan the build system runs to
/// generate the registry. Exposed so tools can determine a project's command
/// tree without building it (e.g. the `zcli tree` command).
pub const command_discovery = @import("build_utils/command_discovery.zig");

const testing = std.testing;

// Re-export error types
pub const ZcliError = diagnostic_errors.ZcliError;
pub const ZcliDiagnostic = diagnostic_errors.ZcliDiagnostic;

// Re-export plugin types for user convenience

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

        // No-op — environ is owned by process.Init
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

    pub fn exit(self: *Self, code: u8) noreturn {
        // std.process.exit does not flush buffered writers — without this,
        // anything printed just before exit() is silently dropped.
        self.io.flush();
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
/// var io = zcli.IO.init(std.testing.io);
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

        var field_names: [field_count][]const u8 = undefined;
        var field_types: [field_count]type = undefined;
        var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;
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

                field_names[idx] = name_buf[0..name_len];
                field_types[idx] = DataType;
                field_attrs[idx] = .{ .default_value_ptr = @ptrCast(&default_val) };
                idx += 1;
            }
        }

        break :blk @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    };

    return struct {
        allocator: std.mem.Allocator,
        io: *IO,
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
            // No-op — environ is owned by process.Init
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

/// I/O abstraction for the framework
pub const IO = struct {
    io: std.Io,
    stdout_writer: std.Io.File.Writer = undefined,
    stderr_writer: std.Io.File.Writer = undefined,
    stdin_reader: std.Io.File.Reader = undefined,
    stdout_buf: [4096]u8 = undefined,
    stderr_buf: [4096]u8 = undefined,
    stdin_buf: [4096]u8 = undefined,

    // Optional overrides for testing
    stdout_override: ?*std.Io.Writer = null,
    stderr_override: ?*std.Io.Writer = null,

    pub fn init(io: std.Io) @This() {
        return .{ .io = io };
    }

    /// Finalize the IO struct by creating writers/readers in-place.
    /// Must be called after the struct is in its final memory location.
    pub fn finalize(self: *@This()) void {
        self.stdout_writer = std.Io.File.stdout().writer(self.io, &self.stdout_buf);
        self.stderr_writer = std.Io.File.stderr().writer(self.io, &self.stderr_buf);
        self.stdin_reader = std.Io.File.stdin().reader(self.io, &self.stdin_buf);
    }

    pub fn stdout(self: *@This()) *std.Io.Writer {
        return self.stdout_override orelse &self.stdout_writer.interface;
    }

    pub fn stderr(self: *@This()) *std.Io.Writer {
        return self.stderr_override orelse &self.stderr_writer.interface;
    }

    pub fn stdin(self: *@This()) *std.Io.Reader {
        return &self.stdin_reader.interface;
    }

    pub fn stdinReader(self: *@This()) *std.Io.File.Reader {
        return &self.stdin_reader;
    }

    /// Flush stdout and stderr writers. Must be called before exit
    /// to ensure buffered output reaches the terminal.
    pub fn flush(self: *@This()) void {
        self.stdout().flush() catch {};
        self.stderr().flush() catch {};
    }
};

/// Environ.Map re-export for convenience.
pub const EnvironMap = std.process.Environ.Map;

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
// Command Validation - Compile-time validation of the command contract
// ============================================================================

/// The prefix every command contract error carries. `path` is the command's
/// registered path (e.g. "add command"), which maps directly to the file under
/// src/commands/ — so the author, or an AI agent, can jump straight to it.
fn commandContext(comptime path: []const u8) []const u8 {
    return "command '" ++ path ++ "': ";
}

/// Validate a command module's contract at compile time, with every error
/// naming the command by its path in plain language. This is the "verify" signal
/// of the authoring loop: a malformed command fails the build with a message an
/// author (or an AI agent) can act on, not a template error buried deep in the
/// framework.
///
/// Checks that `Args`/`Options` are structs and the `meta` block is well-formed
/// (delegated to `validateMeta`). The `execute` signature is intentionally *not*
/// asserted here: a command's `execute` typically takes `context: *Context`,
/// and `Context` is a projection of the very registry being built — reaching for
/// `@TypeOf(execute)` at registration time forms a comptime dependency loop.
/// A wrong `execute` shape still fails the build at the framework's own call
/// site, pointing at the author's file.
pub fn validateCommand(comptime path: []const u8, comptime Module: type) void {
    @setEvalBranchQuota(10000);
    const loc = commandContext(path);

    const ArgsType = if (@hasDecl(Module, "Args")) Module.Args else struct {};
    const OptionsType = if (@hasDecl(Module, "Options")) Module.Options else struct {};

    if (@hasDecl(Module, "Args") and @typeInfo(ArgsType) != .@"struct") {
        @compileError(loc ++ "`Args` must be a struct, found `" ++ @typeName(ArgsType) ++
            "`. Example: `pub const Args = struct { name: []const u8 };`");
    }
    if (@hasDecl(Module, "Options") and @typeInfo(OptionsType) != .@"struct") {
        @compileError(loc ++ "`Options` must be a struct, found `" ++ @typeName(OptionsType) ++
            "`. Example: `pub const Options = struct { verbose: bool = false };`");
    }

    // Every Options field must have a well-defined value when its flag is
    // absent: bool (false), optional (null), accumulating array (empty), or
    // an explicit default. Anything else would be read as undefined memory
    // when the flag isn't passed — required values belong in Args.
    if (@typeInfo(OptionsType) == .@"struct") {
        inline for (@typeInfo(OptionsType).@"struct".fields) |field| {
            const has_absent_value = field.type == bool or
                @typeInfo(field.type) == .optional or
                option_utils.isArrayType(field.type) or
                field.default_value_ptr != null;
            if (!has_absent_value) {
                @compileError(loc ++ "option '" ++ field.name ++ "' has type `" ++ @typeName(field.type) ++
                    "` and no default value, so it would be undefined when the flag is not passed. " ++
                    "Give it a default (`" ++ field.name ++ ": " ++ @typeName(field.type) ++ " = ...`), " ++
                    "make it optional (`?" ++ @typeName(field.type) ++ "`), " ++
                    "or make it a required positional in `Args`.");
            }
        }
    }

    if (@hasDecl(Module, "meta")) {
        validateMeta(path, Module.meta, ArgsType, OptionsType);
    }
}

/// Validate command metadata at compile time to catch typos and invalid fields.
/// This function checks:
/// - Top-level meta fields (description, examples, args, options, hidden)
/// - Options metadata fields (description, short, name)
/// - That option/arg meta field names match actual struct fields
///
/// `path` names the owning command so every error points back at its file.
/// Prefer `validateCommand`, which calls this as part of the full contract.
pub fn validateMeta(
    comptime path: []const u8,
    comptime meta: anytype,
    comptime ArgsType: type,
    comptime OptionsType: type,
) void {
    @setEvalBranchQuota(10000);
    const loc = commandContext(path);

    const MetaType = @TypeOf(meta);
    const meta_info = @typeInfo(MetaType);

    if (meta_info != .@"struct") {
        @compileError(loc ++ "`meta` must be a struct");
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
            @compileError(loc ++ "unknown meta field '" ++ field.name ++ "'. Valid fields are: description, examples, args, options, hidden, aliases");
        }
    }

    // Validate 'options' metadata if present
    if (@hasField(MetaType, "options")) {
        const options_meta = meta.options;
        const options_meta_info = @typeInfo(@TypeOf(options_meta));

        if (options_meta_info != .@"struct") {
            @compileError(loc ++ "`meta.options` must be a struct");
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
                @compileError(loc ++ "meta.options describes '" ++ field.name ++ "', which is not a field in the Options struct");
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
                        @compileError(loc ++ "unknown option metadata field '" ++ opt_field.name ++ "' in option '" ++ field.name ++ "'. Valid fields are: description, short, name, env");
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
            @compileError(loc ++ "`meta.args` must be a struct");
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
                @compileError(loc ++ "meta.args describes '" ++ field.name ++ "', which is not a field in the Args struct");
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
                @compileError(loc ++ "meta.args for '" ++ field.name ++ "' must be a string description");
            }
        }
    }
}

test "validateCommand accepts a well-formed command" {
    // A full, valid command: reaching the assertion means it compiled without
    // tripping a contract error.
    const Cmd = struct {
        pub const meta = .{
            .description = "Greet someone",
            .aliases = &.{"hi"},
            .options = .{ .loud = .{ .short = 'l', .description = "Shout it" } },
        };
        pub const Args = struct { name: []const u8 };
        pub const Options = struct { loud: bool = false };
        pub fn execute(_: Args, _: Options, _: anytype) !void {}
    };
    comptime validateCommand("greet", Cmd);

    // A metadata-only command group (no execute) is valid too.
    const Group = struct {
        pub const meta = .{ .description = "A group" };
    };
    comptime validateCommand("group", Group);

    try testing.expect(true);
}

// The negative cases below are compile errors by design, so they cannot be run
// as tests. Each is verified by hand; uncomment one to see the message it emits.
//
//   command 'broken': unknown meta field 'desciption'. Valid fields are: ...
//     pub const meta = .{ .desciption = "typo" };
//
//   command 'broken': `Args` must be a struct, found `u32`. ...
//     pub const Args = u32;
//
//   command 'broken': meta.options describes 'nope', which is not a field in the Options struct
//     pub const meta = .{ .options = .{ .nope = .{ .short = 'x' } } };
//     pub const Options = struct { real: bool = false };

test "Context creation" {
    const allocator = testing.allocator;

    // Just verify the Context struct can be created
    var io = IO.init(std.testing.io);
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
    var io = IO.init(std.testing.io);
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
    var io = IO.init(std.testing.io);
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
    try app.execute(testing.allocator, std.testing.io, &(std.process.Environ.Map.init(testing.allocator)), &args);

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
    try app.execute(testing.allocator, std.testing.io, &(std.process.Environ.Map.init(testing.allocator)), &args);

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
    try app.execute(testing.allocator, std.testing.io, &(std.process.Environ.Map.init(testing.allocator)), &args);

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
    try app.execute(testing.allocator, std.testing.io, &(std.process.Environ.Map.init(testing.allocator)), &args);

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
    try app.execute(testing.allocator, std.testing.io, &(std.process.Environ.Map.init(testing.allocator)), &args);

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
    try app.execute(testing.allocator, std.testing.io, &(std.process.Environ.Map.init(testing.allocator)), &args);

    // Note: Since execute() creates its own context, we can't verify the argument processing.
    // The test passes if it completes without hanging, confirming global options are handled.
}
