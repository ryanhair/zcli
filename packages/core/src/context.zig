//! The command execution context — single source of truth for the interface
//! commands and plugins receive.
//!
//! `ContextFor(plugins)` computes the concrete context type: the shared
//! interface (streams, app metadata, command introspection, diagnostics) plus
//! one type-safe field per plugin `ContextData` under `.plugins`. The registry
//! instantiates it with the app's plugin list and re-exports it as its
//! `Context`; `zcli.Context` is the plugin-less instantiation for library code
//! and tests; `zcli.TestContext` is an alias of `ContextFor` for tests that
//! need `context.plugins.<plugin_id>` fields.

const std = @import("std");
const zcli = @import("zcli.zig");
const identifier = @import("identifier.zig");

/// Field name in `context.plugins` for a plugin's ContextData: its
/// `plugin_id` with every non-identifier character replaced by '_'.
/// Plugins with ContextData MUST declare `pub const plugin_id = "unique_name";`
pub fn pluginFieldName(comptime Plugin: type) [:0]const u8 {
    comptime {
        if (!@hasDecl(Plugin, "plugin_id")) {
            @compileError("Plugins with ContextData must declare 'pub const plugin_id'. " ++
                "Add: pub const plugin_id = \"my_plugin\";");
        }

        const id: []const u8 = Plugin.plugin_id;
        var result: [256]u8 = undefined;
        var result_idx: usize = 0;
        for (id) |c| {
            if (result_idx >= result.len - 1) break;
            // Shared rule (identifier.zig) — build-time codegen sanitizes
            // plugin/module names with the same function.
            result[result_idx] = identifier.sanitizeChar(c);
            result_idx += 1;
        }
        result[result_idx] = 0;
        return result[0..result_idx :0];
    }
}

/// Struct type with one field per plugin that declares a ContextData type,
/// each default-initialized from the ContextData's own field defaults.
fn PluginDataType(comptime plugins: []const type) type {
    comptime {
        var field_count: usize = 0;
        for (plugins) |Plugin| {
            if (@hasDecl(Plugin, "ContextData")) {
                field_count += 1;
            }
        }

        if (field_count == 0) {
            return struct {};
        }

        var field_names: [field_count][]const u8 = undefined;
        var field_types: [field_count]type = undefined;
        var field_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;
        var idx: usize = 0;

        for (plugins) |Plugin| {
            if (@hasDecl(Plugin, "ContextData")) {
                const DataType = Plugin.ContextData;
                const default_val: DataType = .{};

                field_names[idx] = pluginFieldName(Plugin);
                field_types[idx] = DataType;
                field_attrs[idx] = .{ .default_value_ptr = @ptrCast(&default_val) };
                idx += 1;
            }
        }

        return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    }
}

