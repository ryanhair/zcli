const std = @import("std");
const command_parser = @import("../command_parser.zig");
const option_utils = @import("../options/utils.zig");
const plugin_types = @import("../plugin_types.zig");
const zcli = @import("../zcli.zig");

const console_utf8 = @import("../console_utf8.zig");
const response_file = @import("../response_file.zig");
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
    // The message embeds user-controlled argv text (an unknown option name,
    // a rejected argument/option value) alongside framework-authored prose —
    // sanitize the whole rendered string so a crafted value can't smuggle a
    // raw terminal escape sequence through.
    try stderr.print("Error: ", .{});
    try zcli.writeSanitized(stderr, message);
    try stderr.print("\n", .{});

    // A one-line usage pointer, mirroring the not-found plugin's closing line.
    // Points at the resolved command's own --help when we're inside a command,
    // otherwise the app-level help.
    if (context.command_path.len > 0) {
        const path = try std.mem.join(context.allocator, " ", context.command_path);
        defer context.allocator.free(path);
        try stderr.print("Run '{s} {s} --help' for usage.\n", .{ context.app_name, path });
    } else {
        try stderr.print("Run '{s} --help' for usage.\n", .{context.app_name});
    }
    try stderr.flush();
}

/// Convert a global option's argv string to its declared type through the
/// single source of truth — the same `parseOptionValue` command options, env,
/// and config use — so enums, ints, floats, strings, optionals, and custom
/// `parse` types all coerce identically. A `bool` global is the one exception:
/// it is a presence flag whose value is the sentinel "true" (no token consumed).
fn convertGlobalValue(comptime T: type, value: []const u8) !T {
    if (T == bool) return std.mem.eql(u8, value, "true");
    return option_utils.parseOptionValue(T, value);
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
        error.OptionMissingRequired,
        // Cross-field constraint violations (ADR-0022) and per-field validation
        // failures also print their own diagnostic via reportParseError, so they
        // exit cleanly like every other reported parse error.
        error.OptionMutuallyExclusive,
        error.OptionMissingDependency,
        error.OptionValidationFailed,
        error.ArgumentMissingRequired,
        error.ArgumentInvalidValue,
        error.ArgumentTooMany,
        error.ArgumentValidationFailed,
        error.ResourceLimitExceeded,
        // A command that failed via context.fail() already printed its own
        // user-facing message; exit non-zero without the name/trace.
        error.CommandFailed,
        // A `@file` response file that couldn't be read is CLI misuse: the
        // message (naming the file) was already printed at the parse front.
        error.ResponseFileUnreadable,
        => true,
        else => false,
    };
}

/// Process exit status for a reported CLI error, following the conventional
/// sysexits-flavoured split most CLIs use:
///   2 — misuse: the argv itself is wrong (bad/unknown/missing options and
///       arguments, constraint and validation failures). The user should fix
///       the command line.
///   3 — the named (sub)command doesn't exist at all.
///   1 — a general failure the command itself reported via context.fail(): the
///       command was well-formed, but the work couldn't be done.
/// Caller must have already established `isReportedCliError(err)` is true.
fn exitCodeForReportedError(err: anyerror) u8 {
    return switch (err) {
        error.CommandNotFound,
        error.SubcommandNotFound,
        => 3,
        error.CommandFailed => 1,
        // Everything else reported is CLI misuse (see isReportedCliError).
        else => 2,
    };
}

/// Conventional exit status for a process terminated by SIGPIPE (128 + 13).
/// A zcli CLI whose stdout/stderr pipe is closed by a downstream reader (the
/// classic `yourcli cmd | head` case) mimics that status so shell pipelines
/// and `set -o pipefail` see the same result they would from `grep | head`.
const broken_pipe_status: u8 = 141;

/// Did a `WriteFailed` originate from a broken pipe (EPIPE / closed read end)?
///
/// Zig's start code ignores SIGPIPE, so a write to a pipe whose reader has
/// closed returns EPIPE, which the buffered `std.Io.Writer` surfaces to us as
/// the opaque `error.WriteFailed`. The concrete cause is recorded on the
/// underlying `std.Io.File.Writer.err` field, so we recover it there. This is
/// the same mechanism on Windows, where there is no SIGPIPE at all and a
/// broken pipe only ever appears as a write error — so this one check handles
/// both platforms with no signal handling required.
///
/// Only the framework-owned file writers can carry this state; a test-provided
/// `stdout_override`/`stderr_override` (an in-memory writer) never breaks a
/// pipe, so those are simply not inspected.
fn wroteToBrokenPipe(stdio: *zcli.Stdio) bool {
    if (stdio.stdout_override == null and isBrokenPipe(stdio.stdout_writer.err)) return true;
    if (stdio.stderr_override == null and isBrokenPipe(stdio.stderr_writer.err)) return true;
    return false;
}

fn isBrokenPipe(err: ?std.Io.File.Writer.Error) bool {
    return if (err) |e| e == error.BrokenPipe else false;
}

