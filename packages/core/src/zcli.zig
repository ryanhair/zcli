const std = @import("std");
const args_parser = @import("args.zig");
const options_parser = @import("options.zig");
const command_parser = @import("command_parser.zig");
pub const plugin_types = @import("plugin_types.zig");
pub const registry = @import("registry.zig");
const diagnostic_errors = @import("diagnostic_errors.zig");
const option_utils = @import("options/utils.zig");
pub const theme = @import("theme");
pub const markdown = @import("markdown");

/// Spinners and progress bars. The import IS the type: build one instance
/// carrying writer/io/theme and `spinner`/`progressBar` are methods on it. In a
/// command, prefer `context.progress()`, which returns a pre-wired instance.
pub const Progress = @import("progress");

/// Interactive prompts. The import IS the type: build one instance carrying
/// writer/reader/allocator/theme and every prompt is a method on it. In a
/// command, prefer `context.prompts()`, which returns a pre-wired instance.
pub const Prompts = @import("prompts");

/// The terminal-native layout engine (ADR-0013): a static stream that flows
/// into scrollback plus a diffed live region at the bottom edge — the
/// CLI/TUI hybrid. In a command, prefer `context.ui()`, which returns a
/// pre-wired `ui.App`. progress and prompts render on this engine.
pub const ui = @import("ui");

/// A complete CLI theme; apps declare `pub const zcli_theme: zcli.Theme` in
/// their root source file to customize how the CLI looks everywhere.
pub const Theme = theme.Theme;

/// The application's theme: the root source file's `pub const zcli_theme`
/// declaration if present, otherwise the default theme. Lives in the theme
/// package (ADR-0020) so ui/prompts/progress defaults derive from it too.
pub const appTheme = theme.appTheme;

/// Config-file parsing shims for the zcli_config plugin. Plugin modules import
/// only "zcli", so the plugin cannot depend on serde directly; this is the
/// entire surface it needs. serde itself is an internal dependency —
/// re-exporting its whole API here would make a third-party crate part of
/// zcli's public contract.
///
/// These parse into serde's *dynamic* trees rather than a target struct, so the
/// plugin can walk a command path (nested tables/mappings) before applying
/// values — matching how the JSON path uses `std.json.Value`.
pub const config_parse = struct {
    const serde = @import("serde");

    /// Dynamic (untyped) TOML tree — a `StringArrayHashMap` of `TomlValue`.
    pub const TomlTable = serde.toml.Table;
    pub const TomlValue = serde.toml.Value;
    /// Dynamic (untyped) YAML value; a document root is the `.mapping` variant.
    pub const YamlValue = serde.yaml.Value;

    pub fn parseToml(allocator: std.mem.Allocator, content: []const u8) !TomlTable {
        return serde.toml.parse(allocator, content);
    }

    pub fn parseYaml(allocator: std.mem.Allocator, content: []const u8) !YamlValue {
        return serde.yaml.parseValue(allocator, content);
    }
};

/// HTTP client with safe defaults (TLS verification on, bounded response body)
/// over `std.http.Client`. See http.zig.
pub const http = @import("http.zig");

/// Filesystem command discovery — the same scan the build system runs to
/// generate the registry. Exposed so tools can determine a project's command
/// tree without building it (e.g. the `zcli tree` command).
pub const command_discovery = @import("build_utils/command_discovery.zig");

/// Custom parse-type helpers (ADR-0025): detection and construction for fields
/// whose type declares `pub fn parse`. Exposed so the config plugin — which may
/// import only "zcli" — can build such a field from a config string the same way
/// the CLI parser does.
pub const custom_type = @import("custom_type.zig");

/// Dynamic shell-completion contract (ADR-0026): the `Request`/`Candidate`/
/// `Result`/`Directive` types a `meta.<field>.complete` function hook uses, and
/// the `Spec` union the introspection stores. The `zcli_completions` plugin's
/// `__complete` command runs a field's hook at `<TAB>`.
pub const completion = @import("completion.zig");