/// Compute the context type for a set of plugins.
pub fn ContextFor(comptime plugins: []const type) type {
    return struct {
        allocator: std.mem.Allocator,
        /// The framework's `std.Io` instance — the entry point for all explicit I/O.
        io: std.Io,
        /// Standard-stream holder backing `stdout()`/`stderr()`/`stdin()`. Internal:
        /// command and plugin code should use those accessors and `io`, not this.
        stdio: *zcli.Stdio,
        environ: *const std.process.Environ.Map,
        theme: zcli.theme.ThemeContext = .{ .caps = .{ .capability = .true_color, .is_tty = true, .color_enabled = true } },

        // App metadata; the registry fills these from its Config.
        app_name: []const u8 = "app",
        app_version: []const u8 = "unknown",
        app_description: []const u8 = "",

        // Command execution context
        available_commands: []const []const []const u8 = &.{},
        command_path: []const []const u8 = &.{},

        /// Structured detail for the most recent parse/routing error, set by
        /// the framework just before onError hooks run. Payload slices point
        /// into argv and comptime type names — valid for the whole execution.
        diagnostic: ?zcli.ZcliDiagnostic = null,
        command_meta: ?zcli.CommandMeta = null,
        command_module_info: ?zcli.CommandModuleInfo = null,

        // Plugin introspection
        plugin_command_info: []const zcli.CommandInfo = &.{},
        global_options: []const zcli.OptionInfo = &.{},

        // Type-safe plugin data - each plugin's ContextData is a field
        plugins: PluginDataType(plugins) = .{},

        const Self = @This();

        /// Initialize a new Context with the provided io, standard streams, and
        /// environment (terminal capabilities are detected from `env`; the
        /// theme comes from the app's root `zcli_theme` declaration).
        pub fn init(allocator: std.mem.Allocator, io: std.Io, stdio: *zcli.Stdio, env: *const std.process.Environ.Map) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .stdio = stdio,
                .environ = env,
                .theme = .{ .theme = zcli.appTheme(), .caps = zcli.theme.Capabilities.init(env, io) },
            };
        }

        /// Clean up context resources
        pub fn deinit(self: *Self) void {
            // No per-field frees here: everything the framework attaches to the
            // context (command_path, FieldInfo arrays, diagnostics) is allocated
            // from context.allocator — the arena-per-command — and reclaimed
            // wholesale by arena.deinit() (ADR-0001). environ is owned by the
            // caller.

            // Call plugin deinit hooks if they exist
            inline for (plugins) |Plugin| {
                if (@hasDecl(Plugin, "ContextData") and @hasDecl(Plugin, "deinitContextData")) {
                    const field_name = comptime pluginFieldName(Plugin);
                    Plugin.deinitContextData(&@field(self.plugins, field_name), self.allocator);
                }
            }
        }

        // I/O convenience methods
        pub fn stdout(self: *Self) *std.Io.Writer {
            return self.stdio.stdout();
        }

        pub fn stderr(self: *Self) *std.Io.Writer {
            return self.stdio.stderr();
        }

        pub fn stdin(self: *Self) *std.Io.Reader {
            return self.stdio.stdin();
        }

        /// A `Prompts` instance pre-wired to this command's environment:
        /// stdout, stdin, the arena-per-command allocator, and the app theme.
        /// Override a field before use if you need to (e.g. a scratch allocator).
        pub fn prompts(self: *Self) zcli.Prompts {
            return .{
                .writer = self.stdout(),
                .reader = self.stdin(),
                .allocator = self.allocator,
                .theme = self.theme,
            };
        }

        /// A `Progress` instance pre-wired to this command's environment:
        /// stdout, the framework `io`, the arena-per-command allocator, and the
        /// app theme. Call `.spinner(...)`, `.progressBar(...)`, or
        /// `.multiBar(...)` on the result.
        pub fn progress(self: *Self) zcli.Progress {
            return .{
                .writer = self.stdout(),
                .io = self.io,
                .allocator = self.allocator,
                .theme = self.theme,
            };
        }

        /// A markdown `Formatter` pre-wired to stdout, the detected terminal
        /// capability, and the app's palette (baked at comptime). Call
        /// `.write(fmt, args)` / `.print(alloc, fmt, args)` on the result.
        pub fn markdown(self: *Self) zcli.markdown.Formatter(zcli.appTheme().palette) {
            return .{ .writer = self.stdout(), .capability = self.theme.capability() };
        }

        /// Get command description by path (for plugins)
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
        pub fn getAvailableCommandInfo(self: *Self) []const zcli.CommandInfo {
            return self.plugin_command_info;
        }

        /// Get all global options (for completions)
        pub fn getGlobalOptions(self: *Self) []const zcli.OptionInfo {
            return self.global_options;
        }

        /// Exit the process with the given code, flushing buffered output
        /// first — std.process.exit alone silently drops anything printed
        /// just before the call.
        pub fn exit(self: *Self, code: u8) noreturn {
            self.stdio.flush();
            std.process.exit(code);
        }

        /// Fail the command with a friendly, user-facing message: print `fmt`
        /// (formatted with `args`) to stderr, then return `error.CommandFailed`.
        /// zcli reports that as a clean non-zero exit — just your message, no
        /// `error: CommandFailed` line and no stack trace, in every build mode.
        ///
        /// Use it for expected failures a user should see ("no such note"), and
        /// `return` it directly: `return context.fail("no note: {s}", .{name});`.
        /// For an *unexpected* failure, return a plain error instead — its name
        /// and Debug-only trace are what you want while debugging.
        pub fn fail(self: *Self, comptime fmt: []const u8, args: anytype) error{CommandFailed} {
            self.stderr().print(fmt ++ "\n", args) catch {};
            return error.CommandFailed;
        }
    };
}

test "context accessors type-check" {
    // Core itself never calls prompts()/progress()/markdown() — Zig skips
    // unreferenced methods, so force analysis here to catch a broken accessor
    // signature (e.g. a stale bundle field) at build time rather than only when
    // an example happens to use it.
    std.testing.refAllDecls(ContextFor(&.{}));
}