test "isReportedCliError: context.fail's error exits cleanly, unexpected errors don't" {
    try std.testing.expect(isReportedCliError(error.CommandFailed));
    try std.testing.expect(isReportedCliError(error.ArgumentMissingRequired));
    // Constraint + validation violations self-report, so they exit cleanly too.
    try std.testing.expect(isReportedCliError(error.OptionMutuallyExclusive));
    try std.testing.expect(isReportedCliError(error.OptionMissingDependency));
    try std.testing.expect(isReportedCliError(error.OptionValidationFailed));
    try std.testing.expect(isReportedCliError(error.ArgumentValidationFailed));
    // An unexpected failure keeps its name + trace (propagated, not swallowed).
    try std.testing.expect(!isReportedCliError(error.OutOfMemory));
}

test "exitCodeForReportedError: misuse=2, not-found=3, general=1" {
    // A missing/wrong command line is misuse.
    try std.testing.expectEqual(@as(u8, 2), exitCodeForReportedError(error.OptionUnknown));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForReportedError(error.ArgumentMissingRequired));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForReportedError(error.OptionMutuallyExclusive));
    try std.testing.expectEqual(@as(u8, 2), exitCodeForReportedError(error.ArgumentValidationFailed));
    // A non-existent (sub)command gets its own status.
    try std.testing.expectEqual(@as(u8, 3), exitCodeForReportedError(error.CommandNotFound));
    try std.testing.expectEqual(@as(u8, 3), exitCodeForReportedError(error.SubcommandNotFound));
    // A well-formed command that reported its own failure is a general error.
    try std.testing.expectEqual(@as(u8, 1), exitCodeForReportedError(error.CommandFailed));
}

test "isBrokenPipe: only BrokenPipe counts as a broken pipe" {
    try std.testing.expect(isBrokenPipe(error.BrokenPipe));
    // A different write error (e.g. a full disk) is a genuine failure and must
    // keep its trace, not be silently swallowed as a broken pipe.
    try std.testing.expect(!isBrokenPipe(error.NoSpaceLeft));
    // No recorded error means the write never failed.
    try std.testing.expect(!isBrokenPipe(null));
}

test "wroteToBrokenPipe: test overrides are never mistaken for a broken pipe" {
    var stdio: zcli.Stdio = .{ .io = std.testing.io };
    // A test provides its own in-memory writers via the overrides; those cannot
    // break a pipe, so the (undefined) file-writer state must not be inspected.
    var buf: [16]u8 = undefined;
    var out_aw = std.Io.Writer.fixed(&buf);
    var err_aw = std.Io.Writer.fixed(&buf);
    stdio.stdout_override = &out_aw;
    stdio.stderr_override = &err_aw;
    try std.testing.expect(!wroteToBrokenPipe(&stdio));

    // Simulate the framework's own file writer recording EPIPE.
    stdio.stdout_override = null;
    stdio.stdout_writer.err = error.BrokenPipe;
    stdio.stderr_override = null;
    stdio.stderr_writer.err = null;
    try std.testing.expect(wroteToBrokenPipe(&stdio));
}