/// Option value-coercion surface for the zcli_config plugin. A config file
/// stores scalars in a format-native shape (JSON/TOML/YAML); the plugin
/// stringifies them and routes through *the same* parser the CLI and env use,
/// so every option type coerces identically from every source (single source of
/// truth — no per-type ladder in the plugin). Plugin modules import only "zcli",
/// so this is the entire coercion surface they need.
pub const config_coerce = struct {
    /// Parse a string into an option field type `T` exactly as a CLI/env value
    /// would be: ints (all widths, checked), floats, enums, `[]const u8`,
    /// optionals, and custom `parse` types. Errors (bad format, out of range,
    /// unknown enum variant) surface as `error.InvalidOptionValue` so config can
    /// stay lenient (skip + warn) per DESIGN.md.
    pub const parseOptionValue = option_utils.parseOptionValue;
    /// True for accumulating array fields (`[]T` where `T != u8`) — a multi-value
    /// option. `[]const u8` is a string, not an array.
    pub const isArrayType = option_utils.isArrayType;
    /// True for `bool`/`?bool` flags, which coerce from a config boolean directly.
    pub const isBooleanFlag = option_utils.isBooleanFlag;
};

const testing = std.testing;

// Re-export error types
pub const ZcliError = diagnostic_errors.ZcliError;
pub const ZcliDiagnostic = diagnostic_errors.ZcliDiagnostic;
pub const formatDiagnostic = diagnostic_errors.formatDiagnostic;
pub const expectedTypeName = diagnostic_errors.expectedTypeName;

/// Levenshtein edit-distance + nearest-match helpers, shared by the options
/// parser (unknown-option suggestions) and the not-found plugin (unknown-command
/// suggestions), so both draw "did you mean" hints from one implementation.
pub const levenshtein = @import("levenshtein.zig");

// Re-export plugin types for user convenience

// Re-export new plugin system types
pub const GlobalOption = plugin_types.GlobalOption;
pub const TransformResult = plugin_types.TransformResult;
pub const ParsedArgs = plugin_types.ParsedArgs;
pub const GlobalOptionsResult = plugin_types.GlobalOptionsResult;
pub const PluginEntry = plugin_types.PluginEntry;
pub const option = plugin_types.option;

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
    /// For an enum-typed option, its variant names (the valid choices), else
    /// `null`. Shell completions offer these as the option's argument values.
    enum_values: ?[]const []const u8 = null,
    /// A dynamic/native completion source declared via `meta.options.<field>.complete`
    /// (ADR-0026), else `null`. Drives the callback wiring the generators emit and
    /// the hook `__complete` runs.
    complete: ?completion.Spec = null,
};

/// Argument information for introspection and documentation
pub const ArgInfo = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    is_optional: bool = false,
    is_variadic: bool = false,
    /// For an enum-typed positional argument, its variant names, else `null`.
    /// Shell completions offer these as the positional's values.
    enum_values: ?[]const []const u8 = null,
    /// A dynamic/native completion source declared via `meta.args.<field>.complete`
    /// (ADR-0026), else `null`. Drives the callback wiring the generators emit and
    /// the hook `__complete` runs.
    complete: ?completion.Spec = null,
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
    /// The field's type as a string (`@typeName`), e.g. `"bool"`, `"?bool"`,
    /// `"u32"`, `"[]const u8"`. A descriptor, not a Zig `type` — FieldInfo stays a
    /// plain runtime value.
    type_name: []const u8 = "",
    /// The field's declared default rendered to a string (`"true"`, `"8080"`,
    /// `"info"`, …), or `null` when it has no scalar default. Together with
    /// `type_name` this lets a consumer decide presentation — e.g. help shows a
    /// default-`true` boolean by its `--no-` negation.
    default_value: ?[]const u8 = null,
    /// True for a *required* option: non-optional, non-array, non-bool, and with
    /// no default — the value must be supplied. Help marks these `(required)`.
    /// Always false for positional args (their required-ness is positional).
    is_required: bool = false,
    /// For an enum-typed field (or `?enum`), its variant names — the valid
    /// choices — else `null`. Help renders these as `one of: a, b, c`. Names are
    /// comptime string literals with static lifetime.
    enum_values: ?[]const []const u8 = null,
    /// The option-field names this field depends on via
    /// `meta.options.<field>.requires`, or `null`. Help renders these as
    /// `(requires --dep)`. Raw field names (dash-converted at render), static
    /// lifetime. Always null for positional args.
    requires: ?[]const []const u8 = null,
    /// A dynamic/native completion source declared via the field's
    /// `meta.<args|options>.<field>.complete` (ADR-0026), else `null`. This is
    /// the single per-field completion projection; `OptionInfo`/`ArgInfo` for
    /// completions are derived from `FieldInfo`, carrying this through.
    complete: ?completion.Spec = null,
};

