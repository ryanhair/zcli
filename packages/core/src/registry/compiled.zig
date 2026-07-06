const std = @import("std");
const command_parser = @import("../command_parser.zig");
const option_utils = @import("../options/utils.zig");
const plugin_types = @import("../plugin_types.zig");
const zcli = @import("../zcli.zig");

const console_utf8 = @import("../console_utf8.zig");
const paths = @import("paths.zig");
const builder = @import("builder.zig");
const comptimeJoinPath = paths.comptimeJoinPath;
const sortedByPathLengthDesc = paths.sortedByPathLengthDesc;
const Config = builder.Config;
const CommandEntry = builder.CommandEntry;
const discoverPluginCommands = builder.discoverPluginCommands;

/// Default rendering for a parse error no plugin handled: the diagnostic's
/// precise, human-readable message on stderr (flushed — the process is about
/// to exit with an error). Falls back silently when no diagnostic was filled
/// (the error name still reaches the caller).
fn reportParseError(context: anytype, diag: ?zcli.ZcliDiagnostic) !void {
    const d = diag orelse return;
    const message = zcli.formatDiagnostic(d, context.allocator) catch return;
    var stderr = context.stderr();
    try stderr.print("Error: {s}\n", .{message});
    try stderr.flush();
}

/// Convert a global option's argv string to its declared type. Covers the
/// full set plugin_types.option() accepts (validated at declaration, so the
/// compile-error backstop here is unreachable for declared options).
fn convertGlobalValue(comptime T: type, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .bool => std.mem.eql(u8, value, "true"),
        .int => try std.fmt.parseInt(T, value, 10),
        .float => try std.fmt.parseFloat(T, value),
        .optional => |opt| try convertGlobalValue(opt.child, value),
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8)
            value
        else
            @compileError("Unsupported global option type: " ++ @typeName(T)),
        else => @compileError("Unsupported global option type: " ++ @typeName(T)),
    };
}

/// Errors that execute() reports to the user before returning them — the
/// user-facing message has already been printed by the time these surface.
fn isReportedCliError(err: anyerror) bool {
    return switch (err) {
        error.CommandNotFound,
        error.SubcommandNotFound,
        error.OptionUnknown,
        error.OptionMissingValue,
        error.OptionInvalidValue,
        error.OptionBooleanWithValue,
        error.OptionDuplicate,
        error.ArgumentMissingRequired,
        error.ArgumentInvalidValue,
        error.ArgumentTooMany,
        error.ResourceLimitExceeded,
        // A command that failed via context.fail() already printed its own
        // user-facing message; exit non-zero without the name/trace.
        error.CommandFailed,
        => true,
        else => false,
    };
}

test "isReportedCliError: context.fail's error exits cleanly, unexpected errors don't" {
    try std.testing.expect(isReportedCliError(error.CommandFailed));
    try std.testing.expect(isReportedCliError(error.ArgumentMissingRequired));
    // An unexpected failure keeps its name + trace (propagated, not swallowed).
    try std.testing.expect(!isReportedCliError(error.OutOfMemory));
}