/// Compiled registry with all command and plugin information
pub fn CompiledRegistry(comptime config: Config, comptime cmd_entries: []const CommandEntry, comptime new_plugins: []const type) type {
    // Validate plugin conflicts at compile time
    comptime {
        // Use arrays to check for conflicts since ComptimeStringMap may not be available
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
        // Global-option conflicts (both names and short flags) are validated once
        // over the flattened `global_options` list below (see the `comptime` block
        // after it) — no separate names-only pass here.
    }

    return struct {
        const Self = @This();

        /// Windows console code pages captured by `run()` when it switched the
        /// console to UTF-8 for the current invocation, handed to each Context
        /// so `context.exit` can restore them before `std.process.exit` (which
        /// skips run()'s deferred restore). Zero-valued (no-op) until run()
        /// enables it, and for direct execute()/executeWithStdio callers.
        console: console_utf8.State = .{},

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

        // Validate no command option is silently shadowed by a plugin global
        // option. parseGlobalOptions() scans the entire argv and consumes any
        // token matching a global option's long name or short flag *before*
        // routing, so a command field that collides with a global would never
        // receive its own flag — the global handler eats it and the field keeps
        // its default (see issue #663). Catch it here with a message naming the
        // command, the field, and the owning plugin.
        comptime {
            for (new_plugins) |Plugin| {
                if (!plugin_types.hasGlobalOptions(Plugin)) continue;
                for (Plugin.global_options) |gopt| {
                    for (cmd_entries) |cmd| {
                        if (!@hasDecl(cmd.module, "Options")) continue;
                        const meta = if (@hasDecl(cmd.module, "meta")) cmd.module.meta else null;
                        for (std.meta.fields(cmd.module.Options)) |field| {
                            const long = option_utils.effectiveLongName(meta, field.name);
                            if (std.mem.eql(u8, long, gopt.name)) {
                                @compileError("Command '" ++ comptimeJoinPath(cmd.path) ++
                                    "' option --" ++ long ++ " (field '" ++ field.name ++
                                    "') collides with global option --" ++ gopt.name ++
                                    " provided by plugin '" ++ @typeName(Plugin) ++
                                    "'. The global handler consumes this flag before the command runs, so the command would never see it. Rename the command's option (e.g. `meta.options." ++
                                    field.name ++ ".name`) or remove the conflicting global option.");
                            }
                            const short = option_utils.shortCharForField(meta, field.name);
                            if (short != null and gopt.short != null and short.? == gopt.short.?) {
                                @compileError("Command '" ++ comptimeJoinPath(cmd.path) ++
                                    "' option -" ++ &[_]u8{short.?} ++ " (field '" ++ field.name ++
                                    "') collides with global short flag -" ++ &[_]u8{gopt.short.?} ++
                                    " (--" ++ gopt.name ++ ") provided by plugin '" ++ @typeName(Plugin) ++
                                    "'. The global handler consumes this flag before the command runs, so the command would never see it. Rename the command's short (`meta.options." ++
                                    field.name ++ ".short`) or remove the conflicting global option.");
                            }
                        }
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

        /// Extract the variant names of an enum-typed field (`enum` or `?enum`)
        /// as a static slice of strings, or `null` for any other type. Shared by
        /// options, args, and global options so completions can offer choices.
        fn enumValuesOf(comptime T: type) ?[]const []const u8 {
            const Bare = switch (@typeInfo(T)) {
                .optional => |o| o.child,
                else => T,
            };
            switch (@typeInfo(Bare)) {
                .@"enum" => |e| {
                    var names: [e.fields.len][]const u8 = undefined;
                    for (e.fields, 0..) |f, i| names[i] = f.name;
                    const frozen = names;
                    return &frozen;
                },
                else => return null,
            }
        }

        /// Extract a field's description from either arg-meta shape: a bare
        /// string (`.id = "Task ID"`) or a struct with a `.description`.
        fn argDescriptionOf(comptime field_meta: anytype) ?[]const u8 {
            const T = @TypeOf(field_meta);
            if (@typeInfo(T) == .@"struct") {
                return if (@hasField(T, "description")) field_meta.description else null;
            }
            return field_meta;
        }

        /// Build the completion `Spec` from a struct-form field-meta's `.complete`
        /// value (ADR-0026). A function → `.hook`, wrapped in a thunk with the
        /// stored `anyerror!Result` signature so an inferred error set coerces
        /// cleanly; `.file`/`.dir` enum literals → the matching builtin. Non-struct
        /// meta (a bare description string) carries no completion.
        fn completeSpecOf(comptime field_meta: anytype) ?zcli.completion.Spec {
            const T = @TypeOf(field_meta);
            if (@typeInfo(T) != .@"struct") return null;
            if (!@hasField(T, "complete")) return null;
            const cv = field_meta.complete;
            const CV = @TypeOf(cv);
            if (@typeInfo(CV) == .@"fn") {
                const Thunk = struct {
                    fn call(req: *zcli.completion.Request) anyerror!zcli.completion.Result {
                        return cv(req);
                    }
                };
                return .{ .hook = Thunk.call };
            }
            if (CV == @TypeOf(.enum_literal)) {
                return switch (cv) {
                    .file => .file,
                    .dir => .dir,
                    else => @compileError("meta field .complete: unknown builtin ." ++ @tagName(cv) ++ " (expected .file, .dir, or a function)"),
                };
            }
            @compileError("meta field .complete must be a function or the builtin .file/.dir");
        }

        fn buildGlobalOptionsInfo() []const zcli.OptionInfo {
            var opts: []const zcli.OptionInfo = &.{};
            for (global_options) |global_opt| {
                opts = opts ++ .{zcli.OptionInfo{
                    .name = global_opt.name,
                    .short = global_opt.short,
                    .description = global_opt.description,
                    .takes_value = global_opt.type != bool,
                    .enum_values = enumValuesOf(global_opt.type),
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

                // Options and args both project from the single per-field
                // `FieldInfo` extraction (moduleFieldInfo). The completion-facing
                // `OptionInfo`/`ArgInfo` are thin views of it, so a new per-field
                // meta attribute only has to be threaded through FieldInfo once.
                const mi = moduleInfoOf(cmd.module);

                var options: []const zcli.OptionInfo = &.{};
                for (mi.options_fields) |f| options = options ++ .{optionInfoFrom(f)};

                var arg_infos: []const zcli.ArgInfo = &.{};
                for (mi.args_fields) |f| arg_infos = arg_infos ++ .{argInfoFrom(f)};

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

        /// Project a `FieldInfo` to the completion/doc-facing `OptionInfo`.
        /// `takes_value` is the non-bool test the old extractor did directly:
        /// FieldInfo.type_name is `@typeName(field.type)`, so a bool option is
        /// exactly `"bool"` or `"?bool"`.
        fn optionInfoFrom(comptime f: zcli.FieldInfo) zcli.OptionInfo {
            const takes_value = !(std.mem.eql(u8, f.type_name, "bool") or std.mem.eql(u8, f.type_name, "?bool"));
            return .{
                .name = f.name,
                .short = f.short,
                .description = f.description,
                .takes_value = takes_value,
                .enum_values = f.enum_values,
                .complete = f.complete,
            };
        }

        /// Project a `FieldInfo` to the completion/doc-facing `ArgInfo`. A
        /// positional's `is_variadic` is exactly FieldInfo's `is_array` (a
        /// non-u8 slice), computed once in the shared extractor.
        fn argInfoFrom(comptime f: zcli.FieldInfo) zcli.ArgInfo {
            return .{
                .name = f.name,
                .description = f.description,
                .is_optional = f.is_optional,
                .is_variadic = f.is_array,
                .enum_values = f.enum_values,
                .complete = f.complete,
            };
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
                .theme = .{ .theme = zcli.appTheme(), .caps = zcli.theme.Capabilities.init(environ, io) },
                .app_name = config.app_name,
                .app_version = config.app_version,
                .app_description = config.app_description,
                .available_commands = available_commands,
                .command_path = &.{},
                .plugin_command_info = plugin_command_info_list,
                .global_options = global_options_list,
                .console = self.console,
            };
            defer context.deinit();

            // 0. Let plugins capture references off the context into their
            // ContextData before any hook runs. A failure here aborts before
            // execution and runs any deinit hooks already owed.
            try context.initPluginData();

            // 0.25 Run onStartup hooks once per invocation, after plugin data
            // is captured but before any argument parsing or routing. A startup
            // hook does one-time work (e.g. a rate-limited "new version
            // available" probe); an error here propagates like any other
            // pre-command hook (preParse/transformArgs use a bare `try`),
            // aborting before the command runs.
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "onStartup")) {
                    try Plugin.onStartup(&context);
                }
            }

            // 0.5 Response-file (@file) expansion, once, at the very front of
            // parsing — before global options, transforms, and command routing
            // — so a @file may contribute the command name, options, and
            // positionals alike. See response_file.zig for the full semantics
            // (single-level, `--` stops it). With no @file present this is the
            // caller's argv untouched — pass-through arguments always keep
            // their original lifetime (plugins and diagnostics may hold argv
            // slices past this call); only file-derived arguments and the
            // rebuilt outer slice land in the arena.
            var rf_diag: ?response_file.Diagnostic = null;
            const expanded_args = response_file.expandArgs(context.allocator, io, std.Io.Dir.cwd(), args, &rf_diag) catch |err| {
                // A missing/unreadable response file is reported CLI misuse:
                // print the offending path (sanitized — it comes from argv) and
                // a usage pointer, then let run() map it to exit code 2.
                if (rf_diag) |d| {
                    var stderr = context.stderr();
                    try stderr.print("Error: cannot read response file '", .{});
                    try zcli.writeSanitized(stderr, d.path);
                    try stderr.print("'\n", .{});
                    try stderr.print("Run '{s} --help' for usage.\n", .{context.app_name});
                    try stderr.flush();
                }
                return err;
            };

            // 1. Run preParse hooks
            var current_args = expanded_args;
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
                // Dispatch through runOnErrorHooks (not a bare `try Plugin.onError`)
                // so a hook that itself errors can't shadow the original parse
                // diagnostic — the same catch-warn-continue contract every other
                // error site uses (#390/#512).
                if (!try runOnErrorHooks(&context, err)) {
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
            // Hand the captured code pages to each Context built for this run so
            // context.exit() can restore them before std.process.exit skips the
            // deferred restore above (issue #438).
            self.console = console;

            // Own the Stdio here (rather than letting execute() create it) so
            // that after a failure we can inspect the writer state to tell a
            // broken pipe apart from any other write error.
            var stdio: zcli.Stdio = undefined;
            stdio.init(io);

            self.executeWithStdio(allocator, io, environ, if (args.len > 0) args[1..] else args, &stdio) catch |err| {
                // A write to a closed downstream pipe (`yourcli cmd | head`)
                // surfaces as WriteFailed. Behave like a well-mannered unix
                // program: no trace, no diagnostic, just the conventional
                // SIGPIPE exit status. Checked before the reported-error path
                // because WriteFailed is not itself a "reported" error — the
                // pipe closing is a normal end to a pipeline, not a user error.
                // Windows has no SIGPIPE, but the broken pipe still lands here
                // as a write error, so this covers it too.
                if (err == error.WriteFailed and wroteToBrokenPipe(&stdio)) {
                    console.restore();
                    std.process.exit(broken_pipe_status);
                }
                // CLI-entry semantics: some failures already showed the user a
                // message — parse/routing diagnostics, a plugin, the framework
                // fallback, or a command's own context.fail(). Exit non-zero
                // with the conventional status (2 misuse / 3 command-not-found
                // / 1 general) without letting a raw error trace follow that
                // friendly message. Anything else is an unexpected failure;
                // propagate it so the name and trace aid debugging. Library/test
                // callers who want the error itself use execute() directly.
                if (isReportedCliError(err)) {
                    console.restore();
                    std.process.exit(exitCodeForReportedError(err));
                }
                return err;
            };

            // The command completed without erroring, but the writers may still
            // have hit a broken pipe on the *final* buffered flush — the one
            // `executeWithStdio`'s `defer stdio.flush()` runs on its way out,
            // which swallows the write error (`catch {}`) rather than surfacing
            // it as `error.WriteFailed`. A whole-output-fits-in-one-buffer
            // command (`yourcli cmd | head -c0`) never sees a mid-command write
            // failure, so without this check it would exit 0 instead of the
            // conventional SIGPIPE status. Check the recorded writer error the
            // same way the error path above does.
            if (wroteToBrokenPipe(&stdio)) {
                console.restore();
                std.process.exit(broken_pipe_status);
            }
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
                    .expected_type = zcli.expectedTypeName(global_opt.type),
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
            // Once a bare `--` is seen, stop matching global options for the rest
            // of argv — the command-level parsers honor `--` as an end-of-options
            // terminator (options/parser.zig, command_parser.zig), so the global
            // layer must too or the two disagree (#501). The `--` itself and every
            // token after it flow untouched into `remaining` so the command parser
            // still sees its own terminator.
            var options_ended = false;
            while (i < args.len) {
                const arg = args[i];
                var handled = false;

                if (!options_ended and std.mem.eql(u8, arg, "--")) {
                    options_ended = true;
                } else if (!options_ended and std.mem.startsWith(u8, arg, "--")) {
                    // Split `--name=value` before matching, mirroring the
                    // command-option long path (#391).
                    const opt_body = arg[2..];
                    const eq_idx = std.mem.indexOfScalar(u8, opt_body, '=');
                    const opt_name = if (eq_idx) |e| opt_body[0..e] else opt_body;
                    const attached: ?[]const u8 = if (eq_idx) |e| opt_body[e + 1 ..] else null;
                    // Check if this is a global option
                    inline for (global_options) |global_opt| {
                        if (std.mem.eql(u8, opt_name, global_opt.name)) {
                            // Handle the global option
                            try consumed.append(context.allocator, i);

                            var value: []const u8 = "true"; // Boolean flags: presence == true
                            if (global_opt.type != bool) {
                                if (attached) |v| {
                                    value = v;
                                } else if (i + 1 < args.len and option_utils.isValueToken(args[i + 1])) {
                                    // Same next-token-is-a-value rule the command
                                    // parsers share (options/utils.zig).
                                    i += 1;
                                    value = args[i];
                                    try consumed.append(context.allocator, i);
                                } else {
                                    context.diagnostic = .{ .OptionMissingValue = .{
                                        .option_name = global_opt.name,
                                        .is_short = false,
                                        .expected_type = zcli.expectedTypeName(global_opt.type),
                                    } };
                                    return zcli.ZcliError.OptionMissingValue;
                                }
                            } else if (attached) |v| {
                                // `--flag=x` on a boolean global errors like the
                                // command parser's boolean-with-value path.
                                context.diagnostic = .{ .OptionBooleanWithValue = .{
                                    .option_name = global_opt.name,
                                    .is_short = false,
                                    .provided_value = v,
                                } };
                                return zcli.ZcliError.OptionBooleanWithValue;
                            }

                            try dispatchGlobalOption(context, global_opt, value, false);

                            handled = true;
                            break;
                        }
                    }
                } else if (!options_ended and std.mem.startsWith(u8, arg, "-") and arg.len == 2) {
                    // Single short option: mirrors the long path, including
                    // values for non-boolean globals (`-c config.json`).
                    const short_char = arg[1];
                    inline for (global_options) |global_opt| {
                        if (global_opt.short == short_char) {
                            try consumed.append(context.allocator, i);

                            var value: []const u8 = "true";
                            if (global_opt.type != bool) {
                                if (i + 1 < args.len and option_utils.isValueToken(args[i + 1])) {
                                    i += 1;
                                    value = args[i];
                                    try consumed.append(context.allocator, i);
                                } else {
                                    context.diagnostic = .{ .OptionMissingValue = .{
                                        .option_name = global_opt.name,
                                        .is_short = true,
                                        .expected_type = zcli.expectedTypeName(global_opt.type),
                                    } };
                                    return zcli.ZcliError.OptionMissingValue;
                                }
                            }

                            try dispatchGlobalOption(context, global_opt, value, true);

                            handled = true;
                            break;
                        }
                    }
                } else if (!options_ended and std.mem.startsWith(u8, arg, "-") and arg.len > 2) {
                    // Mixed short bundle (GNU getopt), mirroring the command-option
                    // parser (options/parser.zig): consume leading boolean globals
                    // one at a time; the first value-taking global short claims the
                    // rest of the token as an attached value (`-cval` == `-c val`),
                    // or the next argument when it ends the token (`-vc val`). The
                    // whole token is consumed only when it resolves entirely to
                    // globals — a non-global leading char aborts (the token layer
                    // can't partially consume), leaving the token in `remaining`
                    // for the command's own option parser.
                    const short_opts = arg[1..];

                    // First pass: decide whether the token is consumable without
                    // mutating any state. Every char up to (and including) the first
                    // value-taking global must resolve to a global; a value-taking
                    // global ends the scan since the remainder is its value.
                    var consumable = true;
                    for (short_opts) |short_char| {
                        var is_bool_global = false;
                        var is_value_global = false;
                        inline for (global_options) |global_opt| {
                            if (global_opt.short == short_char) {
                                if (global_opt.type == bool) {
                                    is_bool_global = true;
                                } else {
                                    is_value_global = true;
                                }
                            }
                        }
                        if (is_value_global) break; // rest of token is this option's value
                        if (!is_bool_global) {
                            consumable = false;
                            break;
                        }
                    }

                    if (consumable) {
                        try consumed.append(context.allocator, i);
                        var ci: usize = 0;
                        dispatch: while (ci < short_opts.len) : (ci += 1) {
                            const short_char = short_opts[ci];
                            inline for (global_options) |global_opt| {
                                if (global_opt.short == short_char) {
                                    if (global_opt.type == bool) {
                                        try dispatchGlobalOption(context, global_opt, "true", true);
                                    } else {
                                        const attached = short_opts[ci + 1 ..];
                                        var value: []const u8 = attached;
                                        if (attached.len == 0) {
                                            if (i + 1 < args.len and option_utils.isValueToken(args[i + 1])) {
                                                i += 1;
                                                value = args[i];
                                                try consumed.append(context.allocator, i);
                                            } else {
                                                context.diagnostic = .{ .OptionMissingValue = .{
                                                    .option_name = global_opt.name,
                                                    .is_short = true,
                                                    .expected_type = zcli.expectedTypeName(global_opt.type),
                                                } };
                                                return zcli.ZcliError.OptionMissingValue;
                                            }
                                        }
                                        try dispatchGlobalOption(context, global_opt, value, true);
                                        break :dispatch; // value claimed the rest of the token
                                    }
                                    break;
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
        /// A hook that itself errors must not replace the original error (whose
        /// diagnostic would then never be reported) — the hook's failure is
        /// noted on stderr and dispatch continues to the next hook (#390).
        fn runOnErrorHooks(context: *Context, err: anyerror) !bool {
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "onError")) {
                    const plugin_name = comptime if (@hasDecl(Plugin, "plugin_id")) Plugin.plugin_id else @typeName(Plugin);
                    const handled = Plugin.onError(context, err) catch |hook_err| blk: {
                        context.stderr().print(
                            "Warning: {s} onError hook failed with {s} while handling {s}\n",
                            .{ plugin_name, @errorName(hook_err), @errorName(err) },
                        ) catch {};
                        break :blk false;
                    };
                    if (handled) return true;
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

        /// Convert a command struct's fields to `FieldInfo` — the single per-field
        /// metadata projection, built once at comptime. `field_meta_map` is the
        /// per-field metadata map — an options map (`meta.options`, structs
        /// carrying short/description/complete/requires) when `is_option`, an args
        /// map (`meta.args`, plain string descriptions or structs) otherwise, or
        /// `null`. `is_option` also gates required-option marking: a defaultless
        /// positional is required by position, not by this flag.
        ///
        /// Both the completion/doc `CommandInfo` view (via `optionInfoFrom`/
        /// `argInfoFrom`) and the help `CommandModuleInfo` view read from this, so
        /// a new per-field attribute is threaded here once. Being comptime, the
        /// result is static data — `setCommandInfo` references it with no
        /// per-dispatch allocation.
        fn buildFieldInfoList(comptime T: type, comptime field_meta_map: anytype, comptime is_option: bool) []const zcli.FieldInfo {
            const type_info = @typeInfo(T);
            if (type_info != .@"struct") return &.{};
            var field_list: []const zcli.FieldInfo = &.{};
            for (type_info.@"struct".fields) |field| {
                const field_type_info = @typeInfo(field.type);
                var short: ?u8 = null;
                var description: ?[]const u8 = null;
                var complete: ?zcli.completion.Spec = null;
                if (@TypeOf(field_meta_map) != @TypeOf(null)) {
                    if (@hasField(@TypeOf(field_meta_map), field.name)) {
                        const fm = @field(field_meta_map, field.name);
                        // Args metadata may be a bare string description; both
                        // shapes go through the shared extractors used by the
                        // CommandInfo projection (argDescriptionOf handles the
                        // string-vs-struct split; shorts/complete only exist on the
                        // struct form).
                        description = argDescriptionOf(fm);
                        short = shortOf(fm);
                        complete = completeSpecOf(fm);
                    }
                }
                const requires: ?[]const []const u8 = blk: {
                    if (@TypeOf(field_meta_map) == @TypeOf(null)) break :blk null;
                    if (!@hasField(@TypeOf(field_meta_map), field.name)) break :blk null;
                    const fm = @field(field_meta_map, field.name);
                    if (isStringLike(@TypeOf(fm)) or !@hasField(@TypeOf(fm), "requires")) break :blk null;
                    break :blk option_utils.tupleToStrings(fm.requires);
                };
                const default_value: ?[]const u8 = blk: {
                    const dp = field.default_value_ptr orelse break :blk null;
                    const dv = @as(*const field.type, @ptrCast(@alignCast(dp))).*;
                    break :blk switch (field_type_info) {
                        .bool => if (dv) "true" else "false",
                        .int, .comptime_int, .float, .comptime_float => std.fmt.comptimePrint("{d}", .{dv}),
                        .@"enum" => @tagName(dv),
                        .pointer => |p| if (p.size == .slice and p.child == u8) dv else null,
                        else => null, // optionals default to null; arrays have no scalar default
                    };
                };
                field_list = field_list ++ .{zcli.FieldInfo{
                    .name = field.name,
                    .is_optional = field_type_info == .optional or field.default_value_ptr != null,
                    .is_array = field_type_info == .pointer and field_type_info.pointer.size == .slice and field_type_info.pointer.child != u8,
                    .short = short,
                    .description = description,
                    .type_name = @typeName(field.type),
                    .default_value = default_value,
                    .is_required = is_option and option_utils.isRequiredOption(field),
                    .enum_values = enumValuesOf(field.type),
                    .requires = requires,
                    .complete = complete,
                }};
            }
            return field_list;
        }

        /// A field's short flag from its (struct-form) option meta, else `null`.
        /// Args metadata (a bare string) has no short.
        fn shortOf(comptime field_meta: anytype) ?u8 {
            const T = @TypeOf(field_meta);
            if (@typeInfo(T) != .@"struct") return null;
            return if (@hasField(T, "short")) field_meta.short else null;
        }

        /// Whether `T` is a string description: `[]const u8` or a string literal
        /// (`*const [N:0]u8`). Used to tell an args metadata entry (a bare
        /// string) from an options one (a struct).
        fn isStringLike(comptime T: type) bool {
            const ti = @typeInfo(T);
            if (ti != .pointer) return false;
            if (ti.pointer.size == .slice) return ti.pointer.child == u8;
            if (ti.pointer.size == .one) {
                const ci = @typeInfo(ti.pointer.child);
                return ci == .array and ci.array.child == u8;
            }
            return false;
        }

        /// The command module's full introspection info, built once at comptime.
        /// The single source of truth for a command's per-field metadata: both
        /// `setCommandInfo` (help) and `buildCommandInfoFromEntries` (completions/
        /// docs) read from it.
        fn moduleInfoOf(comptime Module: type) zcli.CommandModuleInfo {
            const options_meta = comptime blk: {
                if (@hasDecl(Module, "meta") and @hasField(@TypeOf(Module.meta), "options")) break :blk Module.meta.options;
                break :blk null;
            };
            const args_meta = comptime blk: {
                if (@hasDecl(Module, "meta") and @hasField(@TypeOf(Module.meta), "args")) break :blk Module.meta.args;
                break :blk null;
            };
            return .{
                .has_args = @hasDecl(Module, "Args"),
                .has_options = @hasDecl(Module, "Options"),
                .args_fields = if (@hasDecl(Module, "Args")) buildFieldInfoList(Module.Args, args_meta, false) else &.{},
                .options_fields = if (@hasDecl(Module, "Options")) buildFieldInfoList(Module.Options, options_meta, true) else &.{},
                .exclusive = option_utils.exclusiveSets(if (@hasDecl(Module, "meta")) Module.meta else null),
            };
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
            context.command_module_info = comptime moduleInfoOf(Module);
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
            // Record the attempted path (base command + stray token) and
            // dispatch onError like every other not-found site, so the
            // not-found plugin renders suggestions instead of a silent
            // exit (#384).
            if (kind == .regular and std.meta.fields(ArgsType).len == 0 and
                remaining_args.len > 0 and !std.mem.startsWith(u8, remaining_args[0], "-"))
            {
                const attempted = try context.allocator.alloc([]const u8, command_parts.len + 1);
                defer context.allocator.free(attempted);
                @memcpy(attempted[0..command_parts.len], command_parts);
                attempted[command_parts.len] = remaining_args[0];
                try setCommandPath(context, attempted);
                if (try runOnErrorHooks(context, error.CommandNotFound)) return;
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

            // Config defaults fill only options no higher source set. The
            // provided bitset (CLI + env, keyed by Options field order) is the
            // single mechanism enforcing CLI > env > config: config skips any
            // field whose flag is true. The plugin marks every field it fills
            // in `config_applied` — an explicit report, not a value diff, so a
            // config value equal to a field's placeholder still counts as
            // supplied (#388).
            var config_applied = [_]bool{false} ** command_parser.optionFieldCount(OptionsType);
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "applyConfigDefaults")) {
                    Plugin.applyConfigDefaults(context, OptionsType, &options_instance, &parse_result.options_provided, &config_applied);
                }
            }

            // Required options: a non-optional, defaultless, non-bool, non-array
            // Options field must be supplied by SOME source — CLI, env, or config.
            // Checked here, after every source has been applied, and reported like
            // any other parse error (humane message + usage hint).
            if (command_parser.firstMissingRequiredOption(OptionsType, cmd_meta, parse_result.options_provided, config_applied)) |missing| {
                const diag: zcli.ZcliDiagnostic = .{ .OptionMissingRequired = .{
                    .option_name = missing.name,
                    .expected_type = missing.expected_type,
                } };
                context.diagnostic = diag;
                if (try runOnErrorHooks(context, error.OptionMissingRequired)) return;
                try reportParseError(context, diag);
                return error.OptionMissingRequired;
            }

            // Cross-field constraints (ADR-0022), checked over the same
            // provided + config_applied bitsets. Order per ADR: requires, then
            // exclusive (missing-required above ran first).
            if (command_parser.firstMissingDependency(OptionsType, cmd_meta, parse_result.options_provided, config_applied)) |dep| {
                const diag: zcli.ZcliDiagnostic = .{ .OptionMissingDependency = .{
                    .option_name = dep.option_name,
                    .required_name = dep.required_name,
                } };
                context.diagnostic = diag;
                if (try runOnErrorHooks(context, error.OptionMissingDependency)) return;
                try reportParseError(context, diag);
                return error.OptionMissingDependency;
            }

            if (command_parser.firstExclusiveViolation(OptionsType, cmd_meta, parse_result.options_provided, config_applied)) |ex| {
                const diag: zcli.ZcliDiagnostic = .{ .OptionMutuallyExclusive = .{
                    .first = ex.first,
                    .second = ex.second,
                } };
                context.diagnostic = diag;
                if (try runOnErrorHooks(context, error.OptionMutuallyExclusive)) return;
                try reportParseError(context, diag);
                return error.OptionMutuallyExclusive;
            }

            // Per-field validation (meta.args/options.<field>.validate), run last
            // on the fully-resolved values so the hooks see every source's effect.
            // Args first (positional), then options — mirroring their parse order.
            if (command_parser.firstArgValidationError(context.allocator, ArgsType, cmd_meta, args_instance)) |failure| {
                const diag: zcli.ZcliDiagnostic = .{ .ArgumentValidationFailed = .{
                    .field_name = failure.name,
                    .position = failure.position,
                    .provided_value = failure.provided_value,
                    .reason = failure.reason,
                } };
                context.diagnostic = diag;
                if (try runOnErrorHooks(context, error.ArgumentValidationFailed)) return;
                try reportParseError(context, diag);
                return error.ArgumentValidationFailed;
            }

            if (command_parser.firstOptionValidationError(context.allocator, OptionsType, cmd_meta, options_instance)) |failure| {
                const diag: zcli.ZcliDiagnostic = .{ .OptionValidationFailed = .{
                    .option_name = failure.name,
                    .provided_value = failure.provided_value,
                    .reason = failure.reason,
                } };
                context.diagnostic = diag;
                if (try runOnErrorHooks(context, error.OptionValidationFailed)) return;
                try reportParseError(context, diag);
                return error.OptionValidationFailed;
            }

            // Execute. A handled error (onError returns true) is suppressed
            // and falls through to postExecute with success = false. An
            // unhandled error still runs postExecute (plugin teardown must
            // not depend on the command succeeding, #389) before propagating.
            var success = true;
            Module.execute(args_instance, options_instance, context) catch |err| {
                success = false;
                if (!try runOnErrorHooks(context, err)) {
                    try runPostExecuteHooks(context, false);
                    return err;
                }
            };

            try runPostExecuteHooks(context, success);
        }

        /// Run every plugin's postExecute hook with the command's outcome.
        fn runPostExecuteHooks(context: *Context, success: bool) !void {
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
            // CommandNotFound. The not-found plugin renders the styled block
            // (suggestions + available commands) — the single source of truth.
            // A plugin that fully handles the error suppresses it (returns true);
            // otherwise the error propagates so the entry point exits non-zero.
            // No bare fallback line here: it would double-report over that block.
            try setCommandPath(context, args);
            if (try runOnErrorHooks(context, error.CommandNotFound)) return;
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
