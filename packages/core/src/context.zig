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

/// Field name in `context.plugins` for a plugin's ContextData: its `plugin_id`
/// verbatim. `plugin_id` is required to be a valid Zig identifier — enforced at
/// registration by plugin_types.validatePlugin — so there is nothing to rewrite
/// here. Plugins with ContextData MUST declare `pub const plugin_id = "unique_name";`
pub fn pluginFieldName(comptime Plugin: type) [:0]const u8 {
    comptime {
        // Backstop for direct ContextFor/TestContext use that bypasses plugin
        // registration (see plugin_types.requirePluginId for the message).
        zcli.plugin_types.requirePluginId(Plugin);

        const id: []const u8 = Plugin.plugin_id;
        var result: [id.len + 1]u8 = undefined;
        for (id, 0..) |c, i| result[i] = c;
        result[id.len] = 0;
        return result[0..id.len :0];
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

        /// Run each plugin's `initContextData` hook, in registration order, so a
        /// plugin can capture borrowed references off this context (allocator,
        /// io, app_name, environ, …) into its ContextData once per invocation —
        /// letting its `context.plugins.<id>` methods serve calls without the
        /// command re-threading `context`. Runs before any lifecycle hook.
        ///
        /// The dispatcher and test harness build the full Context struct first,
        /// then call this — `Context.init` alone lacks app metadata, so init
        /// hooks that capture it must not run there.
        ///
        /// Cleanup on failure is the caller's `defer context.deinit()`, which
        /// every call site registers before calling this: the deferred
        /// `deinit` runs all `deinitContextData` hooks, so they must already be
        /// safe on data whose `initContextData` never ran (fields sit at their
        /// defaults). Not doing rollback here is what keeps a succeeded plugin's
        /// `deinitContextData` from running twice.
        pub fn initPluginData(self: *Self) !void {
            inline for (plugins) |Plugin| {
                if (@hasDecl(Plugin, "ContextData") and @hasDecl(Plugin, "initContextData")) {
                    const field_name = comptime pluginFieldName(Plugin);
                    try Plugin.initContextData(&@field(self.plugins, field_name), self);
                }
            }
        }

        /// Clean up context resources
        pub fn deinit(self: *Self) void {
            // No per-field frees here: everything the framework attaches to the
            // context (command_path, FieldInfo arrays, diagnostics) is allocated
            // from context.allocator — the arena-per-command — and reclaimed
            // wholesale by arena.deinit() (ADR-0001). environ is owned by the
            // caller.

            // Call plugin deinit hooks if they exist. Runs for every plugin that
            // declares one regardless of whether its initContextData ran (or
            // succeeded), so deinit hooks must be safe on default-valued data.
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

        /// A `ui.App` pre-wired to this command's environment: stdout, the
        /// arena-per-command allocator, the detected terminal capability, and
        /// unicode/TTY detection. The entry point for CLI/TUI output —
        /// `app.emit()` for static lines that flow into scrollback,
        /// `app.frame()` for the diffed live region below. `defer app.deinit()`
        /// (idempotent) restores the terminal and persists the final frame.
        ///
        /// For an opt-in alt-screen TUI, use `uiFullScreen` instead.
        /// A hybrid (shared-screen) `ui.App` pre-wired to this command's
        /// environment — the substrate every prompt and progress indicator runs
        /// on. It hides the cursor and rides the caller's raw mode, so a panic
        /// mid-frame must be able to restore the terminal. Requires a panic
        /// handler in your root source file — enforced at compile time:
        ///
        ///     pub const panic = zcli.ui.panic;
        pub fn ui(self: *Self, options: zcli.ui.App.SessionOptions) !zcli.ui.App {
            return zcli.ui.App.init(self.allocator, self.stdout(), .{
                .capability = self.theme.capability(),
                .unicode = zcli.ui.unicodeSupported(self.environ),
                .interactive = self.theme.caps.is_tty,
                .sync = options.sync,
            });
        }

        /// A full-screen (alt-screen) `ui.App` pre-wired to this command's
        /// environment, with stdin wired for input (ADR-0015): the App takes the
        /// screen over, owns raw mode, and reads input through `app.nextEvent()`.
        ///
        /// Requires a panic handler in your root source file so a panic can't
        /// strand the terminal in the alt-screen — enforced at compile time:
        ///
        ///     pub const panic = zcli.ui.panic;
        pub fn uiFullScreen(self: *Self, options: zcli.ui.App.SessionOptions) !zcli.ui.App {
            return zcli.ui.App.initFullScreen(self.allocator, self.stdout(), .{
                .capability = self.theme.capability(),
                .unicode = zcli.ui.unicodeSupported(self.environ),
                .interactive = self.theme.caps.is_tty,
                .sync = options.sync,
                .stdin = self.stdin(),
                .mouse = options.mouse,
                .focus = options.focus,
                .paste = options.paste,
                .paste_max = options.paste_max,
            });
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

test "initPluginData runs declared init hook and mutates ContextData" {
    const Plugin = struct {
        pub const plugin_id = "cap";
        pub const ContextData = struct {
            app_name: ?[]const u8 = null,
        };
        pub fn initContextData(data: *ContextData, context: anytype) !void {
            data.app_name = context.app_name;
        }
    };

    const Ctx = ContextFor(&.{Plugin});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const env = std.process.Environ.Map.init(std.testing.allocator);
    var ctx = Ctx{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stdio = &stdio,
        .environ = &env,
        .app_name = "myapp",
    };
    defer ctx.deinit();

    try std.testing.expect(ctx.plugins.cap.app_name == null);
    try ctx.initPluginData();
    try std.testing.expectEqualStrings("myapp", ctx.plugins.cap.app_name.?);
}

test "init failure propagates and the deferred deinit still cleans up once" {
    // A's init succeeds; B's fails. initPluginData surfaces the error and does
    // NOT itself run cleanup — the caller's deinit does, exactly once, and must
    // be safe on B's data whose init never completed.
    const state = struct {
        var a_deinit_count: usize = 0;
    };
    state.a_deinit_count = 0;

    const PluginA = struct {
        pub const plugin_id = "a";
        pub const ContextData = struct { inited: bool = false };
        pub fn initContextData(data: *ContextData, _: anytype) !void {
            data.inited = true;
        }
        pub fn deinitContextData(_: *ContextData, _: std.mem.Allocator) void {
            state.a_deinit_count += 1;
        }
    };
    const PluginB = struct {
        pub const plugin_id = "b";
        pub const ContextData = struct {};
        pub fn initContextData(_: *ContextData, _: anytype) !void {
            return error.InitFailed;
        }
    };

    const Ctx = ContextFor(&.{ PluginA, PluginB });
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const env = std.process.Environ.Map.init(std.testing.allocator);
    var ctx = Ctx{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stdio = &stdio,
        .environ = &env,
    };

    try std.testing.expectError(error.InitFailed, ctx.initPluginData());
    try std.testing.expectEqual(@as(usize, 0), state.a_deinit_count); // no in-helper rollback
    ctx.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.a_deinit_count); // caller cleans up once
}