/// Compiled registry with all command and plugin information
pub fn CompiledRegistry(comptime config: Config, comptime cmd_entries: []const CommandEntry, comptime new_plugins: []const type) type {
    // Validate plugin conflicts at compile time
    comptime {
        // Use arrays to check for conflicts since ComptimeStringMap may not be available
        var global_option_names: []const []const u8 = &.{};
        var command_paths: []const []const []const u8 = &.{};

        // Check for command path conflicts among regular commands
        for (cmd_entries) |cmd| {
            for (command_paths) |existing_path| {
                // Compare path arrays element by element
                var paths_equal = existing_path.len == cmd.path.len;
                if (paths_equal) {
                    for (existing_path, 0..) |existing_component, i| {
                        if (!std.mem.eql(u8, existing_component, cmd.path[i])) {
                            paths_equal = false;
                            break;
                        }
                    }
                }
                if (paths_equal) {
                    @compileError("Duplicate command path: " ++ comptimeJoinPath(cmd.path));
                }
            }
            command_paths = command_paths ++ .{cmd.path};
        }

        // Validate optional command groups (commands that have subcommands)
        for (cmd_entries) |cmd| {
            // Check if this command has subcommands
            var has_subcommands = false;
            for (cmd_entries) |other_cmd| {
                // Skip self
                if (other_cmd.path.len <= cmd.path.len) continue;

                // Check if other_cmd is a subcommand of cmd
                var is_subcommand = true;
                for (cmd.path, 0..) |component, i| {
                    if (!std.mem.eql(u8, component, other_cmd.path[i])) {
                        is_subcommand = false;
                        break;
                    }
                }

                if (is_subcommand) {
                    has_subcommands = true;
                    break;
                }
            }

            // If this command has subcommands, validate it's an optional command group
            if (has_subcommands) {
                if (@hasDecl(cmd.module, "Args")) {
                    const args_fields = std.meta.fields(cmd.module.Args);
                    if (args_fields.len > 0) {
                        // Build path string for error message
                        var path_str: []const u8 = "";
                        for (cmd.path, 0..) |component, idx| {
                            if (idx > 0) path_str = path_str ++ " ";
                            path_str = path_str ++ component;
                        }
                        @compileError("Optional command group '" ++ path_str ++ "' cannot have Args fields. " ++
                            "Command groups with subcommands must have an empty Args struct.");
                    }
                }
            }
        }

        // Check for conflicts between plugin commands and regular commands
        var plugin_command_paths: []const []const []const u8 = &.{};
        for (new_plugins) |Plugin| {
            if (@hasDecl(Plugin, "commands")) {
                // Recursively discover all plugin commands (including nested)
                const plugin_cmd_entries = discoverPluginCommands(Plugin.commands, &.{});

                for (plugin_cmd_entries) |plugin_cmd| {
                    // Check against regular commands
                    for (command_paths) |existing_path| {
                        var paths_equal = existing_path.len == plugin_cmd.path.len;
                        if (paths_equal) {
                            for (existing_path, 0..) |existing_component, i| {
                                if (!std.mem.eql(u8, existing_component, plugin_cmd.path[i])) {
                                    paths_equal = false;
                                    break;
                                }
                            }
                        }
                        if (paths_equal) {
                            @compileError("Plugin command conflicts with existing command: " ++ comptimeJoinPath(plugin_cmd.path));
                        }
                    }
                    // Check against other plugin commands
                    for (plugin_command_paths) |existing_plugin_path| {
                        var paths_equal = existing_plugin_path.len == plugin_cmd.path.len;
                        if (paths_equal) {
                            for (existing_plugin_path, 0..) |existing_component, i| {
                                if (!std.mem.eql(u8, existing_component, plugin_cmd.path[i])) {
                                    paths_equal = false;
                                    break;
                                }
                            }
                        }
                        if (paths_equal) {
                            @compileError("Duplicate plugin command: " ++ comptimeJoinPath(plugin_cmd.path));
                        }
                    }
                    plugin_command_paths = plugin_command_paths ++ .{plugin_cmd.path};
                }
            }
        }

        // Check for global option conflicts
        for (new_plugins) |Plugin| {
            if (plugin_types.hasGlobalOptions(Plugin)) {
                for (Plugin.global_options) |opt| {
                    for (global_option_names) |existing_name| {
                        if (std.mem.eql(u8, existing_name, opt.name)) {
                            @compileError("Duplicate global option: " ++ opt.name);
                        }
                    }
                    global_option_names = global_option_names ++ .{opt.name};
                }
            }
        }
    }

    return struct {
        const Self = @This();

        // Export the computed Context type for this registry
        pub const Context = zcli.ContextFor(new_plugins);

        // Expose commands array for testing and introspection
        pub const commands = cmd_entries;

        /// Metadata for a command that can be queried by plugins
        pub const CommandMetadata = struct {
            path: []const []const u8,
            description: []const u8,
            hidden: bool,
        };

        /// Get all commands with metadata (for use by plugins)
        /// Returns a compile-time array of command metadata including hidden status
        pub fn getAllCommands() []const CommandMetadata {
            comptime {
                var result: []const CommandMetadata = &.{};

                // Add regular commands
                for (cmd_entries) |cmd| {
                    const hidden = if (@hasDecl(cmd.module, "meta") and @hasField(@TypeOf(cmd.module.meta), "hidden"))
                        cmd.module.meta.hidden
                    else
                        false;

                    const description = if (@hasDecl(cmd.module, "meta") and @hasField(@TypeOf(cmd.module.meta), "description"))
                        cmd.module.meta.description
                    else
                        "";

                    result = result ++ .{CommandMetadata{
                        .path = cmd.path,
                        .description = description,
                        .hidden = hidden,
                    }};
                }

                // Add plugin commands
                for (plugin_command_entries) |plugin_cmd| {
                    const hidden = if (@hasDecl(plugin_cmd.module, "meta") and @hasField(@TypeOf(plugin_cmd.module.meta), "hidden"))
                        plugin_cmd.module.meta.hidden
                    else
                        false;

                    const description = if (@hasDecl(plugin_cmd.module, "meta") and @hasField(@TypeOf(plugin_cmd.module.meta), "description"))
                        plugin_cmd.module.meta.description
                    else
                        "";

                    result = result ++ .{CommandMetadata{
                        .path = plugin_cmd.path,
                        .description = description,
                        .hidden = hidden,
                    }};
                }

                return result;
            }
        }

        // Collect all global options at compile time
        const global_options = blk: {
            var opts: []const plugin_types.GlobalOption = &.{};
            for (new_plugins) |Plugin| {
                if (plugin_types.hasGlobalOptions(Plugin)) {
                    opts = opts ++ Plugin.global_options;
                }
            }
            break :blk opts;
        };

        // Validate no duplicate global option names or short flags
        comptime {
            for (global_options, 0..) |opt_a, i| {
                for (global_options[i + 1 ..]) |opt_b| {
                    if (std.mem.eql(u8, opt_a.name, opt_b.name)) {
                        @compileError("Duplicate global option name: --" ++ opt_a.name ++ ". Two plugins define the same global option.");
                    }
                    if (opt_a.short != null and opt_b.short != null and opt_a.short.? == opt_b.short.?) {
                        @compileError("Duplicate global option short flag: -" ++ &[_]u8{opt_a.short.?} ++ " (used by both --" ++ opt_a.name ++ " and --" ++ opt_b.name ++ ")");
                    }
                }
            }
        }

        // Discover all plugin command entries (including nested)
        const plugin_command_entries = blk: {
            var entries: []const CommandEntry = &.{};
            for (new_plugins) |Plugin| {
                if (@hasDecl(Plugin, "commands")) {
                    entries = entries ++ discoverPluginCommands(Plugin.commands, &.{});
                }
            }
            break :blk entries;
        };

        // Sort plugins by priority at compile time
        const sorted_plugins = blk: {
            // Handle empty plugins case
            if (new_plugins.len == 0) {
                break :blk &.{};
            }

            // Handle single plugin case
            if (new_plugins.len == 1) {
                break :blk &.{new_plugins[0]};
            }

            // Create a mutable array for sorting
            var plugins_with_priority: [new_plugins.len]struct { type, i32 } = undefined;
            for (new_plugins, 0..) |Plugin, i| {
                plugins_with_priority[i] = .{ Plugin, plugin_types.getPriority(Plugin) };
            }

            // Sort by priority (higher first) using comptime bubble sort
            var changed = true;
            while (changed) {
                changed = false;
                var i: usize = 0;
                while (i < plugins_with_priority.len - 1) : (i += 1) {
                    if (plugins_with_priority[i][1] < plugins_with_priority[i + 1][1]) {
                        const temp = plugins_with_priority[i];
                        plugins_with_priority[i] = plugins_with_priority[i + 1];
                        plugins_with_priority[i + 1] = temp;
                        changed = true;
                    }
                }
            }

            var result: []const type = &.{};
            for (plugins_with_priority) |plugin_entry| {
                result = result ++ .{plugin_entry[0]};
            }
            break :blk result;
        };

        // Command metadata for documentation, completions, and help.
        // Built at comptime from all registered commands and plugins.
        pub const command_info = buildCommandInfo();
        pub const global_options_info = buildGlobalOptionsInfo();

        fn buildGlobalOptionsInfo() []const zcli.OptionInfo {
            var opts: []const zcli.OptionInfo = &.{};
            for (global_options) |global_opt| {
                opts = opts ++ .{zcli.OptionInfo{
                    .name = global_opt.name,
                    .short = global_opt.short,
                    .description = global_opt.description,
                    .takes_value = global_opt.type != bool,
                }};
            }
            return opts;
        }

        fn buildCommandInfo() []const zcli.CommandInfo {
            @setEvalBranchQuota(10000);
            return buildCommandInfoFromEntries(cmd_entries) ++ buildCommandInfoFromEntries(plugin_command_entries);
        }

        fn buildCommandInfoFromEntries(entries: anytype) []const zcli.CommandInfo {
            var cmd_info_list: []const zcli.CommandInfo = &.{};
            for (entries) |cmd| {
                // Skip root command
                if (cmd.path.len == 1 and std.mem.eql(u8, cmd.path[0], "root")) continue;

                var description: ?[]const u8 = null;
                var examples: ?[]const []const u8 = null;
                var hidden: bool = false;
                var aliases: []const []const u8 = &.{};

                if (@hasDecl(cmd.module, "meta")) {
                    const meta = cmd.module.meta;
                    if (@hasField(@TypeOf(meta), "description")) description = meta.description;
                    if (@hasField(@TypeOf(meta), "examples")) examples = meta.examples;
                    if (@hasField(@TypeOf(meta), "hidden")) hidden = meta.hidden;
                    if (@hasField(@TypeOf(meta), "aliases")) aliases = meta.aliases;
                }

                // Introspect Options
                var options: []const zcli.OptionInfo = &.{};
                if (@hasDecl(cmd.module, "Options")) {
                    const OptionsType = cmd.module.Options;
                    const options_type_info = @typeInfo(OptionsType);
                    if (options_type_info == .@"struct") {
                        for (options_type_info.@"struct".fields) |field| {
                            const base_type = if (@typeInfo(field.type) == .optional) @typeInfo(field.type).optional.child else field.type;
                            var opt_desc: ?[]const u8 = null;
                            var opt_short: ?u8 = null;
                            if (@hasDecl(cmd.module, "meta")) {
                                const meta = cmd.module.meta;
                                if (@hasField(@TypeOf(meta), "options")) {
                                    if (@hasField(@TypeOf(meta.options), field.name)) {
                                        const opt_meta = @field(meta.options, field.name);
                                        if (@hasField(@TypeOf(opt_meta), "description")) opt_desc = opt_meta.description;
                                        if (@hasField(@TypeOf(opt_meta), "short")) opt_short = opt_meta.short;
                                    }
                                }
                            }
                            options = options ++ .{zcli.OptionInfo{ .name = field.name, .short = opt_short, .description = opt_desc, .takes_value = base_type != bool }};
                        }
                    }
                }

                // Introspect Args
                var arg_infos: []const zcli.ArgInfo = &.{};
                if (@hasDecl(cmd.module, "Args")) {
                    const ArgsType = cmd.module.Args;
                    const args_type_info = @typeInfo(ArgsType);
                    if (args_type_info == .@"struct") {
                        for (args_type_info.@"struct".fields) |field| {
                            var arg_desc: ?[]const u8 = null;
                            if (@hasDecl(cmd.module, "meta")) {
                                const meta = cmd.module.meta;
                                if (@hasField(@TypeOf(meta), "args")) {
                                    if (@hasField(@TypeOf(meta.args), field.name)) {
                                        arg_desc = @field(meta.args, field.name);
                                    }
                                }
                            }
                            const is_opt = @typeInfo(field.type) == .optional or field.default_value_ptr != null;
                            const is_variadic = vblk: {
                                const ft = @typeInfo(field.type);
                                break :vblk ft == .pointer and ft.pointer.size == .slice and ft.pointer.child != u8;
                            };
                            arg_infos = arg_infos ++ .{zcli.ArgInfo{ .name = field.name, .description = arg_desc, .is_optional = is_opt, .is_variadic = is_variadic }};
                        }
                    }
                }

                cmd_info_list = cmd_info_list ++ .{zcli.CommandInfo{
                    .path = cmd.path,
                    .description = description,
                    .examples = examples,
                    .args = arg_infos,
                    .options = options,
                    .hidden = hidden,
                    .aliases = aliases,
                }};
            }
            return cmd_info_list;
        }

        pub fn init() Self {
            return Self{};
        }

        pub fn execute(self: *Self, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8) !void {
            var stdio: zcli.Stdio = undefined;
            stdio.init(io);
            return self.executeWithStdio(allocator, io, environ, args, &stdio);
        }

        /// Like `execute`, but with a caller-provided standard-stream holder.
        /// Tests use this to capture or silence framework output via
        /// `Stdio.stdout_override`/`stderr_override` — without it, pipeline-
        /// level tests spill parse errors onto the real stderr.
        pub fn executeWithStdio(self: *Self, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8, stdio: *zcli.Stdio) !void {
            // Build list of available commands at compile time
            const available_commands = comptime blk: {
                var cmd_list: []const []const []const u8 = &.{};
                // Add regular commands (paths are already arrays), but skip "root"
                for (cmd_entries) |cmd| {
                    // Skip root command from the visible commands list
                    if (cmd.path.len == 1 and std.mem.eql(u8, cmd.path[0], "root")) {
                        continue;
                    }
                    cmd_list = cmd_list ++ .{cmd.path};
                }
                // Add plugin commands (with full paths including nested)
                for (plugin_command_entries) |plugin_cmd| {
                    cmd_list = cmd_list ++ .{plugin_cmd.path};
                }
                break :blk cmd_list;
            };

            const global_options_list = global_options_info;

            const plugin_command_info_list = command_info;

            defer stdio.flush();

            // Arena-per-command allocator: everything the command and framework
            // bookkeeping allocate during this invocation lives in the arena and is
            // reclaimed wholesale when execute() returns. Command authors never need
            // to call free. See docs/adr/0001-arena-per-command-allocator.md.
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            // Use the computed Context type which includes type-safe plugin data
            var context = Context{
                .allocator = arena.allocator(),
                .io = io,
                .stdio = stdio,
                .environ = environ,
                .theme = zcli.ztheme.Theme.init(environ, io),
                .app_name = config.app_name,
                .app_version = config.app_version,
                .app_description = config.app_description,
                .available_commands = available_commands,
                .command_path = &.{},
                .plugin_command_info = plugin_command_info_list,
                .global_options = global_options_list,
            };
            defer context.deinit();

            // 1. Run preParse hooks
            var current_args = args;
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "preParse")) {
                    current_args = try Plugin.preParse(&context, current_args);
                }
            }

            // 2. Extract and handle global options. Failures here are parse
            // errors like any other: dispatch onError, default-render the
            // diagnostic when unhandled.
            const global_result = self.parseGlobalOptions(&context, current_args) catch |err| {
                if (!isReportedCliError(err)) return err;
                var error_handled = false;
                inline for (sorted_plugins) |Plugin| {
                    if (@hasDecl(Plugin, "onError")) {
                        if (try Plugin.onError(&context, err)) {
                            error_handled = true;
                            break;
                        }
                    }
                }
                if (!error_handled) {
                    try reportParseError(&context, context.diagnostic);
                    return err;
                }
                return;
            };
            defer context.allocator.free(global_result.consumed);
            defer context.allocator.free(global_result.remaining);
            current_args = global_result.remaining;

            // 3. Transform arguments
            var transform_result = zcli.TransformResult{ .args = current_args };
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "transformArgs") and transform_result.continue_processing) {
                    transform_result = try Plugin.transformArgs(&context, transform_result.args);
                }
            }

            if (!transform_result.continue_processing) {
                return; // Plugin stopped execution
            }

            current_args = transform_result.args;

            // 4. Route to command
            try self.executeCommand(&context, current_args);
        }

        /// Convenient run method that handles process args, io, and environment
        pub fn run(self: *Self, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8) !void {
            // Windows consoles default to a legacy code page, so without this a
            // typed multibyte character arrives mangled and printed UTF-8 shows
            // as mojibake. Switch to UTF-8 for the run and restore on the way
            // out; a no-op on POSIX. `std.process.exit` skips deferred restores,
            // so the reported-error path below restores explicitly.
            const console = console_utf8.enable();
            defer console.restore();
            self.execute(allocator, io, environ, if (args.len > 0) args[1..] else args) catch |err| {
                // CLI-entry semantics: some failures already showed the user a
                // message — parse/routing diagnostics, a plugin, the framework
                // fallback, or a command's own context.fail(). Exit(1) without
                // letting a raw error trace follow that friendly message.
                // Anything else is an unexpected failure; propagate it so the
                // name and trace aid debugging. Library/test callers who want
                // the error itself use execute() directly.
                if (isReportedCliError(err)) {
                    console.restore();
                    std.process.exit(1);
                }
                return err;
            };
        }

        /// Convert `value` and hand it to the plugin that declared
        /// `global_opt`. A value that doesn't parse as the declared type is
        /// reported as OptionInvalidValue with a diagnostic.
        fn dispatchGlobalOption(context: *Context, comptime global_opt: zcli.GlobalOption, value: []const u8, is_short: bool) !void {
            const typed_value = convertGlobalValue(global_opt.type, value) catch {
                context.diagnostic = .{ .OptionInvalidValue = .{
                    .option_name = global_opt.name,
                    .is_short = is_short,
                    .provided_value = value,
                    .expected_type = @typeName(global_opt.type),
                } };
                return zcli.ZcliError.OptionInvalidValue;
            };
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "handleGlobalOption") and @hasDecl(Plugin, "global_options")) {
                    inline for (Plugin.global_options) |plugin_opt| {
                        if (comptime std.mem.eql(u8, plugin_opt.name, global_opt.name)) {
                            try Plugin.handleGlobalOption(context, global_opt.name, typed_value);
                            return;
                        }
                    }
                }
            }
        }

        pub fn parseGlobalOptions(_: *Self, context: *Context, args: []const []const u8) !zcli.GlobalOptionsResult {
            var consumed = std.ArrayList(usize).empty;
            var remaining = std.ArrayList([]const u8).empty;
            defer consumed.deinit(context.allocator);
            defer remaining.deinit(context.allocator);

            var i: usize = 0;
            while (i < args.len) {
                const arg = args[i];
                var handled = false;

                if (std.mem.startsWith(u8, arg, "--")) {
                    const opt_name = arg[2..];
                    // Check if this is a global option
                    inline for (global_options) |global_opt| {
                        if (std.mem.eql(u8, opt_name, global_opt.name)) {
                            // Handle the global option
                            try consumed.append(context.allocator, i);

                            var value: []const u8 = "true"; // Boolean flags: presence == true
                            if (global_opt.type != bool) {
                                // Same next-token-is-a-value rule the command
                                // parsers share (options/utils.zig).
                                if (i + 1 < args.len and
                                    (!std.mem.startsWith(u8, args[i + 1], "-") or option_utils.isNegativeNumber(args[i + 1])))
                                {
                                    i += 1;
                                    value = args[i];
                                    try consumed.append(context.allocator, i);
                                } else {
                                    context.diagnostic = .{ .OptionMissingValue = .{
                                        .option_name = global_opt.name,
                                        .is_short = false,
                                        .expected_type = @typeName(global_opt.type),
                                    } };
                                    return zcli.ZcliError.OptionMissingValue;
                                }
                            }

                            try dispatchGlobalOption(context, global_opt, value, false);

                            handled = true;
                            break;
                        }
                    }
                } else if (std.mem.startsWith(u8, arg, "-") and arg.len == 2) {
                    // Single short option: mirrors the long path, including
                    // values for non-boolean globals (`-c config.json`).
                    const short_char = arg[1];
                    inline for (global_options) |global_opt| {
                        if (global_opt.short == short_char) {
                            try consumed.append(context.allocator, i);

                            var value: []const u8 = "true";
                            if (global_opt.type != bool) {
                                if (i + 1 < args.len and
                                    (!std.mem.startsWith(u8, args[i + 1], "-") or option_utils.isNegativeNumber(args[i + 1])))
                                {
                                    i += 1;
                                    value = args[i];
                                    try consumed.append(context.allocator, i);
                                } else {
                                    context.diagnostic = .{ .OptionMissingValue = .{
                                        .option_name = global_opt.name,
                                        .is_short = true,
                                        .expected_type = @typeName(global_opt.type),
                                    } };
                                    return zcli.ZcliError.OptionMissingValue;
                                }
                            }

                            try dispatchGlobalOption(context, global_opt, value, true);

                            handled = true;
                            break;
                        }
                    }
                } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 2) {
                    // Bundled shorts (-abc): consumed as globals only when
                    // EVERY char is a boolean global — a partial match would
                    // silently drop the other chars, and a value-taking short
                    // can't get a value inside a bundle. Anything else stays
                    // in `remaining` for the command's own option parser.
                    const short_opts = arg[1..];
                    var all_boolean_globals = true;
                    for (short_opts) |short_char| {
                        var char_is_boolean_global = false;
                        inline for (global_options) |global_opt| {
                            if (global_opt.short == short_char and global_opt.type == bool) {
                                char_is_boolean_global = true;
                            }
                        }
                        if (!char_is_boolean_global) all_boolean_globals = false;
                    }

                    if (all_boolean_globals) {
                        try consumed.append(context.allocator, i);
                        for (short_opts) |short_char| {
                            inline for (global_options) |global_opt| {
                                if (global_opt.short == short_char) {
                                    try dispatchGlobalOption(context, global_opt, "true", true);
                                }
                            }
                        }
                        handled = true;
                    }
                }

                if (!handled) {
                    try remaining.append(context.allocator, arg);
                }

                i += 1;
            }

            const result = zcli.GlobalOptionsResult{
                .consumed = try consumed.toOwnedSlice(context.allocator),
                .remaining = try remaining.toOwnedSlice(context.allocator),
            };
            // Note: Caller is responsible for freeing consumed and remaining arrays
            return result;
        }

        // ------------------------------------------------------------------
        // Command execution
        //
        // executeCommand routes argv to a command module; everything after
        // routing — context metadata, hook dispatch, parsing, execution,
        // error handling — is shared by regular and plugin commands in
        // executeResolvedCommand and the hook helpers below.
        // ------------------------------------------------------------------

        /// Whether a resolved module came from the app's command tree or a
        /// plugin's `commands`. The paths differ in one place: a regular
        /// command with no positional Args treats a stray non-option argument
        /// as a mistyped subcommand (CommandNotFound); plugin commands keep
        /// their historical behavior of letting the parser report it.
        const CommandKind = enum { regular, plugin };

        /// Dispatch `err` to the plugins' onError hooks, first handler wins.
        /// Returns whether a plugin handled (and thereby suppressed) the error.
        fn runOnErrorHooks(context: *Context, err: anyerror) !bool {
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "onError")) {
                    if (try Plugin.onError(context, err)) return true;
                }
            }
            return false;
        }

        /// Run postParse hooks, threading each plugin's replacement ParsedArgs.
        fn runPostParseHooks(context: *Context, parsed: zcli.ParsedArgs) !zcli.ParsedArgs {
            var parsed_args = parsed;
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "postParse")) {
                    if (try Plugin.postParse(context, parsed_args)) |new_parsed| {
                        parsed_args = new_parsed;
                    }
                }
            }
            return parsed_args;
        }

        /// Run preExecute hooks. Returns null when a plugin cancels execution.
        fn runPreExecuteHooks(context: *Context, parsed: zcli.ParsedArgs) !?zcli.ParsedArgs {
            var parsed_args = parsed;
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "preExecute")) {
                    if (try Plugin.preExecute(context, parsed_args)) |new_parsed| {
                        parsed_args = new_parsed;
                    } else {
                        return null;
                    }
                }
            }
            return parsed_args;
        }

        /// Point context.command_path at an allocated copy of `parts`.
        fn setCommandPath(context: *Context, parts: []const []const u8) !void {
            const copy = try context.allocator.alloc([]const u8, parts.len);
            for (parts, 0..) |part, i| {
                copy[i] = try context.allocator.dupe(u8, part);
            }
            context.command_path = copy;
        }

        /// Convert a command struct's fields to runtime FieldInfo for plugin
        /// introspection, pulling per-option short/description from
        /// `options_meta` (pass null for Args structs, which carry neither).
        fn buildFieldInfoList(comptime T: type, comptime options_meta: anytype, allocator: std.mem.Allocator) ![]const zcli.FieldInfo {
            const type_info = @typeInfo(T);
            if (type_info != .@"struct") return &.{};
            var field_list = std.ArrayList(zcli.FieldInfo).empty;
            inline for (type_info.@"struct".fields) |field| {
                const field_type_info = @typeInfo(field.type);
                var short: ?u8 = null;
                var description: ?[]const u8 = null;
                if (comptime @TypeOf(options_meta) != @TypeOf(null)) {
                    if (@hasField(@TypeOf(options_meta), field.name)) {
                        const field_meta = @field(options_meta, field.name);
                        if (@hasField(@TypeOf(field_meta), "short")) short = field_meta.short;
                        if (@hasField(@TypeOf(field_meta), "description")) description = field_meta.description;
                    }
                }
                const default_true = comptime blk: {
                    if (field.type != bool) break :blk false;
                    if (field.default_value_ptr) |dp| break :blk @as(*const bool, @ptrCast(@alignCast(dp))).*;
                    break :blk false;
                };
                try field_list.append(allocator, zcli.FieldInfo{
                    .name = field.name,
                    .is_optional = field_type_info == .optional or field.default_value_ptr != null,
                    .is_array = field_type_info == .pointer and field_type_info.pointer.size == .slice and field_type_info.pointer.child != u8,
                    .short = short,
                    .description = description,
                    .default_true = default_true,
                });
            }
            return field_list.toOwnedSlice(allocator);
        }

        /// Record the resolved command's metadata and introspection info on
        /// the context (the help plugin renders from these).
        fn setCommandInfo(comptime Module: type, context: *Context) !void {
            if (@hasDecl(Module, "meta")) {
                const meta = Module.meta;
                context.command_meta = zcli.CommandMeta{
                    .description = if (@hasField(@TypeOf(meta), "description")) meta.description else null,
                    .examples = if (@hasField(@TypeOf(meta), "examples")) meta.examples else null,
                };
            }

            const options_meta = comptime blk: {
                if (@hasDecl(Module, "meta") and @hasField(@TypeOf(Module.meta), "options")) break :blk Module.meta.options;
                break :blk null;
            };
            context.command_module_info = zcli.CommandModuleInfo{
                .has_args = @hasDecl(Module, "Args"),
                .has_options = @hasDecl(Module, "Options"),
                .raw_meta_ptr = if (@hasDecl(Module, "meta")) &Module.meta else null,
                .args_fields = if (@hasDecl(Module, "Args")) try buildFieldInfoList(Module.Args, null, context.allocator) else &.{},
                .options_fields = if (@hasDecl(Module, "Options")) try buildFieldInfoList(Module.Options, options_meta, context.allocator) else &.{},
            };
        }

        /// Everything that happens after routing has resolved a command
        /// module: record context info, run postParse/preExecute hooks, parse
        /// argv, execute, and dispatch errors/postExecute. `command_parts` is
        /// the matched command path; `remaining_args` the argv after it.
        fn executeResolvedCommand(comptime Module: type, comptime kind: CommandKind, context: *Context, command_parts: []const []const u8, remaining_args: []const []const u8) !void {
            @setEvalBranchQuota(10000);
            try setCommandPath(context, command_parts);
            try setCommandInfo(Module, context);

            var parsed_args = zcli.ParsedArgs.init(context.allocator);
            parsed_args.positional = remaining_args;
            parsed_args = try runPostParseHooks(context, parsed_args);
            parsed_args = (try runPreExecuteHooks(context, parsed_args)) orelse return; // plugin cancelled execution

            // Metadata-only command group (no execute): route through
            // CommandNotFound so the help plugin renders the subcommand list.
            if (!@hasDecl(Module, "execute")) {
                if (try runOnErrorHooks(context, error.CommandNotFound)) return;
                const cmd_name_str = try std.mem.join(context.allocator, " ", command_parts);
                defer context.allocator.free(cmd_name_str);
                try context.stderr().print("'{s}' is a command group. Use --help to see available subcommands.\n", .{cmd_name_str});
                return error.CommandNotFound;
            }

            // Reached only after the `!@hasDecl(Module, "execute")` early return
            // above, and `validateCommand` requires an executable command to
            // declare both — so `Args`/`Options` are guaranteed present here.
            const ArgsType = Module.Args;
            const OptionsType = Module.Options;
            const cmd_meta = if (@hasDecl(Module, "meta")) Module.meta else null;

            // A regular command that declares no positionals but got a
            // non-option argument was almost certainly invoked with a
            // mistyped subcommand — CommandNotFound, not a parse error.
            if (kind == .regular and std.meta.fields(ArgsType).len == 0 and
                remaining_args.len > 0 and !std.mem.startsWith(u8, remaining_args[0], "-"))
            {
                return error.CommandNotFound;
            }

            var parse_diag: ?zcli.ZcliDiagnostic = null;
            const parse_result = command_parser.parseCommandLine(ArgsType, OptionsType, cmd_meta, context.allocator, context.environ, parsed_args.positional, &parse_diag) catch |err| {
                context.diagnostic = parse_diag;
                if (try runOnErrorHooks(context, err)) return;
                try reportParseError(context, parse_diag);
                return err;
            };
            defer parse_result.deinit();

            const args_instance = parse_result.args;
            var options_instance = parse_result.options;

            // Config defaults override struct defaults; CLI-provided values
            // (already parsed) still take precedence.
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "applyConfigDefaults")) {
                    Plugin.applyConfigDefaults(context, OptionsType, &options_instance);
                }
            }

            // Execute. A handled error (onError returns true) is suppressed
            // and falls through to postExecute with success = false.
            var success = true;
            Module.execute(args_instance, options_instance, context) catch |err| {
                success = false;
                if (!try runOnErrorHooks(context, err)) return err;
            };

            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "postExecute")) {
                    try Plugin.postExecute(context, success);
                }
            }
        }

        fn executeCommand(_: *Self, context: *Context, args_input: []const []const u8) !void {
            @setEvalBranchQuota(10000);
            // The root command handles bare invocation: no args, or a first
            // arg that's an option rather than a command name.
            const use_root_command = args_input.len == 0 or std.mem.startsWith(u8, args_input[0], "-");

            const root_exists = comptime blk: {
                for (cmd_entries) |cmd| {
                    if (cmd.path.len == 1 and std.mem.eql(u8, cmd.path[0], "root")) break :blk true;
                }
                break :blk false;
            };

            // Route through the "root" pseudo-path when applicable. The root
            // command still receives the original argv for option parsing.
            const root_args = [_][]const u8{"root"};
            const args: []const []const u8 = if (use_root_command and root_exists) &root_args else args_input;

            // No command and no root command to fall back on: run the hooks
            // (the help plugin answers a bare --help here), then route
            // through CommandNotFound.
            if (args.len == 0) {
                const parsed_args = try runPostParseHooks(context, zcli.ParsedArgs.init(context.allocator));
                _ = (try runPreExecuteHooks(context, parsed_args)) orelse return; // plugin cancelled execution
                if (try runOnErrorHooks(context, error.CommandNotFound)) return;
                try context.stderr().print("No command specified. Use --help for usage information.\n", .{});
                return error.CommandNotFound;
            }

            // Regular commands, longest path first so the longest match wins.
            const sorted_commands = comptime sortedByPathLengthDesc(cmd_entries);
            inline for (sorted_commands) |cmd| {
                if (cmd.path.len <= args.len) {
                    var parts_match = true;
                    for (cmd.path, 0..) |part, i| {
                        if (!std.mem.eql(u8, part, args[i])) {
                            parts_match = false;
                            break;
                        }
                    }
                    if (parts_match) {
                        // The root command keeps the original argv (it's all
                        // options/positionals for root); other commands skip
                        // their matched path parts.
                        const remaining_args = if (use_root_command and std.mem.eql(u8, cmd.path[0], "root"))
                            args_input
                        else
                            args[cmd.path.len..];
                        return executeResolvedCommand(cmd.module, .regular, context, cmd.path, remaining_args);
                    }
                }
            }

            // Plugin commands: find the longest matching path, then execute it.
            var best_match_idx: ?usize = null;
            var best_match_len: usize = 0;
            inline for (plugin_command_entries, 0..) |plugin_cmd, idx| {
                if (args.len >= plugin_cmd.path.len and plugin_cmd.path.len > best_match_len) {
                    var matches = true;
                    for (plugin_cmd.path, 0..) |path_part, i| {
                        if (!std.mem.eql(u8, path_part, args[i])) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) {
                        best_match_idx = idx;
                        best_match_len = plugin_cmd.path.len;
                    }
                }
            }
            if (best_match_idx) |match_idx| {
                inline for (plugin_command_entries, 0..) |plugin_cmd, idx| {
                    if (idx == match_idx) {
                        return executeResolvedCommand(plugin_cmd.module, .plugin, context, plugin_cmd.path, args[plugin_cmd.path.len..]);
                    }
                }
            }

            // Nothing matched. Record the attempted path and route through
            // CommandNotFound (the help plugin suggests near-misses).
            try setCommandPath(context, args);
            if (try runOnErrorHooks(context, error.CommandNotFound)) return;
            try context.stderr().print("command {s} not found\n", .{args[0]});
            return error.CommandNotFound;
        }

        // Testing/introspection methods for the test suite
        pub fn getGlobalOptions() []const plugin_types.GlobalOption {
            return global_options;
        }

        pub fn getPluginCommandEntries() []const CommandEntry {
            return plugin_command_entries;
        }

        pub fn transformArgs(self: @This(), context: anytype, args: []const []const u8) !zcli.TransformResult {
            _ = self;
            var transform_result = zcli.TransformResult{ .args = args };
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "transformArgs") and transform_result.continue_processing) {
                    transform_result = try Plugin.transformArgs(context, transform_result.args);
                }
            }
            return transform_result;
        }
    };
}