/// Information about command module structure for plugin introspection
pub const CommandModuleInfo = struct {
    has_args: bool = false,
    has_options: bool = false,
    raw_meta_ptr: ?*const anyopaque = null, // Points to cmd.module.meta
    args_fields: []const FieldInfo = &.{}, // Runtime-safe field info
    options_fields: []const FieldInfo = &.{}, // Runtime-safe field info
    /// The command's `meta.exclusive` mutually-exclusive sets — each a list of
    /// Options field names. Help lists them under OPTIONS. Empty when none.
    exclusive: []const []const []const u8 = &.{},
};

/// Execution context provided to commands and plugins — see context.zig,
/// the single source of truth for the interface.
///
/// `ContextFor(plugins)` computes the concrete type with one type-safe field
/// per plugin ContextData under `.plugins`; the Registry re-exports its
/// instantiation as `Registry...build().Context`, which is what generated
/// apps import via `@import("command_registry").Context`.
pub const ContextFor = @import("context.zig").ContextFor;

/// Plugin-less context instantiation, for library code and tests that don't
/// touch `context.plugins`.
pub const Context = ContextFor(&.{});

/// Create a test context type with plugin data support (an alias of
/// `ContextFor`). Use this when testing code that accesses
/// `context.plugins.{plugin_id}`.
///
/// ```zig
/// const TestCtx = zcli.TestContext(&.{ MyPlugin });
/// var stdio: zcli.Stdio = undefined;
/// stdio.init(std.testing.io);
/// const environ = std.process.Environ.Map.init(testing.allocator);
/// var ctx = TestCtx.init(testing.allocator, std.testing.io, &stdio, &environ);
/// defer ctx.deinit();
/// ctx.plugins.my_plugin.some_field = true;
/// ```
pub const TestContext = ContextFor;

