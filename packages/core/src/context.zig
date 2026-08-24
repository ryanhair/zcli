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
const console_utf8 = @import("console_utf8.zig");

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

        /// Console code pages captured by the registry's `run()` when it
        /// switched the Windows console to UTF-8 for this invocation. `exit()`
        /// restores them before `std.process.exit` — which skips the deferred
        /// restore `run()` relies on — so a command that exits early doesn't
        /// leak CP_UTF8 into the parent shell. Zero-valued (a no-op restore)
        /// for direct `execute()`/`executeWithStdio` callers and on POSIX.
        console: console_utf8.State = .{},

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
        ///
        /// **Why stdout, when `progress()` deliberately uses stderr** (#790).
        /// The two are different kinds of output and the split is intentional:
        ///
        ///   * `prompts()` and `ui()` are the command's *foreground* output —
        ///     the thing the user is here for. `app.emit()` lines are results,
        ///     and a prompt's question plus its echoed answer is the interactive
        ///     form of the same conversation. Commands narrate around their
        ///     prompts with plain `context.stdout()` writes (`zcli init` and the
        ///     `zcli add` wizard both do), and that narration only stays in
        ///     order with the questions because both go through one writer. Move
        ///     prompts to stderr and a buffered stdout heading surfaces *after*
        ///     the self-flushing prompt it was introducing — a visible ordering
        ///     bug traded for a redirection one.
        ///   * `progress()` is *out-of-band status*, written from a background
        ///     task concurrently with whatever the command is producing. It is
        ///     never part of the result, so a redirected stdout must not receive
        ///     it; a separate stream is the only way to keep cursor escapes out
        ///     of piped data.
        ///
        /// The known cost is that `myapp interactive | tee out.txt` captures
        /// prompt text and its escapes. A command that must keep stdout pure —
        /// one whose result is machine-read — can retarget its own prompts,
        /// since this returns a plain value: `var p = context.prompts();
        /// p.writer = context.stderr();`. That is the right granularity for the
        /// decision: it depends on what the individual command emits, which the
        /// framework cannot know.
        pub fn prompts(self: *Self) zcli.Prompts {
            return .{
                .writer = self.stdout(),
                .reader = self.stdin(),
                .allocator = self.allocator,
                .theme = self.theme,
            };
        }

        /// A `Progress` instance pre-wired to this command's environment:
        /// stderr, the framework `io`, the arena-per-command allocator, and the
        /// app theme. Progress renders to stderr (not stdout) by convention, so
        /// it survives `myapp | tee` / stdout redirection while keeping piped
        /// stdout clean. Call `.spinner(...)`, `.progressBar(...)`, or
        /// `.multiBar(...)` on the result.
        ///
        /// This is the deliberate counterpart to `prompts()`/`ui()` living on
        /// stdout — see the note on `prompts()` for why out-of-band status and
        /// foreground conversation are split rather than aligned (#790).
        pub fn progress(self: *Self) zcli.Progress {
            return .{
                .writer = self.stderr(),
                .io = self.io,
                .allocator = self.allocator,
                .theme = self.theme,
            };
        }

        /// A `process.Runner` pre-wired to this command's environment: the
        /// arena-per-command allocator, the framework `io`, and — the part that
        /// matters — the threaded `environ`. `Runner` has no constructor that
        /// omits the environment map, so going through the context is what makes
        /// an ambient `getenv` in a subprocess call impossible to write by
        /// accident rather than merely discouraged.
        pub fn process(self: *Self) zcli.process.Runner {
            return .{
                .allocator = self.allocator,
                .io = self.io,
                .environ = self.environ,
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
        /// Stdout, not stderr, because `app.emit()` lines *are* the command's
        /// result — `myapp list | grep` has to receive them. See the note on
        /// `prompts()` for the full foreground-vs-out-of-band split (#790).
        ///
        /// For an opt-in alt-screen TUI, use `uiFullScreen` instead.
        /// A hybrid (shared-screen) `ui.App` pre-wired to this command's
        /// environment — the substrate every prompt and progress indicator runs
        /// on. It hides the cursor and rides the caller's raw mode, so a panic
        /// mid-frame must be able to restore the terminal. Requires the two
        /// crash hooks in your root source file — enforced at compile time
        /// (segfaults go to `root.debug.handleSegfault`, not `root.panic`):
        ///
        ///     pub const panic = zcli.ui.panic;
        ///     pub const debug = zcli.ui.debug;
        pub fn ui(self: *Self, options: zcli.ui.App.SessionOptions) !zcli.ui.App {
            return zcli.ui.App.init(self.allocator, self.stdout(), .{
                .capability = self.theme.capability(),
                .unicode = zcli.ui.unicodeSupported(self.environ),
                .interactive = self.theme.caps.is_tty,
                .session = options,
            });
        }

        /// A full-screen (alt-screen) `ui.App` pre-wired to this command's
        /// environment, with stdin wired for input (ADR-0015): the App takes the
        /// screen over, owns raw mode, and reads input through `app.nextEvent()`.
        ///
        /// Requires the two crash hooks in your root source file so neither a
        /// panic nor a segfault can strand the terminal in the alt-screen —
        /// enforced at compile time:
        ///
        ///     pub const panic = zcli.ui.panic;
        ///     pub const debug = zcli.ui.debug;
        pub fn uiFullScreen(self: *Self, options: zcli.ui.App.SessionOptions) !zcli.ui.App {
            return zcli.ui.App.initFullScreen(self.allocator, self.stdout(), .{
                .capability = self.theme.capability(),
                .unicode = zcli.ui.unicodeSupported(self.environ),
                .interactive = self.theme.caps.is_tty,
                .stdin = self.stdin(),
                .session = options,
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
        ///
        /// `std.process.exit` runs no `defer`, so every unwind `run()` and the
        /// command itself would have performed has to be replayed here by hand.
        /// Missing one of them is what made this the framework's only
        /// `noreturn` hole (#732): the *error* path is fine, because
        /// `context.fail()` returns an error and defers unwind normally.
        pub fn exit(self: *Self, code: u8) noreturn {
            self.stdio.flush();
            // Restore process-global terminal state: raw mode, the alternate
            // screen, a hidden cursor. A `uiFullScreen` TUI (or a spinner) that
            // validates input and exits from inside its session never runs
            // `defer app.deinit()`, so without this the shell comes back with
            // no echo, no line editing and an invisible cursor — blind `reset`
            // is the only recovery. Replays whatever the session armed; a no-op
            // when nothing did. After the flush, so buffered output still lands
            // on the screen it was drawn for (#732).
            zcli.ui.guard.restore();
            // Output integrity has the last word on a *success* exit, exactly
            // as it does on run()'s normal return: a closed downstream pipe
            // becomes 141, any other lost write becomes a diagnosed general
            // failure. Bypassing this is why `context.exit(0)` after a broken
            // pipe used to report success (#732/#731). Reported before the
            // console restore below so the diagnostic is written under the same
            // code page the rest of this run's output used.
            const write_err = self.stdio.writeError();
            if (code == 0) if (write_err) |e| self.stdio.reportWriteFailure(e);
            // Restore the Windows console code pages `run()` switched to UTF-8;
            // std.process.exit skips run()'s deferred restore, so without this
            // an early exit leaks CP_UTF8 into the parent shell. No-op on POSIX
            // and for callers that never enabled it.
            self.console.restore();
            std.process.exit(exitStatus(code, write_err));
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
            // Render first, sanitize on the way out (#734). `args` are routinely
            // user-controlled — a rejected `--config` path, a version string
            // echoed back *because* it contained a byte outside [A-Za-z0-9._-],
            // a set that includes ESC — and printing them raw hands the terminal
            // an OSC 52 clipboard write or a window-title rewrite. This is the
            // failure API the framework documents for command authors, so
            // sanitizing here fixes every downstream CLI at once instead of
            // asking each author to remember. Same sanitize-the-whole-rendered-
            // string boundary reportParseError uses: framework prose can't
            // contain control bytes, so nothing is lost by covering all of it.
            var rendered = std.Io.Writer.Allocating.init(self.allocator);
            defer rendered.deinit();
            // The message is arena-allocated and the arena is this command's;
            // on OOM the message is dropped rather than printed unsanitized —
            // falling back to a raw write would reopen the hole this closes.
            if (rendered.writer.print(fmt ++ "\n", args)) |_| {
                zcli.writeSanitized(self.stderr(), rendered.written()) catch {};
            } else |_| {}
            return error.CommandFailed;
        }
    };
}

/// The status `Context.exit(code)` actually takes, given what the run's
/// stdout/stderr writers recorded. Split out because `exit` is `noreturn` and
/// so untestable in-process.
///
/// A non-zero `code` is the command's own classification and wins — the same
/// rule `run()` follows when it lets a reported CLI error outrank a write
/// failure (#740). The process is already reporting failure, so no loss can
/// pass as success. Only `exit(0)` — a claim that everything worked — is
/// overridden, and then through the shared `statusForWriteError` mapping so
/// an early exit and a normal return can never disagree (#732).
///
/// That makes the two ways a command reports its own failure agree exactly:
/// with a closed downstream pipe, `context.exit(1)` and `return
/// context.fail(...)` both exit 1, because in both the command classified the
/// failure itself and its classification is the answer. Only an *unclassified*
/// failure lets the pipe decide (141).
fn exitStatus(code: u8, write_err: ?std.Io.File.Writer.Error) u8 {
    if (code != 0) return code;
    const e = write_err orelse return 0;
    return zcli.statusForWriteError(e);
}

test "exitStatus: a success exit can't outrank lost output" {
    // Nothing failed: the caller's code stands.
    try std.testing.expectEqual(@as(u8, 0), exitStatus(0, null));
    try std.testing.expectEqual(@as(u8, 3), exitStatus(3, null));

    // context.exit(0) after a broken pipe is the case #732 names: the framework
    // documents 141 for `yourcli cmd | head`, and bypassing run() must not
    // quietly turn that into success.
    try std.testing.expectEqual(@as(u8, 141), exitStatus(0, error.BrokenPipe));
    // Any other lost write is a general failure, never 0.
    try std.testing.expectEqual(@as(u8, 1), exitStatus(0, error.NoSpaceLeft));
    try std.testing.expectEqual(@as(u8, 1), exitStatus(0, error.NotOpenForWriting));

    // A command that already decided it failed keeps its own status; it is
    // not reporting success, so there is nothing to correct.
    try std.testing.expectEqual(@as(u8, 2), exitStatus(2, error.NoSpaceLeft));
    try std.testing.expectEqual(@as(u8, 7), exitStatus(7, error.BrokenPipe));

    // The sibling-API agreement: with a broken pipe, `context.exit(1)` is 1 —
    // and so is `return context.fail(...)`, because CommandFailed is a
    // classified error and run() gives it exitCodeForReportedError's 1 rather
    // than 141. Same physical situation, same status, whichever API the author
    // reached for. The other half of the pairing is pinned next to
    // `exitCodeForReportedError` in registry/compiled.zig.
    try std.testing.expectEqual(@as(u8, 1), exitStatus(1, error.BrokenPipe));
}

test "context accessors type-check" {
    // Core itself never calls prompts()/progress()/markdown() — Zig skips
    // unreferenced methods, so force analysis here to catch a broken accessor
    // signature (e.g. a stale bundle field) at build time rather than only when
    // an example happens to use it.
    std.testing.refAllDecls(ContextFor(&.{}));
}

test "Context carries the console State so exit() can restore code pages" {
    // Regression for #438: context.exit must restore the Windows console code
    // pages run() switched to UTF-8. exit() is `noreturn` and restore() is a
    // no-op off Windows, so the leak itself can't be observed in-process here;
    // this instead locks in the wiring — that Context has a `console` field the
    // registry threads through and exit() reads — so the restore call can't be
    // silently dropped again. The behavioral Windows path is exercised by CI.
    const Ctx = ContextFor(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    const env = std.process.Environ.Map.init(std.testing.allocator);

    // A Context built with captured code pages must retain them verbatim.
    const ctx = Ctx{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stdio = &stdio,
        .environ = &env,
        .console = .{ .prev_in = 437, .prev_out = 437 },
    };
    try std.testing.expectEqual(@as(console_utf8.UINT, 437), ctx.console.prev_in);
    try std.testing.expectEqual(@as(console_utf8.UINT, 437), ctx.console.prev_out);

    // The default (no run(), or POSIX) is an empty, safe-to-restore State.
    var plain = Ctx{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stdio = &stdio,
        .environ = &env,
    };
    try std.testing.expectEqual(@as(console_utf8.UINT, 0), plain.console.prev_in);
    plain.console.restore(); // no-op, must not crash
}

test "exit() restores the terminal, not just the Windows code pages" {
    // Regression for #732: `grep -n guard packages/core/src/context.zig`
    // returned nothing — a `uiFullScreen` TUI that called context.exit() died
    // inside the alt-screen with raw mode on and the cursor hidden, because
    // std.process.exit runs no `defer` and so skips `app.deinit()`. exit() is
    // `noreturn` and the state it repairs is process-global terminal state, so
    // — like the #438 test above — this locks in the wiring rather than the
    // effect: the guard must be reachable from here and safe to replay
    // unconditionally.
    //
    // The behavioral proof is a PTY capture of a full-screen command that ends
    // in `context.exit(3)`, recorded here so the expectation is reproducible
    // (`script -q out.raw myapp tui-cmd`, then `cat -v out.raw`):
    //
    //     before:  ^[[?1049h ^[[?25l ^M
    //     after:   ^[[?1049h ^[[?25l ^M ^[[?25h ^[[?1049l
    //
    // i.e. enter alt-screen + hide cursor, and now also show cursor + leave
    // alt-screen on the way out. Without the trailing pair the user's shell
    // comes back inside the alt-screen with echo off.
    try std.testing.expect(@TypeOf(zcli.ui.guard.restore) == fn () void);
    // Never armed (no session took the terminal over): a no-op, must not
    // crash — exit() calls it on every path, TUI or not.
    zcli.ui.guard.restore();
}

test "fail() sanitizes its rendered message" {
    // Regression for #734: `fail` is the failure API the framework documents
    // for command authors, and it printed `args` raw. Those args are routinely
    // user-controlled — the upgrade plugin echoes back a version string
    // *because* it contained a byte outside [A-Za-z0-9._-], a set that
    // includes ESC — so an OSC 52 clipboard write or a window-title rewrite
    // rode straight through to the operator's terminal.
    const Ctx = ContextFor(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var err_aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer err_aw.deinit();
    stdio.stderr_override = &err_aw.writer;
    const env = std.process.Environ.Map.init(std.testing.allocator);

    var ctx = Ctx{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stdio = &stdio,
        .environ = &env,
    };

    // An OSC 52 payload smuggled through a command's own failure message.
    try std.testing.expectEqual(error.CommandFailed, ctx.fail("invalid version '{s}'", .{"\x1b]52;c;cHduZWQ=\x07"}));
    const text = err_aw.written();
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x07) == null);
    // The framework prose and the inert part of the value still read normally,
    // and the trailing newline `fail` appends survives sanitization.
    try std.testing.expectEqualStrings("invalid version ']52;c;cHduZWQ='\n", text);

    // UTF-8 multibyte passes through untouched: continuation bytes (0x80-0xBF)
    // and lead bytes (0xC0+) both fall outside the stripped C0/DEL range.
    err_aw.clearRetainingCapacity();
    try std.testing.expectEqual(error.CommandFailed, ctx.fail("no note: {s}", .{"café-日本語-🎉"}));
    try std.testing.expectEqualStrings("no note: café-日本語-🎉\n", err_aw.written());

    // Tab and newline are the two control bytes worth keeping — a multi-line
    // failure message must still render as multiple lines.
    err_aw.clearRetainingCapacity();
    try std.testing.expectEqual(error.CommandFailed, ctx.fail("a\tb\nc", .{}));
    try std.testing.expectEqualStrings("a\tb\nc\n", err_aw.written());
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
