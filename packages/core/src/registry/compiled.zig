const std = @import("std");
const command_parser = @import("../command_parser.zig");
const command_validation = @import("../command_validation.zig");
const option_utils = @import("../options/utils.zig");
const tokenizer = @import("../options/tokenizer.zig");
const plugin_types = @import("../plugin_types.zig");
const zcli = @import("../zcli.zig");

const console_utf8 = @import("../console_utf8.zig");
const response_file = @import("../response_file.zig");
const paths = @import("paths.zig");
const builder = @import("builder.zig");
const validation = @import("validation.zig");
const quota = @import("quota.zig");
const comptimeJoinPath = paths.comptimeJoinPath;
const sortedByPathLengthDesc = paths.sortedByPathLengthDesc;
const Config = builder.Config;
const CommandEntry = builder.CommandEntry;
const discoverPluginCommands = builder.discoverPluginCommands;

/// Default rendering for a parse error no plugin handled: the diagnostic's
/// precise, human-readable message on stderr (flushed — the process is about
/// to exit with an error). Falls back silently when no diagnostic was filled
/// (the error name still reaches the caller).
///
/// Every write here is best-effort (`catch {}`), never `try` (#740). Rendering
/// the diagnostic is cosmetic; classifying the error is not. A `try` on any of
/// these — the trailing `flush` above all, since a sub-4KB diagnostic only
/// touches the fd there — replaces the caller's classified parse error with
/// `error.WriteFailed`, so `myapp --bogus 2>&-` exits 1 (general failure)
/// instead of 2 (misuse) and scripts that key on 2 break. A stderr that
/// genuinely failed is still not lost: the writer records it, and `run()`
/// consults that record (see `exitOnWriteFailure`) — but only for a failure
/// nothing else classified, so the parse error keeps its status either way.
fn reportParseError(context: anytype, diag: ?zcli.ZcliDiagnostic) !void {
    const d = diag orelse return;
    const message = zcli.formatDiagnostic(d, context.allocator) catch return;
    var stderr = context.stderr();
    // The message embeds user-controlled argv text (an unknown option name,
    // a rejected argument/option value) alongside framework-authored prose —
    // sanitize the whole rendered string so a crafted value can't smuggle a
    // raw terminal escape sequence through.
    stderr.print("Error: ", .{}) catch {};
    zcli.writeSanitized(stderr, message) catch {};
    stderr.print("\n", .{}) catch {};

    // A one-line usage pointer, mirroring the not-found plugin's closing line.
    // Points at the resolved command's own --help when we're inside a command,
    // otherwise the app-level help.
    if (context.command_path.len > 0) {
        const path = try std.mem.join(context.allocator, " ", context.command_path);
        defer context.allocator.free(path);
        stderr.print("Run '{s} {s} --help' for usage.\n", .{ context.app_name, path }) catch {};
    } else {
        stderr.print("Run '{s} --help' for usage.\n", .{context.app_name}) catch {};
    }
    stderr.flush() catch {};
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

/// Compiled registry with all command and plugin information
pub fn CompiledRegistry(comptime config: Config, comptime cmd_entries: []const CommandEntry, comptime new_plugins: []const type) type {
    // Discover every plugin command (including nested) up front, then run THE
    // single registry-level validation pass over the whole composition —
    // file-based commands, plugin commands, and plugin global options. All
    // comptime validation (per-command contract, per-plugin contract, path
    // uniqueness, group shape, global-option conflicts and shadowing) lives in
    // validation.zig; nothing else in the framework calls @compileError over
    // the composition.
    const discovered_plugin_commands = comptime blk: {
        var entries: []const CommandEntry = &.{};
        for (new_plugins) |Plugin| {
            if (@hasDecl(Plugin, "commands")) {
                entries = entries ++ discoverPluginCommands(Plugin.commands, &.{});
            }
        }
        break :blk entries;
    };
    comptime validation.validateComposition(cmd_entries, discovered_plugin_commands, new_plugins);

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

        // Global-option conflicts (duplicate names/shorts across plugins) and
        // global-vs-command shadowing (#663) are validated by the single
        // registry-level pass in validation.zig, which sees the whole
        // composition.

        // All plugin command entries (including nested), discovered once above
        // and already validated by the registry-level pass.
        const plugin_command_entries = discovered_plugin_commands;

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
            // Per-command `meta` walks plus the comptimePrint that renders each
            // usage line — the single costliest per-command comptime pass, and
            // the second wall a growing app used to hit (#730).
            @setEvalBranchQuota(comptime quota.forCommands(cmd_entries.len + plugin_command_entries.len));
            return buildCommandInfoFromEntries(cmd_entries) ++ buildCommandInfoFromEntries(plugin_command_entries);
        }

        fn buildCommandInfoFromEntries(entries: anytype) []const zcli.CommandInfo {
            var cmd_info_list: []const zcli.CommandInfo = &.{};
            for (entries) |cmd| {
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
        pub fn invokeWithStdio(self: *Self, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8, stdio: *zcli.Stdio) !zcli.InvocationResult {
            // Build list of available commands at compile time
            const available_commands = comptime blk: {
                var cmd_list: []const []const []const u8 = &.{};
                // Add regular commands (paths are already arrays). The root
                // index (empty path) is not a *named* command — it must not
                // appear in suggestion/"available commands" lists.
                for (cmd_entries) |cmd| {
                    if (cmd.path.len == 0) continue;
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

            // Arena-per-command allocator: everything the command and framework
            // bookkeeping allocate during this invocation lives in the arena and is
            // reclaimed wholesale when execute() returns. Command authors never need
            // to call free. See docs/adr/0001-arena-per-command-allocator.md.
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

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

            errdefer context.deinit();

            var failure_trace: ?std.builtin.StackTrace = null;
            const invocation_error: ?anyerror = blk: {
                self.executeInvocation(&context, args) catch |err| {
                    if (@errorReturnTrace()) |trace| failure_trace = zcli.failure.retain(context.allocator, trace.*) catch null;
                    break :blk err;
                };
                break :blk null;
            };
            var primary = invocation_error;
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "onFinish")) {
                    if (context.pluginInitialized(Plugin)) {
                        const had_primary = primary != null;
                        const saved = if (had_primary) FailureState.capture(&context) else null;
                        Plugin.onFinish(&context, !had_primary) catch |err| {
                            if (!had_primary) {
                                primary = err;
                                if (@errorReturnTrace()) |trace| failure_trace = zcli.failure.retain(context.allocator, trace.*) catch null;
                                context.failure_stage = .completion;
                                context.failure_origin = .{ .plugin = pluginName(Plugin) };
                            } else context.secondary_errors.append(context.allocator, err) catch {};
                        };
                        if (saved) |state| state.restore(&context);
                    }
                }
            }
            var outcome: zcli.failure.Outcome = if (context.invocation_completed) .completed else .success;
            var status: u8 = 0;
            if (primary) |err| {
                var failure = zcli.Failure{
                    .category = context.failure_category,
                    .cause = err,
                    .trace = failure_trace,
                    .stage = context.failure_stage,
                    .origin = context.failure_origin,
                    .command_path = context.command_path,
                    .id = context.failure_id,
                    .message = context.failure_message,
                    .diagnostic = context.diagnostic,
                };
                status = finalizeFailure(&context, &failure);
                outcome = .{ .failure = failure };
            }
            // Release plugin resources before flushing and handing ownership of
            // the arena to the caller. Result strings remain alive in the arena.
            context.deinit();
            stdio.flush();
            if (stdio.writeError()) |write_err| {
                // Classified application/framework failures outrank diagnostic
                // write failures; otherwise output integrity determines status.
                const classified = switch (outcome) {
                    .failure => |f| f.category != .unexpected and f.category != .io,
                    else => false,
                };
                if (!classified) {
                    stdio.reportWriteFailure(write_err);
                    status = zcli.statusForWriteError(write_err);
                    outcome = .{ .failure = .{ .category = .io, .cause = error.WriteFailed, .stage = .flushing } };
                }
            }
            return .{ .outcome = outcome, .status = status, .arena = arena, .secondary_errors = context.secondary_errors.items };
        }

        /// Run an invocation without exiting. The result owns its diagnostic
        /// storage; call deinit even on success.
        pub fn invoke(self: *Self, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8) !zcli.InvocationResult {
            var stdio: zcli.Stdio = undefined;
            stdio.init(io);
            return self.invokeWithStdio(allocator, io, environ, args, &stdio);
        }

        pub fn executeWithStdio(self: *Self, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8, stdio: *zcli.Stdio) !void {
            var result = try self.invokeWithStdio(allocator, io, environ, args, stdio);
            defer result.deinit();
            switch (result.outcome) {
                .failure => |failure| {
                    zcli.failure.restoreTrace(failure.trace);
                    return failure.cause;
                },
                else => {},
            }
        }

        fn executeInvocation(self: *Self, context: *Context, args: []const []const u8) !void {
            // 0. Let plugins capture references off the context into their
            // ContextData before any hook runs. A failure here aborts before
            // execution and runs any deinit hooks already owed.
            try context.initPluginData();

            // Early startup hooks run before parsing. Operational I/O belongs
            // in prepare, which help and invalid invocations bypass.
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "onStartup")) {
                    setStage(context, .startup, .{ .plugin = pluginName(Plugin) });
                    try Plugin.onStartup(context);
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
            //
            // Opt-in per app (#764). When `response_files` is false — the
            // default — this whole stage compiles out and a leading `@` is just
            // a character, so `myapp install @scope/pkg` reaches the command as
            // written and no argv token can name a file to read.
            setStage(context, .response_files, .framework);
            const expanded_args = if (comptime !config.response_files) args else expand: {
                var rf_diag: ?response_file.Diagnostic = null;
                break :expand response_file.expandArgs(context.allocator, context.io, std.Io.Dir.cwd(), args, &rf_diag) catch |err| {
                    context.failure_category = .usage;
                    if (rf_diag) |d| {
                        context.failure_message = switch (err) {
                            error.ResponseFileTooLarge => std.fmt.allocPrint(context.allocator, "Error: response file '@{s}' is too large (limit {d} bytes)\nRun '{s} --help' for usage.", .{ d.path, response_file.max_file_bytes, context.app_name }) catch null,
                            else => std.fmt.allocPrint(context.allocator, "Error: cannot read response file '@{s}'\nIf you meant a literal '@' argument, put it after '--': {s} -- @{s}\nRun '{s} --help' for usage.", .{ d.path, context.app_name, d.path, context.app_name }) catch null,
                        };
                        context.failure_message_owned = context.failure_message != null;
                    }
                    return err;
                };
            };

            // 1. Run preParse hooks
            var current_args = expanded_args;
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "preParse")) {
                    setStage(context, .pre_parse, .{ .plugin = pluginName(Plugin) });
                    current_args = try Plugin.preParse(context, current_args);
                }
            }

            // Validate all global values before dispatching any handlers.
            setStage(context, .global_options, .framework);
            const global_result = self.parseGlobalOptions(context, current_args) catch |err| {
                if (context.diagnostic != null and context.failure_origin == .framework) context.failure_category = .usage;
                return err;
            };
            context.globals_ready = true;
            defer context.allocator.free(global_result.consumed);
            defer context.allocator.free(global_result.remaining);
            current_args = global_result.remaining;

            // 3. Transform arguments
            var transform_result = zcli.TransformResult{ .args = current_args };
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "transformArgs") and transform_result.continue_processing) {
                    setStage(context, .transform, .{ .plugin = pluginName(Plugin) });
                    transform_result = try Plugin.transformArgs(context, transform_result.args);
                }
            }

            if (!transform_result.continue_processing) {
                context.invocation_completed = true;
                return; // Plugin stopped execution
            }

            current_args = transform_result.args;

            // 4. Route to command
            setStage(context, .routing, .framework);
            try self.executeCommand(context, current_args);
        }

        /// Convenient run method that handles process args, io, and environment
        pub fn run(self: *Self, allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, args: []const []const u8) !void {
            const console = console_utf8.enable();
            defer console.restore();
            self.console = console;
            var result = try self.invoke(allocator, io, environ, if (args.len > 0) args[1..] else args);
            const status = result.status;
            const unexpected: ?anyerror = switch (result.outcome) {
                .failure => |f| if (f.category == .unexpected and !f.reported and f.message == null and f.id == null) f.cause else null,
                else => null,
            };
            if (unexpected != null) zcli.failure.restoreTrace(result.outcome.failure.trace);
            result.deinit();
            console.restore();
            if (unexpected) |err| return err;
            if (status != 0) std.process.exit(status);
        }

        fn pluginName(comptime Plugin: type) []const u8 {
            return if (@hasDecl(Plugin, "plugin_id")) Plugin.plugin_id else @typeName(Plugin);
        }

        fn setStage(context: *Context, stage: zcli.failure.Stage, origin: zcli.failure.Origin) void {
            context.failure_stage = stage;
            context.failure_origin = origin;
            context.failure_category = .unexpected;
            context.diagnostic = null;
        }

        fn recordSecondary(context: *Context, err: anyerror) void {
            context.secondary_errors.append(context.allocator, err) catch {};
        }

        /// Failure callbacks may themselves call fail(). Detaching the primary
        /// message prevents that secondary report from freeing it; restoring
        /// state keeps later callbacks and fallback rendering on the primary.
        const FailureState = struct {
            category: zcli.failure.Category,
            stage: zcli.failure.Stage,
            origin: zcli.failure.Origin,
            diagnostic: ?zcli.ZcliDiagnostic,
            message: ?[]const u8,
            message_owned: bool,
            id: ?[]const u8,
            rendered: bool,
            globals_ready: bool,
            command_path: []const []const u8,
            command_arguments: []const []const u8,
            canonical_command_path: []const []const u8,
            fn capture(context: *Context) FailureState {
                const state = FailureState{
                    .category = context.failure_category,
                    .stage = context.failure_stage,
                    .origin = context.failure_origin,
                    .diagnostic = context.diagnostic,
                    .message = context.failure_message,
                    .message_owned = context.failure_message_owned,
                    .id = context.failure_id,
                    .rendered = context.failure_rendered,
                    .globals_ready = context.globals_ready,
                    .command_path = context.command_path,
                    .command_arguments = context.command_arguments,
                    .canonical_command_path = context.canonical_command_path,
                };
                context.failure_message_owned = false;
                return state;
            }
            fn restore(state: FailureState, context: *Context) void {
                if (context.failure_message_owned) context.allocator.free(context.failure_message.?);
                context.failure_category = state.category;
                context.failure_stage = state.stage;
                context.failure_origin = state.origin;
                context.diagnostic = state.diagnostic;
                context.failure_message = state.message;
                context.failure_message_owned = state.message_owned;
                context.failure_id = state.id;
                context.failure_rendered = state.rendered;
                context.globals_ready = state.globals_ready;
                context.command_path = state.command_path;
                context.command_arguments = state.command_arguments;
                context.canonical_command_path = state.canonical_command_path;
            }
        };

        fn describeWith(context: *Context, failure: zcli.Failure, comptime Describer: type) !?zcli.failure.Description {
            const state = FailureState.capture(context);
            defer state.restore(context);
            var description = (try Describer.describeFailure(context, failure)) orelse return null;
            // A successful description may borrow the callback's own fail()
            // message, which the state guard will reclaim on return.
            description.id = if (description.id) |id| context.allocator.dupe(u8, id) catch null else null;
            description.message = if (description.message) |message| context.allocator.dupe(u8, message) catch null else null;
            return description;
        }

        fn commandScopeMatches(parts: []const []const u8, expected: []const u8) bool {
            var index: usize = 0;
            for (parts, 0..) |part, i| {
                if (i != 0) {
                    if (index == expected.len or expected[index] != ' ') return false;
                    index += 1;
                }
                if (!std.mem.startsWith(u8, expected[index..], part)) return false;
                index += part.len;
            }
            return index == expected.len;
        }

        // Stage a renderer's bytes: an error must never leave half a JSON
        // document followed by the fallback human explanation.
        fn renderWith(context: *Context, failure: zcli.Failure, status: u8, comptime Renderer: type, comptime app_policy: bool) !bool {
            const state = FailureState.capture(context);
            defer state.restore(context);
            var out: std.Io.Writer.Allocating = .init(context.allocator);
            defer out.deinit();
            var errout: std.Io.Writer.Allocating = .init(context.allocator);
            defer errout.deinit();
            const stdout = context.stdout();
            const stderr = context.stderr();
            const old_out = context.stdio.stdout_override;
            const old_err = context.stdio.stderr_override;
            context.stdio.stdout_override = &out.writer;
            context.stdio.stderr_override = &errout.writer;
            defer {
                context.stdio.stdout_override = old_out;
                context.stdio.stderr_override = old_err;
            }
            const rendered = if (app_policy) blk: {
                try Renderer.renderFailure(context, failure, status);
                break :blk true;
            } else try Renderer.renderFailure(context, failure);
            if (rendered) {
                try stdout.writeAll(out.written());
                try stderr.writeAll(errout.written());
            }
            return rendered;
        }

        fn finalizeFailure(context: *Context, failure: *zcli.Failure) u8 {
            const Policy = config.failure_policy;
            var status = zcli.failure.statusFor(failure.category, config.exit_codes);
            var silent = false;
            var mapped = false;
            if (@hasDecl(Policy, "error_codes")) {
                comptime {
                    for (Policy.error_codes, 0..) |rule, i| {
                        if (rule.code == 0) @compileError("failure_policy.error_codes: failure status must be nonzero");
                        if (rule.command != null and rule.plugin != null) @compileError("failure_policy.error_codes: choose a command scope or plugin scope");
                        for (Policy.error_codes[0..i]) |other| {
                            if ((rule.command != null and other.plugin != null) or (rule.plugin != null and other.command != null)) continue;
                            if (rule.cause == other.cause and
                                (rule.command == null or other.command == null or std.mem.eql(u8, rule.command.?, other.command.?)) and
                                (rule.plugin == null or other.plugin == null or std.mem.eql(u8, rule.plugin.?, other.plugin.?)))
                                @compileError("failure_policy.error_codes: overlapping rules for " ++ @errorName(rule.cause));
                        }
                    }
                }
                if (!failure.isUsage() and failure.origin != .framework) {
                    inline for (Policy.error_codes) |rule| {
                        const plugin_matches = if (rule.plugin) |name| switch (failure.origin) {
                            .plugin => |id| std.mem.eql(u8, name, id),
                            else => false,
                        } else true;
                        const command_matches = if (rule.command) |name| failure.origin == .command and commandScopeMatches(context.canonical_command_path, name) else true;
                        if (rule.cause == failure.cause and plugin_matches and command_matches) {
                            failure.category = .application;
                            failure.id = rule.id;
                            failure.message = failure.message orelse rule.message;
                            status = rule.code;
                            mapped = true;
                            silent = rule.silent;
                            break;
                        }
                    }
                }
            }
            // Plugin descriptions enrich an error; numeric policy stays with
            // the application. First description wins, application overrides it.
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "describeFailure")) {
                    const description = if (context.pluginInitialized(Plugin)) describeWith(context, failure.*, Plugin) catch |err| blk: {
                        recordSecondary(context, err);
                        break :blk null;
                    } else null;
                    if (description) |d| {
                        failure.id = failure.id orelse d.id;
                        failure.message = failure.message orelse d.message;
                        silent = silent or d.silent;
                    }
                }
            }
            if (@hasDecl(Policy, "describeFailure")) {
                const description = describeWith(context, failure.*, Policy) catch |err| blk: {
                    recordSecondary(context, err);
                    break :blk null;
                };
                if (description) |d| {
                    failure.id = d.id orelse failure.id;
                    failure.message = d.message orelse failure.message;
                    silent = d.silent;
                }
            }
            if (failure.message != null or failure.id != null or silent) {
                if (failure.category == .unexpected) failure.category = .application;
            }
            failure.reported = silent or context.failure_rendered;
            if (!mapped) status = zcli.failure.statusFor(failure.category, config.exit_codes);
            if (!silent and !context.failure_rendered) {
                var rendered = false;
                if (@hasDecl(Policy, "renderFailure")) {
                    rendered = if (context.globals_ready) renderWith(context, failure.*, status, Policy, true) catch |err| blk: {
                        recordSecondary(context, err);
                        break :blk false;
                    } else false;
                }
                inline for (sorted_plugins) |Plugin| {
                    if (@hasDecl(Plugin, "renderFailure")) {
                        if (!rendered and context.globals_ready and context.pluginInitialized(Plugin)) rendered = renderWith(context, failure.*, status, Plugin, false) catch |err| blk: {
                            recordSecondary(context, err);
                            break :blk false;
                        };
                    }
                }
                failure.reported = rendered;
                if (!rendered) {
                    if (failure.message) |message| {
                        zcli.writeSanitized(context.stderr(), message) catch {};
                        context.stderr().writeByte('\n') catch {};
                    } else if (failure.diagnostic != null) {
                        reportParseError(context, failure.diagnostic) catch {};
                    } else if (failure.category == .unknown_command) {
                        context.stderr().writeAll("Unknown command. Use --help for usage information.\n") catch {};
                    } else if (failure.category != .unexpected) {
                        context.stderr().print("Error: {s}\n", .{@errorName(failure.cause)}) catch {};
                    }
                }
            }
            failure.id = if (failure.id) |id| context.allocator.dupe(u8, id) catch null else null;
            failure.message = if (failure.message) |message| context.allocator.dupe(u8, message) catch null else null;
            failure.diagnostic = if (failure.diagnostic) |d| zcli.failure.retain(context.allocator, d) catch null else null;
            return status;
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
                            setStage(context, .global_options, .{ .plugin = pluginName(Plugin) });
                            try Plugin.handleGlobalOption(context, global_opt.name, typed_value);
                            return;
                        }
                    }
                }
            }
        }

        /// The shared argv tokenizer's spec for the global-option namespace:
        /// exact long-name matches (no dashed aliases, no negation) and the
        /// plugins' declared shorts. `unknown_short_aborts` because this layer
        /// cannot partially consume a bundle — a non-global char before the
        /// first value-taking global leaves the whole token (and any would-be
        /// value) for the command's own option parser.
        const GlobalSpec = struct {
            pub const unknown_short_aborts = true;
            pub fn longTakesValue(name: []const u8) ?bool {
                inline for (global_options) |global_opt| {
                    if (std.mem.eql(u8, name, global_opt.name)) return global_opt.type != bool;
                }
                return null;
            }
            pub fn shortTakesValue(char: u8) ?bool {
                inline for (global_options) |global_opt| {
                    if (global_opt.short == char) return global_opt.type != bool;
                }
                return null;
            }
        };

        const PendingGlobal = struct { name: []const u8, value: []const u8, is_short: bool };
        fn queueGlobalOption(context: *Context, comptime opt: zcli.GlobalOption, value: []const u8, is_short: bool, pending: *std.ArrayList(PendingGlobal)) !void {
            _ = convertGlobalValue(opt.type, value) catch {
                context.diagnostic = .{ .OptionInvalidValue = .{
                    .option_name = opt.name,
                    .is_short = is_short,
                    .provided_value = value,
                    .expected_type = zcli.expectedTypeName(opt.type),
                } };
                return error.OptionInvalidValue;
            };
            try pending.append(context.allocator, .{ .name = opt.name, .value = value, .is_short = is_short });
        }

        pub fn parseGlobalOptions(_: *Self, context: *Context, args: []const []const u8) !zcli.GlobalOptionsResult {
            var pending: std.ArrayList(PendingGlobal) = .empty;
            defer pending.deinit(context.allocator);
            var consumed = std.ArrayList(usize).empty;
            var remaining = std.ArrayList([]const u8).empty;
            defer consumed.deinit(context.allocator);
            defer remaining.deinit(context.allocator);

            // The shared tokenizer (options/tokenizer.zig) owns the walking:
            // the `--` terminator (#501 — after it, every token flows untouched
            // into `remaining`, the `--` itself included, so the command parser
            // still sees its own terminator), the `--name=value` split (#391),
            // the short-bundle state machine, and the next-token value
            // lookahead the command parsers share. This layer only filters:
            // tokens that resolve to globals are consumed and dispatched,
            // everything else passes through verbatim.
            //
            // No resource limit is applied here, and none is missing (#741):
            // option occurrences are no longer capped anywhere, and the option
            // name-length cap is a guard for the O(name x fields) suggestion
            // scoring that only the command parser runs — this layer does exact
            // memcmp against a fixed global list and then hands the token on.
            var tok = tokenizer.Tokenizer(GlobalSpec){ .args = args };
            while (tok.next()) |token| {
                switch (token) {
                    .terminator, .positional => |item| try remaining.append(context.allocator, item.raw),
                    .long => |long| {
                        if (long.takes_value == null) {
                            // Not a global option — the command's to parse.
                            try remaining.append(context.allocator, long.raw);
                            continue;
                        }
                        try consumed.append(context.allocator, long.index);
                        inline for (global_options) |global_opt| {
                            if (std.mem.eql(u8, long.name, global_opt.name)) {
                                var value: []const u8 = "true"; // Boolean flags: presence == true
                                if (global_opt.type != bool) {
                                    if (long.attached) |v| {
                                        value = v;
                                    } else if (long.next_value) |v| {
                                        value = v;
                                        try consumed.append(context.allocator, long.index + 1);
                                    } else {
                                        context.diagnostic = .{ .OptionMissingValue = .{
                                            .option_name = global_opt.name,
                                            .is_short = false,
                                            .expected_type = zcli.expectedTypeName(global_opt.type),
                                        } };
                                        return zcli.ZcliError.OptionMissingValue;
                                    }
                                } else if (long.attached) |v| {
                                    // `--flag=x` on a boolean global errors like the
                                    // command parser's boolean-with-value path.
                                    context.diagnostic = .{ .OptionBooleanWithValue = .{
                                        .option_name = global_opt.name,
                                        .is_short = false,
                                        .provided_value = v,
                                    } };
                                    return zcli.ZcliError.OptionBooleanWithValue;
                                }

                                try queueGlobalOption(context, global_opt, value, false, &pending);
                                break;
                            }
                        }
                    },
                    .shorts => |shorts| {
                        if (!shorts.consumable) {
                            // Some char isn't a global — the token layer can't
                            // partially consume, so the whole token passes.
                            try remaining.append(context.allocator, shorts.raw);
                            continue;
                        }
                        try consumed.append(context.allocator, shorts.index);
                        var walk = shorts.walk();
                        while (walk.next()) |step| switch (step) {
                            // A consumable bundle resolved every char before the
                            // value-taker to a global.
                            .unknown => unreachable,
                            .flag => |ci| {
                                const short_char = shorts.chars[ci];
                                inline for (global_options) |global_opt| {
                                    // A .flag step means shortTakesValue returned false for this
                                    // char — the first-matching global is boolean — so first-match
                                    // dispatch of "true" is safe.
                                    if (global_opt.short == short_char) {
                                        try queueGlobalOption(context, global_opt, "true", true, &pending);
                                        break;
                                    }
                                }
                            },
                            .value => |v| {
                                const short_char = shorts.chars[v.index];
                                inline for (global_options) |global_opt| {
                                    if (global_opt.short == short_char) {
                                        const value = v.attached orelse shorts.next_value orelse {
                                            context.diagnostic = .{ .OptionMissingValue = .{
                                                .option_name = global_opt.name,
                                                .is_short = true,
                                                .expected_type = zcli.expectedTypeName(global_opt.type),
                                            } };
                                            return zcli.ZcliError.OptionMissingValue;
                                        };
                                        if (v.attached == null) {
                                            try consumed.append(context.allocator, shorts.index + 1);
                                        }
                                        try queueGlobalOption(context, global_opt, value, true, &pending);
                                        break;
                                    }
                                }
                            },
                        };
                    },
                }
            }

            // No handler observes partially parsed global options.
            for (pending.items) |item| {
                inline for (global_options) |opt| {
                    if (std.mem.eql(u8, item.name, opt.name)) {
                        try dispatchGlobalOption(context, opt, item.value, item.is_short);
                        break;
                    }
                }
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

        /// Finish a rejected command-input path through the one registry-owned
        /// diagnostic seam. Context records the diagnostic before failure callbacks;
        /// renderers control presentation without changing failure status.
        /// Secondary callback errors cannot replace the classified input error.
        fn handleInputError(context: *Context, err: anyerror, diag: ?zcli.ZcliDiagnostic) !void {
            context.diagnostic = diag;
            if (diag != null) context.failure_category = .usage;
            return err;
        }

        /// Run postParse hooks, threading each plugin's replacement ParsedArgs.
        fn runPostParseHooks(context: *Context, parsed: zcli.ParsedArgs) !zcli.ParsedArgs {
            var parsed_args = parsed;
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "postParse")) {
                    setStage(context, .parsing, .{ .plugin = pluginName(Plugin) });
                    if (try Plugin.postParse(context, parsed_args)) |new_parsed| {
                        parsed_args = new_parsed;
                    }
                }
            }
            return parsed_args;
        }

        /// Operational preparation runs only after resolved input validates.
        fn runPreExecuteHooks(context: *Context, parsed_args: zcli.ParsedArgs) !?zcli.ParsedArgs {
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "prepare")) {
                    setStage(context, .preparation, .{ .plugin = pluginName(Plugin) });
                    try Plugin.prepare(context);
                }
            }
            return parsed_args;
        }

        fn runInformationHooks(context: *Context) !bool {
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "handleInformation")) {
                    setStage(context, .information, .{ .plugin = pluginName(Plugin) });
                    if (try Plugin.handleInformation(context) == .complete) {
                        context.invocation_completed = true;
                        return true;
                    }
                }
            }
            setStage(context, .routing, .framework);
            return false;
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
                const delimiter: ?u8 = blk: {
                    if (!is_option or @TypeOf(field_meta_map) == @TypeOf(null)) break :blk null;
                    if (!@hasField(@TypeOf(field_meta_map), field.name)) break :blk null;
                    const fm = @field(field_meta_map, field.name);
                    if (!@hasField(@TypeOf(fm), "delimiter")) break :blk null;
                    break :blk fm.delimiter;
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
                    .delimiter = delimiter,
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
            context.setCommandConfig(Module);
            if (@hasDecl(Module, "meta")) {
                const meta = Module.meta;
                context.command_meta = zcli.CommandMeta{
                    .description = if (@hasField(@TypeOf(meta), "description")) meta.description else null,
                    .examples = if (@hasField(@TypeOf(meta), "examples")) meta.examples else null,
                };
            }
            context.command_module_info = comptime moduleInfoOf(Module);
        }

        /// Resolve metadata, information, typed input, configuration and
        /// validation before preparing and executing. `command_parts` is
        /// the matched command path; `remaining_args` the argv after it.
        fn executeResolvedCommand(comptime Module: type, comptime kind: CommandKind, context: *Context, command_parts: []const []const u8, canonical_parts: []const []const u8, remaining_args: []const []const u8) !void {
            @setEvalBranchQuota(comptime quota.forCommands(cmd_entries.len + plugin_command_entries.len));
            try setCommandPath(context, command_parts);
            context.canonical_command_path = canonical_parts;
            try setCommandInfo(Module, context);
            context.command_arguments = remaining_args;

            var parsed_args = zcli.ParsedArgs.init(context.allocator);
            parsed_args.positional = remaining_args;
            parsed_args = try runPostParseHooks(context, parsed_args);
            context.command_arguments = parsed_args.positional;
            if (try runInformationHooks(context)) return;

            // Metadata-only command group (no execute): route through
            // CommandNotFound so the help plugin renders the subcommand list.
            if (!@hasDecl(Module, "execute")) {
                const rest = parsed_args.positional;
                if (rest.len > 0 and std.mem.startsWith(u8, rest[0], "-")) {
                    setStage(context, .parsing, .framework);
                    var diagnostic: ?zcli.ZcliDiagnostic = null;
                    const parsed = command_parser.parseCommandLine(struct {}, struct {}, null, context.allocator, context.environ, rest, &diagnostic) catch |err|
                        return handleInputError(context, err, diagnostic);
                    parsed.deinit();
                } else if (rest.len > 0) {
                    const attempted = try context.allocator.alloc([]const u8, command_parts.len + rest.len);
                    @memcpy(attempted[0..command_parts.len], command_parts);
                    @memcpy(attempted[command_parts.len..], rest);
                    try setCommandPath(context, attempted);
                }
                setStage(context, .routing, .framework);
                context.failure_category = .unknown_command;
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
            // use the common failure pipeline like every other not-found site, so the
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
                context.failure_category = .unknown_command;
                return error.CommandNotFound;
            }

            setStage(context, .parsing, .framework);
            var input_diag: ?zcli.ZcliDiagnostic = null;
            const parse_result = command_parser.parseCommandLine(ArgsType, OptionsType, cmd_meta, context.allocator, context.environ, parsed_args.positional, &input_diag) catch |err|
                return handleInputError(context, err, input_diag);
            defer parse_result.deinit();

            const args_instance = parse_result.args;
            var options_instance = parse_result.options;

            // Resolve every lower-precedence config adapter behind one policy
            // interface. It preserves the real CLI/env bitset, shares applied
            // state across adapters, and enforces ADR-0032 around the whole loop.
            inline for (sorted_plugins) |Plugin| {
                if (@hasDecl(Plugin, "loadConfig")) {
                    setStage(context, .configuration, .{ .plugin = pluginName(Plugin) });
                    try Plugin.loadConfig(context);
                }
            }
            setStage(context, .configuration, .framework);
            const config_applied = command_validation.applyConfigAdapters(
                OptionsType,
                cmd_meta,
                sorted_plugins,
                context,
                &options_instance,
                parse_result.options_provided,
            );

            // The resolved-value policy owns the accepted order: required,
            // requires, exclusive, Args validation, then Options validation.
            setStage(context, .input, .framework);
            var stdin_requests: usize = 0;
            for (parse_result.stdin_requested) |requested| stdin_requests += @intFromBool(requested);
            if (stdin_requests == 1 and context.stdio.stdin_override == null and (std.Io.File.stdin().isTty(context.io) catch false)) {
                context.stderr().writeAll("Reading option value from stdin; send EOF to finish.\n") catch {};
                context.stderr().flush() catch {};
            }
            _ = @import("../options.zig").resolveStdin(OptionsType, &options_instance, parse_result.stdin_requested, context.allocator, context.stdin(), config.stdin_max_bytes) catch |err| {
                switch (err) {
                    error.MultipleStdinOptions => {
                        context.failure_category = .usage;
                        context.failure_message = "Only one option may read from stdin in an invocation";
                    },
                    error.StdinTooLong => {
                        context.failure_category = .usage;
                        context.failure_message = "Option input from stdin exceeds the configured byte limit";
                    },
                    error.StdinReadFailed => {
                        context.failure_category = .io;
                        context.failure_message = "Could not read option input from stdin";
                    },
                    else => {},
                }
                return err;
            };

            setStage(context, .validation, .framework);
            command_validation.validateResolved(
                context.allocator,
                ArgsType,
                OptionsType,
                cmd_meta,
                args_instance,
                options_instance,
                parse_result.options_provided,
                config_applied,
                &input_diag,
            ) catch |err| return handleInputError(context, err, input_diag);

            _ = try runPreExecuteHooks(context, parsed_args);
            setStage(context, .execution, .command);
            try Module.execute(args_instance, options_instance, context);
        }

        fn executeCommand(_: *Self, context: *Context, args: []const []const u8) !void {
            // `inline for` over every command entry to find the longest match:
            // the routing loop is unrolled once per command, so the budget
            // scales with the registry (#730).
            @setEvalBranchQuota(comptime quota.forCommands(cmd_entries.len + plugin_command_entries.len));

            // A leading bare `--` is the conventional "nothing after this is an
            // option" terminator, not a command name (#743). `parseGlobalOptions`
            // deliberately forwards it (#501) so a command's own parser still
            // sees its own terminator, but nothing consumed it at the routing
            // layer, so `myapp -- list` reported "Unknown command '-- list'" and
            // the `myapp -- "$@"` wrapper idiom failed unconditionally.
            //
            // Only the *leading* one is a routing artifact: once a command name
            // has been matched, everything after it is passed through untouched,
            // so `myapp cmd -- -x` still terminates `cmd`'s options. A second
            // `--` (`myapp -- -- x`) is likewise left alone.
            //
            // The root-index fallback below is deliberately handed the untrimmed
            // argv: the root command shares the top-level option namespace, so
            // `myapp -- -x` must reach its parser with the terminator intact for
            // `-x` to land as a positional.
            const route_args = if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args[1..] else args;

            // The root group's index (a top-level index.zig) registers at the
            // empty path (ADR-0029). It is deliberately NOT matched by the
            // longest-path loop below — an empty path matches any argv, which
            // would shadow plugin commands like `help`. It is the fallback of
            // last resort instead: after named commands and plugin commands.
            const root_index_exists = comptime blk: {
                for (cmd_entries) |cmd| {
                    if (cmd.path.len == 0) break :blk true;
                }
                break :blk false;
            };

            // No command given and no root index to run it: run the hooks (the
            // help plugin answers a bare --help here), then route through
            // CommandNotFound. With a root index, bare invocation falls
            // through to it below.
            if (!root_index_exists and route_args.len == 0) {
                _ = try runPostParseHooks(context, zcli.ParsedArgs.init(context.allocator));
                if (try runInformationHooks(context)) return;
                context.failure_category = .unknown_command;

                return error.CommandNotFound;
            }

            // Regular commands, longest path first so the longest match wins.
            const sorted_commands = comptime sortedByPathLengthDesc(cmd_entries);
            inline for (sorted_commands) |cmd| {
                if (cmd.path.len > 0 and cmd.path.len <= route_args.len) {
                    var parts_match = true;
                    for (cmd.path, 0..) |part, i| {
                        if (!std.mem.eql(u8, part, route_args[i])) {
                            parts_match = false;
                            break;
                        }
                    }
                    if (parts_match) {
                        return executeResolvedCommand(cmd.module, .regular, context, cmd.path, cmd.canonical_path orelse cmd.path, route_args[cmd.path.len..]);
                    }
                }
            }

            // Plugin commands: find the longest matching path, then execute it.
            //
            // Only the dispatch below has to be unrolled — each arm passes a
            // different comptime `module` type to `executeResolvedCommand`.
            // The search does not: it reads nothing but `path`, so it runs as
            // an ordinary runtime loop over a comptime-built table of paths
            // (a plain `[]const []const u8` array, no `type` field, hence
            // runtime-representable). That keeps one unrolled pass over the
            // entries instead of two.
            const plugin_paths = comptime blk: {
                // Not `paths` — that name is the module-level `paths.zig`
                // import at the top of this file.
                var entry_paths: [plugin_command_entries.len][]const []const u8 = undefined;
                for (plugin_command_entries, 0..) |entry, i| entry_paths[i] = entry.path;
                break :blk entry_paths;
            };
            var best_match_idx: ?usize = null;
            var best_match_len: usize = 0;
            for (plugin_paths, 0..) |path, idx| {
                if (route_args.len >= path.len and path.len > best_match_len) {
                    var matches = true;
                    for (path, 0..) |path_part, i| {
                        if (!std.mem.eql(u8, path_part, route_args[i])) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) {
                        best_match_idx = idx;
                        best_match_len = path.len;
                    }
                }
            }
            if (best_match_idx) |match_idx| {
                inline for (plugin_command_entries, 0..) |plugin_cmd, idx| {
                    if (idx == match_idx) {
                        return executeResolvedCommand(plugin_cmd.module, .plugin, context, plugin_cmd.path, plugin_cmd.canonical_path orelse plugin_cmd.path, route_args[plugin_cmd.path.len..]);
                    }
                }
            }

            // Root index fallback: the whole argv — empty, option-first, or
            // positionals — belongs to the root command. Note the argv is NOT
            // trimmed (the root's path is empty, so it consumed no words).
            // executeResolvedCommand's mistyped-subcommand gate still applies:
            // a root index whose Args declares no positionals treats a stray
            // word as CommandNotFound, preserving "did you mean" suggestions.
            if (root_index_exists) {
                inline for (cmd_entries) |cmd| {
                    if (comptime cmd.path.len == 0) {
                        return executeResolvedCommand(cmd.module, .regular, context, cmd.path, cmd.canonical_path orelse cmd.path, args);
                    }
                }
            }

            // Nothing matched. Record the attempted path and route through
            // CommandNotFound. The not-found plugin renders the styled block
            // (suggestions + available commands) — the single source of truth.
            // Renderers may explain the failure; the invocation remains nonzero.
            // No bare fallback line here: it would double-report over that block.
            // Pure namespace groups have no module/index.zig. Their flags
            // still have usage semantics, just like a metadata-only group.
            var group_len: usize = 0;
            for (context.available_commands) |path| {
                var matched: usize = 0;
                while (matched < route_args.len and matched + 1 < path.len and std.mem.eql(u8, path[matched], route_args[matched])) : (matched += 1) {}
                group_len = @max(group_len, matched);
            }
            const group_flags = group_len > 0 and group_len < route_args.len and std.mem.startsWith(u8, route_args[group_len], "-");
            context.command_arguments = if (group_len > 0) route_args[group_len..] else route_args;
            try setCommandPath(context, if (group_flags) route_args[0..group_len] else route_args);
            if (try runInformationHooks(context)) return;
            if (group_flags) {
                setStage(context, .parsing, .framework);
                var diagnostic: ?zcli.ZcliDiagnostic = null;
                const parsed = command_parser.parseCommandLine(struct {}, struct {}, null, context.allocator, context.environ, context.command_arguments, &diagnostic) catch |err|
                    return handleInputError(context, err, diagnostic);
                parsed.deinit();
                // A terminator alone adds no command input.
                context.command_arguments = &.{};
                if (try runInformationHooks(context)) return;
            }
            setStage(context, .routing, .framework);
            context.failure_category = .unknown_command;
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