/// Holder for the process's standard streams. Owns the buffered stdout/stderr
/// writers and stdin reader (plus their backing buffers), which is why it must
/// live at a stable address and be passed to a Context by pointer. Command and
/// plugin code never reaches into this directly — it reads the `std.Io` instance
/// via `context.io` and does I/O via `context.stdout()`/`stderr()`/`stdin()`.
/// Standard-stream holder backing `context.stdout()`/`stderr()`/`stdin()`.
///
/// PINNED TYPE: the buffered writers/reader point into buffers inside the
/// struct itself, so a Stdio must stay at one address for its whole life —
/// never copy it, never return it by value. `init` therefore initializes in
/// place (there is no by-value constructor to accidentally move):
///
///     var stdio: zcli.Stdio = undefined;
///     stdio.init(io);
pub const Stdio = struct {
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

    /// Initialize in place; `self` must already be at its final address.
    /// Replaces the old two-phase init()+finalize(), whose window between
    /// the by-value return and finalize() invited exactly the copy that
    /// dangles — and which made "forgot to finalize" (undefined streams)
    /// possible at all.
    pub fn init(self: *@This(), io: std.Io) void {
        self.* = .{ .io = io };
        // Streaming (plain write(2)), never positional. Inherited stdout/stderr
        // may be a shared regular-file fd (e.g. `cmd >log`, CI logs, a coding
        // agent capturing output). Positional mode pwrites from its own offset
        // starting at 0, ignoring the fd's shared offset — so a second process
        // writing to the same file overwrites the first from byte 0. Streaming
        // uses the kernel's shared offset, so appends serialize correctly.
        self.stdout_writer = std.Io.File.stdout().writerStreaming(io, &self.stdout_buf);
        self.stderr_writer = std.Io.File.stderr().writerStreaming(io, &self.stderr_buf);
        // Streaming (plain read(2)) for the same reason: an inherited stdin fd
        // that is a shared regular file (`cmd <file`) has a live shared offset.
        // Positional mode would read from byte 0, re-reading data the parent
        // already consumed instead of continuing from the shared offset.
        self.stdin_reader = std.Io.File.stdin().readerStreaming(io, &self.stdin_buf);
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
/// var diag: ?ZcliDiagnostic = null;
/// const result = try parseCommandLine(Args, Options, null, allocator, context.environ, args, &diag);
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
/// Requires that any command with an `execute` declares `Args` and `Options`,
/// checks that `Args`/`Options` are structs, and checks the `meta` block is
/// well-formed (delegated to `validateMeta`). The `execute` signature is
/// intentionally *not* asserted here: a command's `execute` typically takes
/// `context: *Context`, and `Context` is a projection of the very registry
/// being built — reaching for `@TypeOf(execute)` at registration time forms a
/// comptime dependency loop. A wrong `execute` shape still fails the build at
/// the framework's own call site, pointing at the author's file.
pub fn validateCommand(comptime path: []const u8, comptime Module: type) void {
    @setEvalBranchQuota(10000);
    const loc = commandContext(path);

    // The command contract is declaration-driven: zcli reads a command's
    // `Args`/`Options` *declarations* to build parsing and dispatch — it never
    // inspects `execute`'s parameter types (see above). So a runnable command
    // (one that declares `execute`) MUST declare both, even when empty. Naming
    // a type in the signature, e.g. `execute(_: struct {}, ...)`, is not a
    // declaration and leaves the contract undefined. Metadata-only command
    // groups have no `execute` and are exempt — they never parse arguments.
    if (@hasDecl(Module, "execute")) {
        if (!@hasDecl(Module, "Args")) {
            @compileError(loc ++ "missing `pub const Args`. zcli reads a command's positional " ++
                "arguments from its `Args` declaration, not from `execute`'s parameters — writing " ++
                "`execute(_: struct {}, ...)` names a type but declares nothing. Add a declaration:\n" ++
                "    pub const Args = struct {};                     // no positional arguments\n" ++
                "    pub const Args = struct { name: []const u8 };   // one required positional\n" ++
                "and refer to it in execute: `execute(args: Args, ...)`.");
        }
        if (!@hasDecl(Module, "Options")) {
            @compileError(loc ++ "missing `pub const Options`. zcli reads a command's flags from " ++
                "its `Options` declaration, not from `execute`'s parameters — writing " ++
                "`execute(_, _: struct {}, ...)` names a type but declares nothing. Add a declaration:\n" ++
                "    pub const Options = struct {};                         // no flags\n" ++
                "    pub const Options = struct { verbose: bool = false };  // one --verbose flag\n" ++
                "and refer to it in execute: `execute(_, options: Options, ...)`.");
        }
    }

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

    // Options field shapes. A field with no absent-flag value — not bool,
    // optional, accumulating array, or defaulted — is a REQUIRED option: its
    // type says a value must be supplied, and the parser enforces that at
    // runtime (satisfiable by CLI, env, or config). No shape is rejected here;
    // the checks below are about naming collisions, not presence.
    if (@typeInfo(OptionsType) == .@"struct") {
        const opts_meta = if (@hasDecl(Module, "meta")) Module.meta else null;
        inline for (@typeInfo(OptionsType).@"struct".fields) |field| {
            // A boolean flag's name must not begin with `no-`: every bool and
            // `?bool` auto-generates a `--no-<name>` negation, so a `no_`-prefixed
            // flag would collide with (and read as) another flag's negation.
            if (option_utils.isBooleanFlag(field.type)) {
                const eff = option_utils.effectiveLongName(opts_meta, field.name);
                if (std.mem.startsWith(u8, eff, "no-")) {
                    @compileError(loc ++ "boolean option '" ++ field.name ++ "' resolves to flag `--" ++
                        eff ++ "`, which collides with the auto-generated `--no-…` negation. " ++
                        "Name it positively (e.g. `" ++ eff[3..] ++ ": " ++ @typeName(field.type) ++
                        "`) and pass `--" ++ eff ++ "` to disable it.");
                }
            }

            // An optional option carries a third, "unset" state that config/env
            // fill in — that state is `null`, and the parser initializes optionals
            // to `null` *before* any declared default is read (so a non-null
            // default would be silently discarded). Forbid it: optionals default
            // to null; use a non-optional field with a default for a guaranteed value.
            if (@typeInfo(field.type) == .optional and field.default_value_ptr != null) {
                const dv: *const field.type = @ptrCast(@alignCast(field.default_value_ptr.?));
                if (dv.* != null) {
                    @compileError(loc ++ "optional option '" ++ field.name ++ "' has a non-null default. " ++
                        "Optionals default to `null` (the \"unset\" state config/env fill in). " ++
                        "Drop the default, or use a non-optional field with a default for a guaranteed value.");
                }
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
/// - Options metadata fields (description, short, name, env)
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
    const valid_top_level = .{ "description", "examples", "args", "options", "hidden", "aliases", "exclusive" };

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
                const valid_option_fields = .{ "description", "short", "name", "env", "requires", "validate", "complete" };

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
                        @compileError(loc ++ "unknown option metadata field '" ++ opt_field.name ++ "' in option '" ++ field.name ++ "'. Valid fields are: description, short, name, env, requires, validate, complete");
                    }
                }

                // `validate`: an optional per-field hook run after the value is
                // resolved from every source. Its signature must be
                // `fn(Base) ?[]const u8`, where Base is the Options field type
                // with one optional level removed (the hook sees a present value,
                // never null). Null means valid; a returned string is the reason.
                if (@hasField(@TypeOf(option_meta), "validate")) {
                    const FieldT = comptime blk: {
                        for (options_fields) |of| {
                            if (std.mem.eql(u8, of.name, field.name)) break :blk of.type;
                        }
                        unreachable;
                    };
                    const Base = switch (@typeInfo(FieldT)) {
                        .optional => |o| o.child,
                        else => FieldT,
                    };
                    const v_info = @typeInfo(@TypeOf(option_meta.validate));
                    const sig_ok = comptime blk: {
                        if (v_info != .@"fn") break :blk false;
                        const f = v_info.@"fn";
                        if (f.params.len != 1) break :blk false;
                        const param_ok = if (f.params[0].type) |pt| pt == Base else false;
                        const ret_ok = if (f.return_type) |rt| rt == ?[]const u8 else false;
                        break :blk param_ok and ret_ok;
                    };
                    if (!sig_ok) {
                        @compileError(loc ++ "option '" ++ field.name ++ "' `validate` must have signature `fn(" ++ @typeName(Base) ++ ") ?[]const u8`");
                    }
                }

                // `requires`: every named dependency must be an Options field,
                // and a field may not require itself (a no-op that reads as a bug).
                if (@hasField(@TypeOf(option_meta), "requires")) {
                    for (option_utils.tupleToStrings(option_meta.requires)) |dep| {
                        if (!@hasField(OptionsType, dep)) {
                            @compileError(loc ++ "option '" ++ field.name ++ "' requires '" ++ dep ++
                                "', which is not a field in the Options struct");
                        }
                        if (std.mem.eql(u8, dep, field.name)) {
                            @compileError(loc ++ "option '" ++ field.name ++ "' lists itself in `requires`");
                        }
                    }
                }
            }
        }
    }

    // Validate 'exclusive' sets if present: each set names two or more distinct
    // Options fields, at most one of which may be supplied. A *required* field
    // (always present) can never satisfy "at most one", so it may not appear in
    // a set at all.
    if (@hasField(MetaType, "exclusive")) {
        for (option_utils.exclusiveSets(meta), 0..) |set, set_i| {
            if (set.len < 2) {
                @compileError(loc ++ std.fmt.comptimePrint("`meta.exclusive` set #{d} lists {d} option(s); " ++
                    "a mutually-exclusive set needs at least two members", .{ set_i + 1, set.len }));
            }
            for (set, 0..) |member, member_i| {
                if (!@hasField(OptionsType, member)) {
                    @compileError(loc ++ "`meta.exclusive` names '" ++ member ++
                        "', which is not a field in the Options struct");
                }
                // No duplicate members within a set.
                for (set[0..member_i]) |earlier| {
                    if (std.mem.eql(u8, earlier, member)) {
                        @compileError(loc ++ "`meta.exclusive` lists '" ++ member ++ "' twice in the same set");
                    }
                }
                // A required option can't participate: it is always supplied, so
                // no other member of its set could ever be.
                inline for (@typeInfo(OptionsType).@"struct".fields) |opt_field| {
                    if (comptime std.mem.eql(u8, opt_field.name, member) and option_utils.isRequiredOption(opt_field)) {
                        @compileError(loc ++ "`meta.exclusive` includes required option '" ++ member ++
                            "'. A required option is always supplied, so it can't be one of several mutually-" ++
                            "exclusive choices — give it a default, make it optional, or drop it from the set.");
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

            // Args metadata is either a bare string description or a struct
            // carrying named fields (currently just `description`), mirroring
            // the options metadata shape so args can grow richer per-field
            // configuration without another breaking change.
            const arg_meta = @field(args_meta, field.name);
            const arg_meta_type = @TypeOf(arg_meta);
            const arg_meta_info = @typeInfo(arg_meta_type);

            if (arg_meta_info == .@"struct") {
                const valid_arg_fields = .{ "description", "validate", "complete" };

                inline for (arg_meta_info.@"struct".fields) |arg_field| {
                    const arg_is_valid = comptime blk: {
                        for (valid_arg_fields) |valid| {
                            if (std.mem.eql(u8, arg_field.name, valid)) {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    };
                    if (!arg_is_valid) {
                        @compileError(loc ++ "unknown arg metadata field '" ++ arg_field.name ++ "' in arg '" ++ field.name ++ "'. Valid fields are: description, validate, complete");
                    }
                }

                // `validate`: same per-field hook as options, run on the parsed
                // positional value. Signature `fn(Base) ?[]const u8`, Base = the
                // Args field type with one optional level removed.
                if (@hasField(@TypeOf(arg_meta), "validate")) {
                    const FieldT = comptime blk: {
                        for (args_fields) |af| {
                            if (std.mem.eql(u8, af.name, field.name)) break :blk af.type;
                        }
                        unreachable;
                    };
                    const Base = switch (@typeInfo(FieldT)) {
                        .optional => |o| o.child,
                        else => FieldT,
                    };
                    const v_info = @typeInfo(@TypeOf(arg_meta.validate));
                    const sig_ok = comptime blk: {
                        if (v_info != .@"fn") break :blk false;
                        const f = v_info.@"fn";
                        if (f.params.len != 1) break :blk false;
                        const param_ok = if (f.params[0].type) |pt| pt == Base else false;
                        const ret_ok = if (f.return_type) |rt| rt == ?[]const u8 else false;
                        break :blk param_ok and ret_ok;
                    };
                    if (!sig_ok) {
                        @compileError(loc ++ "arg '" ++ field.name ++ "' `validate` must have signature `fn(" ++ @typeName(Base) ++ ") ?[]const u8`");
                    }
                }
            } else {
                // Bare string form: a string literal (*const [N:0]u8) or a
                // string slice ([]const u8).
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
                    @compileError(loc ++ "meta.args for '" ++ field.name ++ "' must be a string description or a struct with a `description` field");
                }
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
            // Args metadata accepts both the bare-string and struct forms.
            .args = .{
                .name = .{ .description = "Who to greet" },
                .title = "Optional honorific",
            },
        };
        pub const Args = struct { name: []const u8, title: ?[]const u8 = null };
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
//
//   command 'broken': unknown arg metadata field 'desc' in arg 'name'. Valid fields are: description
//     pub const meta = .{ .args = .{ .name = .{ .desc = "typo" } } };
//     pub const Args = struct { name: []const u8 };
//
//   Option constraints (ADR-0022). Each guard below is verified by hand:
//
//   command 'broken': `meta.exclusive` names 'yamlx', which is not a field ...
//     pub const meta = .{ .exclusive = .{.{ .json, .yamlx }} };
//
//   command 'broken': `meta.exclusive` includes required option 'region' ...
//     pub const meta = .{ .exclusive = .{.{ .region, .json }} };
//     pub const Options = struct { region: []const u8, json: bool = false };
//
//   command 'broken': `meta.exclusive` set #1 lists 1 option(s); a ... needs at least two
//     pub const meta = .{ .exclusive = .{.{.json}} };
//
//   command 'broken': option 'a' lists itself in `requires`
//     pub const meta = .{ .options = .{ .a = .{ .requires = .{.a} } } };

test "Context creation" {
    const allocator = testing.allocator;

    // Just verify the Context struct can be created
    var stdio: Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var context = Context.init(allocator, std.testing.io, &stdio, &test_environ);
    defer context.deinit();

    // Test that convenience methods work
    _ = context.stdout();
    _ = context.stderr();
    _ = context.stdin();
}

test "context.ui() returns an App wired to the detected environment" {
    const allocator = testing.allocator;
    var stdio: Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var context = Context.init(allocator, std.testing.io, &stdio, &test_environ);
    defer context.deinit();

    var app = try context.ui(.{});
    defer app.deinit();
    // Tests never run on a TTY: the App must come back non-interactive, so
    // frame() is a no-op and emit() prints plain lines.
    try testing.expect(!app.options.interactive);
    try testing.expect(app.options.capability == context.theme.capability());
}

test "Context is one generic: base and TestContext instantiations unify" {
    // The three historical Context definitions (base, TestContext, and the
    // registry's computed type) are now one generic. Zig memoizes generic
    // instantiation, so the same plugin list must yield the SAME type — a
    // command typed against one is callable with the other.
    try testing.expect(Context == TestContext(&.{}));
    try testing.expect(Context == ContextFor(&.{}));
}

test "getCommandDescription matches full paths only" {
    const allocator = testing.allocator;
    var stdio: Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var context = Context.init(allocator, std.testing.io, &stdio, &test_environ);
    defer context.deinit();

    const infos = [_]CommandInfo{
        .{ .path = &.{"deploy"}, .description = "Deploy the app" },
        .{ .path = &.{ "remote", "add" }, .description = "Add a remote" },
    };
    context.plugin_command_info = &infos;

    try testing.expectEqualStrings("Deploy the app", context.getCommandDescription(&.{"deploy"}).?);
    try testing.expectEqualStrings("Add a remote", context.getCommandDescription(&.{ "remote", "add" }).?);
    // Prefixes, wrong parts, and unknown paths all miss.
    try testing.expect(context.getCommandDescription(&.{"remote"}) == null);
    try testing.expect(context.getCommandDescription(&.{ "remote", "rm" }) == null);
    try testing.expect(context.getCommandDescription(&.{"nope"}) == null);
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
    var stdio: Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &test_environ);
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
    var stdio: Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &test_environ);
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
        pub const Args = struct {};
        pub const Options = struct {};

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
        pub const Args = struct {};
        pub const Options = struct {};

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
        pub const Args = struct {};
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
        pub const Args = struct {};
        pub const Options = struct {};

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
        pub const Args = struct {};
        pub const Options = struct {};

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

test "Stdio.init wires streams to the struct's own buffers, in place" {
    var stdio: Stdio = undefined;
    stdio.init(std.testing.io);

    // The buffered streams must point into this instance's buffers — that is
    // the pinned-type invariant init establishes (and the reason there is no
    // by-value constructor: a copy would leave these pointing at the source).
    try testing.expectEqual(@as([*]u8, &stdio.stdout_buf), stdio.stdout_writer.interface.buffer.ptr);
    try testing.expectEqual(@as([*]u8, &stdio.stderr_buf), stdio.stderr_writer.interface.buffer.ptr);
    try testing.expectEqual(@as([*]u8, &stdio.stdin_buf), stdio.stdin_reader.interface.buffer.ptr);

    // stdin is usable without any override — the old two-phase API left it
    // undefined when finalize() was skipped (as the unit-test helper did).
    _ = stdio.stdin();

    // Overrides still take precedence over the wired streams.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    stdio.stdout_override = &aw.writer;
    try testing.expectEqual(&aw.writer, stdio.stdout());
}

test "TestContext.deinit runs plugin deinitContextData hooks" {
    const HookPlugin = struct {
        pub const plugin_id = "hook_plugin";
        var hook_ran: bool = false;
        pub const ContextData = struct { payload: ?[]u8 = null };
        pub fn deinitContextData(data: *ContextData, allocator: std.mem.Allocator) void {
            hook_ran = true;
            if (data.payload) |p| allocator.free(p);
            data.payload = null;
        }
    };

    const Ctx = TestContext(&.{HookPlugin});
    var stdio: Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(testing.allocator);
    var ctx = Ctx.init(testing.allocator, std.testing.io, &stdio, &test_environ);
    ctx.plugins.hook_plugin.payload = try testing.allocator.dupe(u8, "plugin-owned");
    ctx.deinit();

    // The hook ran — and freed the allocation, or std.testing.allocator's
    // leak check fails this test. Before this fix TestContext.deinit never
    // ran lifecycle hooks, so plugins cleaned up in production but leaked
    // under test.
    try testing.expect(HookPlugin.hook_ran);
}
