const std = @import("std");
const zcli = @import("zcli.zig");
const identifier = @import("identifier.zig");
const option_utils = @import("options/utils.zig");
const custom_type = @import("custom_type.zig");
const levenshtein = @import("levenshtein.zig");
const testing = std.testing;

// ============================================================================
// Core Plugin Types
// ============================================================================

/// Global option that can be registered by plugins.
///
/// A global option is parsed by the *same* pipeline command options, env, and
/// config use (`option_utils.parseOptionValue`) — the single source of truth —
/// so it supports the full type set: bool flags, integers, floats, enums,
/// `[]const u8`, custom `parse` types, and optionals of those. There is no
/// second, weaker parser.
pub const GlobalOption = struct {
    name: []const u8,
    short: ?u8 = null,
    type: type,
    /// The declared (or synthesized) default, type-erased so every GlobalOption
    /// is one concrete struct type storable in a `[]const GlobalOption`. It
    /// points at a comptime value of `type`; recover it with `defaultValue`. A
    /// GlobalOption carries a `type` field, so it only ever exists at comptime.
    default: *const anyopaque,
    description: []const u8,
    category: ?[]const u8 = null,

    /// The stored default typed as `T` (which must be `self.type`).
    pub fn defaultValue(comptime self: @This(), comptime T: type) T {
        return @as(*const T, @ptrCast(@alignCast(self.default))).*;
    }
};

/// Whether `option_utils.parseOptionValue` can coerce a string into `T` — the
/// single source of truth the CLI, env, and config already use. Mirrors that
/// function's type switch exactly, so the declaration-time validator and the
/// runtime converter never disagree. (`bool` is handled separately as a
/// presence flag, so it is intentionally absent here.)
fn parseableByOptionValue(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .@"enum" => true,
        .pointer => |ptr| ptr.size == .slice and ptr.child == u8,
        .optional => |opt| parseableByOptionValue(opt.child),
        .@"struct", .@"union" => custom_type.isCustomParsed(T),
        else => false,
    };
}

/// The types a global option may declare: a `bool` presence flag, or anything
/// the shared option parser handles. Rejected at the point of declaration — not
/// at some later use site with a baffling error.
fn validateGlobalOptionType(comptime name: []const u8, comptime T: type) void {
    if (T == bool or parseableByOptionValue(T)) return;
    @compileError("global option '" ++ name ++ "' has unsupported type `" ++ @typeName(T) ++
        "`. Supported: bool, integers, floats, enums, []const u8, custom `parse` types, and optionals of those.");
}

/// A synthesized default for a global option declared without one. Only read by
/// introspection (`GlobalOption.defaultValue`); an absent global never fires its
/// handler, so this value is never delivered to a plugin.
fn zeroDefault(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .optional => null,
        .@"enum" => |e| @field(T, e.fields[0].name),
        .pointer => "", // []const u8
        else => std.mem.zeroes(T),
    };
}

/// Unified helper for declaring a GlobalOption. The default is stored typed
/// (as a comptime value of `T`), so there is no stringly default round-trip —
/// `parseOptionValue` is the only value coercion the pipeline performs.
pub fn option(comptime name: []const u8, comptime T: type, comptime config: anytype) GlobalOption {
    comptime validateGlobalOptionType(name, T);

    const short = if (@hasField(@TypeOf(config), "short")) config.short else null;
    const description = if (@hasField(@TypeOf(config), "description")) config.description else "";
    const category = if (@hasField(@TypeOf(config), "category")) config.category else null;
    // Coerce the declared default (or a synthesized zero) to the field type once,
    // at comptime, and hand back a pointer to that comptime value. Being
    // comptime-known, the value has static lifetime.
    const default_value: T = if (@hasField(@TypeOf(config), "default")) config.default else zeroDefault(T);

    return GlobalOption{
        .name = name,
        .short = short,
        .type = T,
        // @ptrCast: a pointer to a slice-typed default (`*const []const u8`) is a
        // double pointer that won't implicitly coerce to anyopaque; the cast is
        // exact and `defaultValue` casts straight back to `*const T`.
        .default = @ptrCast(&default_value),
        .description = description,
        .category = category,
    };
}

/// Result of argument transformation
pub const TransformResult = struct {
    args: []const []const u8,
    consumed_indices: []const usize = &.{},
    continue_processing: bool = true,
};

/// Parsed arguments structure
pub const ParsedArgs = struct {
    positional: []const []const u8 = &.{},

    pub fn init(_: std.mem.Allocator) @This() {
        return .{
            .positional = &.{},
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.positional.len > 0) {
            allocator.free(self.positional);
        }
    }
};

/// Global options parsing result
pub const GlobalOptionsResult = struct {
    consumed: []const usize,
    remaining: []const []const u8,
    errors: []const []const u8 = &.{},
};

// ============================================================================
// Plugin Capability Detection (compile-time introspection)
// ============================================================================

/// Check if a type has global options
pub fn hasGlobalOptions(comptime T: type) bool {
    return @hasDecl(T, "global_options");
}

/// Check if a type has a transformArgs function
pub fn hasTransformArgs(comptime T: type) bool {
    return @hasDecl(T, "transformArgs");
}

/// Check if a type has a handleGlobalOption function
pub fn hasHandleGlobalOption(comptime T: type) bool {
    return @hasDecl(T, "handleGlobalOption");
}

/// Check if a type has lifecycle hooks
pub fn hasPreParse(comptime T: type) bool {
    return @hasDecl(T, "preParse");
}

pub fn hasPostParse(comptime T: type) bool {
    return @hasDecl(T, "postParse");
}

pub fn hasPreExecute(comptime T: type) bool {
    return @hasDecl(T, "preExecute");
}

pub fn hasPostExecute(comptime T: type) bool {
    return @hasDecl(T, "postExecute");
}

pub fn hasOnError(comptime T: type) bool {
    return @hasDecl(T, "onError");
}

/// Check if a type has an onStartup hook. Runs once per invocation after plugin
/// data is captured and before argument parsing/routing.
pub fn hasOnStartup(comptime T: type) bool {
    return @hasDecl(T, "onStartup");
}

/// Check if a type has an applyConfigDefaults hook. See `hook_names` below for
/// the full contract.
pub fn hasApplyConfigDefaults(comptime T: type) bool {
    return @hasDecl(T, "applyConfigDefaults");
}

/// Check if a type has command extensions
pub fn hasCommands(comptime T: type) bool {
    return @hasDecl(T, "commands");
}

/// Get plugin priority (default 50)
pub fn getPriority(comptime T: type) i32 {
    if (@hasDecl(T, "priority")) {
        return T.priority;
    }
    return 50;
}

/// The lifecycle hooks detected by exact name above. Kept next to the has*
/// functions so a new hook is added to both or the validator complains about
/// nothing.
///
/// Signatures (all take `context: anytype` because plugins compile independently
/// of the host app):
///
///   transformArgs(context, args: []const []const u8) !zcli.TransformResult
///   handleGlobalOption(context, name: []const u8, value: anytype) !void
///   preParse(context, args: []const []const u8) ![]const []const u8
///   postParse(context, args: zcli.ParsedArgs) !?zcli.ParsedArgs
///   preExecute(context, args: zcli.ParsedArgs) !?zcli.ParsedArgs
///   postExecute(context, success: bool) !void
///   onError(context, err: anyerror) !bool
///
///   applyConfigDefaults(context, comptime OptionsType: type,
///                       options: *OptionsType, provided: []const bool,
///                       applied: []bool) void
///     Fills option fields from a lower-precedence source (e.g. a config file)
///     after CLI + env parsing but before required/dependency/exclusive
///     validation. `provided` has one flag per Options field, in field-
///     declaration order, true when the CLI or the field's env fallback already
///     set it. The precedence obligation: the hook MUST skip any field whose
///     `provided` flag is true — this single check is what makes
///     CLI > env > hook hold. `applied` (same keying, caller-zeroed) is the
///     hook's report back: it MUST mark every field it fills — the registry's
///     required-option and constraint checks treat `provided[i] or applied[i]`
///     as "supplied", with no value diffing (#388). `options` is mutated in
///     place; `provided` is a read-only view. The hook does not return an
///     error union — a malformed or
///     unreadable source is a warning-and-skip, never a hard failure (a config
///     typo must not brick every command). Any values it writes into `options`
///     (e.g. coerced strings/arrays) must outlive the command's execution;
///     the built-in zcli_config plugin allocates them from a parse arena tied
///     to its ContextData so they die with `deinitContextData`.
const hook_names = [_][]const u8{
    "transformArgs",
    "handleGlobalOption",
    "preParse",
    "postParse",
    "preExecute",
    "postExecute",
    "onError",
    "onStartup",
    "applyConfigDefaults",
};

/// Non-hook decl names that are part of the plugin contract (never flagged).
///
/// The two ContextData pairings run outside the lifecycle-hook pipeline and take
/// `context: anytype` for the same reason (plugins compile independently):
///
///   initContextData(data: *ContextData, context: anytype) !void
///     Runs once per invocation after the framework fills the core context
///     fields and before any lifecycle hook, so `data` can capture borrowed
///     references (allocator, io, app_name, environ, …) that stay valid for the
///     whole invocation. Optional; requires ContextData.
///   deinitContextData(data: *ContextData, allocator: std.mem.Allocator) void
///     Runs from Context.deinit at end of invocation. Optional; requires
///     ContextData, and must be safe on partially-initialized data.
const contract_names = hook_names ++ [_][]const u8{
    "global_options",
    "commands",
    "priority",
    "plugin_id",
    "ContextData",
    "initContextData",
    "deinitContextData",
    "init",
};

/// The single source of the "ContextData without plugin_id" error, shared by
/// `validatePlugin` (fires at plugin registration) and `context.pluginFieldName`
/// (a backstop for direct `ContextFor`/`TestContext` use that bypasses
/// registration, e.g. in tests).
pub fn requirePluginId(comptime Plugin: type) void {
    comptime {
        if (@hasDecl(Plugin, "ContextData") and !@hasDecl(Plugin, "plugin_id")) {
            @compileError("plugin '" ++ @typeName(Plugin) ++ "' declares ContextData but no plugin_id. " ++
                "ContextData is exposed as a typed field on context.plugins named by plugin_id. Add:\n" ++
                "    pub const plugin_id = \"my_plugin\";");
        }
    }
}

/// Comptime backstop against silently-dead hooks. Hooks are detected by exact
/// name (`@hasDecl`), so a typo'd hook — `preExeucte` — compiles fine and
/// simply never fires. Called by the registry-level validation pass
/// (registry/validation.zig) for every registered plugin: any *function* decl
/// whose name is within edit distance 2 of a hook (but isn't one) is rejected
/// with a pointer at the hook it resembles.
pub fn validatePlugin(comptime Plugin: type) void {
    comptime {
        // The per-decl edit-distance DP over every hook name is cheap
        // individually but adds up across a plugin with many decls; give it
        // headroom above the 1000 default so adding a hook name never trips it.
        @setEvalBranchQuota(10_000);
        if (@typeInfo(Plugin) != .@"struct") return;
        for (@typeInfo(Plugin).@"struct".decls) |decl| {
            if (isContractName(decl.name)) continue;
            // Only functions can be hooks; consts near a hook name are inert.
            if (@typeInfo(@TypeOf(@field(Plugin, decl.name))) != .@"fn") continue;
            for (hook_names) |hook| {
                // Cheap length gate before the DP — comptime branch quota.
                const len_diff = if (decl.name.len > hook.len) decl.name.len - hook.len else hook.len - decl.name.len;
                if (len_diff > 2) continue;
                if (levenshtein.editDistance(decl.name, hook) <= 2) {
                    @compileError("plugin function '" ++ decl.name ++ "' looks like a misspelling of the lifecycle hook '" ++ hook ++
                        "' and would never be called — hooks are detected by exact name. Fix the spelling, or rename the function away from the hook.");
                }
            }
        }

        // The ContextData contract: a plugin's ContextData is exposed as a
        // typed field on `context.plugins`, named by `plugin_id`. Enforce the
        // whole contract here at the declaration — a helpful comptime error —
        // instead of letting it fail obscurely at the `context.plugins.<id>`
        // use-site (or silently getting no slot).
        requirePluginId(Plugin);
        // deinitContextData is the cleanup hook for ContextData and only runs
        // when ContextData exists — without it the function is silently dead,
        // the same failure shape as a misspelled lifecycle hook above.
        if (@hasDecl(Plugin, "deinitContextData") and !@hasDecl(Plugin, "ContextData")) {
            @compileError("plugin '" ++ @typeName(Plugin) ++ "' declares deinitContextData but no ContextData. " ++
                "deinitContextData is the cleanup hook for a plugin's ContextData and would never be called as written. " ++
                "Add a ContextData, or remove deinitContextData.");
        }
        // initContextData is the setup hook for ContextData — same silently-dead
        // shape as deinitContextData without one.
        if (@hasDecl(Plugin, "initContextData") and !@hasDecl(Plugin, "ContextData")) {
            @compileError("plugin '" ++ @typeName(Plugin) ++ "' declares initContextData but no ContextData. " ++
                "initContextData is the setup hook for a plugin's ContextData and would never be called as written. " ++
                "Add a ContextData, or remove initContextData.");
        }
        // plugin_id becomes the `context.plugins.<id>` field name verbatim, so
        // it must already be a valid Zig identifier (checked whenever declared).
        if (@hasDecl(Plugin, "plugin_id")) {
            validatePluginId(@typeName(Plugin), Plugin.plugin_id);
        }
    }
}

/// `plugin_id` becomes the `context.plugins.<id>` field name verbatim, so it
/// must be a valid Zig identifier (`[a-zA-Z_][a-zA-Z0-9_]*`). An invalid id is
/// a compile error — the framework does not silently rewrite it, because the
/// author is choosing the field name they will type in code.
fn validatePluginId(comptime type_name: []const u8, comptime id: []const u8) void {
    comptime {
        if (!isValidIdentifier(id)) {
            @compileError("plugin '" ++ type_name ++ "': plugin_id \"" ++ id ++ "\" is not a valid Zig identifier. " ++
                "It becomes the context.plugins.<id> field name you access in code, so it must match " ++
                "[a-zA-Z_][a-zA-Z0-9_]*. Use \"" ++ identifierSuggestion(id) ++ "\".");
        }
    }
}

/// Whether `id` is a valid Zig identifier: non-empty, first byte a letter or
/// '_', the rest letters, digits, or '_'.
fn isValidIdentifier(comptime id: []const u8) bool {
    comptime {
        if (id.len == 0) return false;
        for (id, 0..) |c, i| {
            const ok = std.ascii.isAlphabetic(c) or c == '_' or (i > 0 and std.ascii.isDigit(c));
            if (!ok) return false;
        }
        return true;
    }
}

/// A valid-identifier form of `id` to show in the error message: every
/// non-identifier byte becomes '_' (the shared identifier rule), with a
/// leading '_' prepended if the result would otherwise start with a digit.
fn identifierSuggestion(comptime id: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (id) |c| out = out ++ &[_]u8{identifier.sanitizeChar(c)};
        if (out.len == 0 or std.ascii.isDigit(out[0])) out = "_" ++ out;
        return out;
    }
}

fn isContractName(comptime name: []const u8) bool {
    for (contract_names) |contract| {
        if (std.mem.eql(u8, name, contract)) return true;
    }
    return false;
}

test "validatePlugin accepts a well-formed plugin with helpers" {
    const Plugin = struct {
        pub const plugin_id = "valid_plugin";
        pub const priority = 10;
        pub fn preExecute(context: anytype, args: anytype) !?@TypeOf(args) {
            _ = context;
            return args;
        }
        // A helper far from any hook name must not be flagged.
        pub fn isHelpRequested(context: anytype) bool {
            _ = context;
            return false;
        }
    };
    comptime validatePlugin(Plugin);
}

test "editDistance flags an applyConfigDefaults typo" {
    comptime {
        // The transposition the typo-guard exists to catch: this misspelling
        // compiles fine but would never be dispatched (hooks match by exact name).
        std.debug.assert(levenshtein.editDistance("applyConfigDefualts", "applyConfigDefaults") == 2);
        // A far-off helper in the same plugin must stay clear of the guard.
        std.debug.assert(levenshtein.editDistance("applyFromJsonScoped", "applyConfigDefaults") > 2);
    }
}

test "validatePlugin accepts a well-formed applyConfigDefaults hook" {
    const Plugin = struct {
        pub const plugin_id = "cfg_plugin";
        pub fn applyConfigDefaults(context: anytype, comptime OptionsType: type, options: *OptionsType, provided: []const bool, applied: []bool) void {
            _ = context;
            _ = options;
            _ = provided;
            _ = applied;
        }
    };
    comptime validatePlugin(Plugin);
}

test "validatePlugin accepts ContextData paired with a valid plugin_id" {
    const Plugin = struct {
        pub const plugin_id = "my_plugin";
        pub const ContextData = struct { count: u32 = 0 };
        pub fn deinitContextData(data: *ContextData, allocator: std.mem.Allocator) void {
            _ = data;
            _ = allocator;
        }
    };
    comptime validatePlugin(Plugin);
}

test "isValidIdentifier accepts identifiers and rejects everything else" {
    comptime {
        std.debug.assert(isValidIdentifier("zcli_help"));
        std.debug.assert(isValidIdentifier("_x9"));
        std.debug.assert(!isValidIdentifier("my-plugin"));
        std.debug.assert(!isValidIdentifier("9lives"));
        std.debug.assert(!isValidIdentifier("has space"));
        std.debug.assert(!isValidIdentifier(""));
    }
}

test "identifierSuggestion rewrites to a valid identifier" {
    comptime {
        std.debug.assert(std.mem.eql(u8, identifierSuggestion("my-plugin"), "my_plugin"));
        std.debug.assert(std.mem.eql(u8, identifierSuggestion("9lives"), "_9lives"));
    }
}

// Test basic argument transformation
test "basic argument transformation" {
    const allocator = testing.allocator;

    const TransformUppercasePlugin = struct {
        pub fn transformArgs(
            context: anytype,
            args: []const []const u8,
        ) !zcli.TransformResult {
            var new_args = try context.allocator.alloc([]const u8, args.len);
            for (args, 0..) |arg, i| {
                new_args[i] = try std.ascii.allocUpperString(context.allocator, arg);
            }
            return .{ .args = new_args };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformUppercasePlugin)
        .build();

    var app = TestRegistry.init();
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var context = zcli.Context.init(allocator, std.testing.io, &stdio, &test_environ);
    defer context.deinit();

    const args = [_][]const u8{ "hello", "world" };
    const result = try app.transformArgs(&context, &args);
    defer {
        for (result.args) |arg| {
            context.allocator.free(arg);
        }
        context.allocator.free(result.args);
    }

    try testing.expectEqualStrings(result.args[0], "HELLO");
    try testing.expectEqualStrings(result.args[1], "WORLD");
}

// Test transformation with consumption
test "transformation with argument consumption" {
    const allocator = testing.allocator;

    const TransformFilterPlugin = struct {
        pub fn transformArgs(
            context: anytype,
            args: []const []const u8,
        ) !zcli.TransformResult {
            var filtered: std.ArrayList([]const u8) = .empty;
            var consumed: std.ArrayList(usize) = .empty;
            defer filtered.deinit(context.allocator);
            defer consumed.deinit(context.allocator);

            for (args, 0..) |arg, i| {
                if (std.mem.startsWith(u8, arg, "--internal-")) {
                    try consumed.append(context.allocator, i);
                } else {
                    try filtered.append(context.allocator, arg);
                }
            }

            return .{
                .args = try filtered.toOwnedSlice(context.allocator),
                .consumed_indices = try consumed.toOwnedSlice(context.allocator),
            };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformFilterPlugin)
        .build();

    var app = TestRegistry.init();
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var context = zcli.Context.init(allocator, std.testing.io, &stdio, &test_environ);
    defer context.deinit();

    const args = [_][]const u8{ "command", "--internal-debug", "arg1", "--internal-trace", "arg2" };
    const result = try app.transformArgs(&context, &args);
    defer {
        context.allocator.free(result.args);
        context.allocator.free(result.consumed_indices);
    }

    try testing.expect(result.args.len == 3);
    try testing.expectEqualStrings(result.args[0], "command");
    try testing.expectEqualStrings(result.args[1], "arg1");
    try testing.expectEqualStrings(result.args[2], "arg2");

    try testing.expect(result.consumed_indices.len == 2);
    try testing.expect(result.consumed_indices[0] == 1); // --internal-debug
    try testing.expect(result.consumed_indices[1] == 3); // --internal-trace
}

// Test transformation chain with multiple plugins
test "transformation chain with multiple plugins" {
    const allocator = testing.allocator;

    const TransformPlugin1 = struct {
        pub const priority = 100;
        pub fn transformArgs(
            context: anytype,
            args: []const []const u8,
        ) !zcli.TransformResult {
            // Replace "alias" with "actual-command" - no allocation, just return modified view
            if (args.len > 0 and std.mem.eql(u8, args[0], "alias")) {
                // Create a new slice with the modified command (this will be cleaned up by Plugin2)
                var new_args = try context.allocator.alloc([]const u8, args.len);
                new_args[0] = "actual-command";
                if (args.len > 1) {
                    @memcpy(new_args[1..], args[1..]);
                }
                return .{ .args = new_args };
            }
            return .{ .args = args };
        }
    };

    const TransformPlugin2 = struct {
        pub const priority = 50;
        pub fn transformArgs(
            context: anytype,
            args: []const []const u8,
        ) !zcli.TransformResult {
            // Add a prefix to all arguments and free the intermediate allocation if needed
            var new_args = try context.allocator.alloc([]const u8, args.len);
            for (args, 0..) |arg, i| {
                new_args[i] = try std.fmt.allocPrint(context.allocator, "prefix-{s}", .{arg});
            }
            // Clean up intermediate allocation if it's not the original args
            // We can check by seeing if the first arg is our expected "actual-command"
            if (args.len > 0 and std.mem.eql(u8, args[0], "actual-command")) {
                // This means Plugin1 allocated the args array, so we need to free it
                context.allocator.free(args);
            }
            return .{ .args = new_args };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformPlugin1)
        .registerPlugin(TransformPlugin2)
        .build();

    var app = TestRegistry.init();
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var context = zcli.Context.init(allocator, std.testing.io, &stdio, &test_environ);
    defer context.deinit();

    const args = [_][]const u8{ "alias", "arg" };
    const result = try app.transformArgs(&context, &args);
    defer {
        for (result.args) |arg| {
            context.allocator.free(arg);
        }
        context.allocator.free(result.args);
    }

    // Plugin1 runs first (higher priority), changes "alias" to "actual-command"
    // Plugin2 runs second, adds "prefix-" to all args
    try testing.expectEqualStrings(result.args[0], "prefix-actual-command");
    try testing.expectEqualStrings(result.args[1], "prefix-arg");
}

// Test stopping transformation pipeline
test "stopping transformation pipeline" {
    const allocator = testing.allocator;

    const TransformStopPlugin = struct {
        pub fn transformArgs(
            context: anytype,
            args: []const []const u8,
        ) !zcli.TransformResult {
            _ = context;
            if (args.len > 0 and std.mem.eql(u8, args[0], "stop")) {
                return .{
                    .args = &.{},
                    .continue_processing = false,
                };
            }
            return .{ .args = args };
        }
    };

    const TransformNeverCalledPlugin = struct {
        pub var was_called = false;

        pub fn transformArgs(
            context: anytype,
            args: []const []const u8,
        ) !zcli.TransformResult {
            _ = context;
            was_called = true;
            return .{ .args = args };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformStopPlugin)
        .registerPlugin(TransformNeverCalledPlugin)
        .build();

    var app = TestRegistry.init();
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var context = zcli.Context.init(allocator, std.testing.io, &stdio, &test_environ);
    defer context.deinit();

    TransformNeverCalledPlugin.was_called = false;

    const args = [_][]const u8{ "stop", "other", "args" };
    const result = try app.transformArgs(&context, &args);

    try testing.expect(result.args.len == 0);
    try testing.expect(!result.continue_processing);
    try testing.expect(!TransformNeverCalledPlugin.was_called);
}

// Test environment variable expansion
test "environment variable expansion transformation" {
    const allocator = testing.allocator;

    const TransformEnvPlugin = struct {
        pub fn transformArgs(
            context: anytype,
            args: []const []const u8,
        ) !zcli.TransformResult {
            var new_args: std.ArrayList([]const u8) = .empty;
            defer new_args.deinit(context.allocator);

            for (args) |arg| {
                if (std.mem.startsWith(u8, arg, "$")) {
                    const env_var = arg[1..];
                    const resolved = if (@hasField(@TypeOf(context.*), "environ"))
                        context.environ.get(env_var)
                    else
                        null;
                    if (resolved) |value| {
                        try new_args.append(context.allocator, value);
                    } else {
                        try new_args.append(context.allocator, arg);
                    }
                } else {
                    try new_args.append(context.allocator, arg);
                }
            }

            return .{ .args = try new_args.toOwnedSlice(context.allocator) };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformEnvPlugin)
        .build();

    var app = TestRegistry.init();
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var context = zcli.Context.init(allocator, std.testing.io, &stdio, &test_environ);
    defer context.deinit();

    // Without environment variables set, $VAR references stay unexpanded
    const args = [_][]const u8{ "command", "$USER", "$HOME", "$NONEXISTENT" };
    const result = try app.transformArgs(&context, &args);
    defer context.allocator.free(result.args);

    try testing.expectEqualStrings(result.args[0], "command");
    // Without environ on base Context, env vars are not expanded
    try testing.expectEqualStrings(result.args[1], "$USER");
    try testing.expectEqualStrings(result.args[2], "$HOME");
    try testing.expectEqualStrings(result.args[3], "$NONEXISTENT");
}

// Test path expansion transformation
test "path expansion transformation" {
    const allocator = testing.allocator;

    const TransformPathPlugin = struct {
        pub fn transformArgs(
            context: anytype,
            args: []const []const u8,
        ) !zcli.TransformResult {
            var new_args: std.ArrayList([]const u8) = .empty;
            defer new_args.deinit(context.allocator);

            for (args) |arg| {
                if (std.mem.startsWith(u8, arg, "~/")) {
                    const home = if (@hasField(@TypeOf(context.*), "environ")) context.environ.get("HOME") orelse "/home/user" else "/home/user";
                    const expanded = try std.fmt.allocPrint(context.allocator, "{s}{s}", .{ home, arg[1..] });
                    try new_args.append(context.allocator, expanded);
                } else {
                    try new_args.append(context.allocator, arg);
                }
            }

            return .{ .args = try new_args.toOwnedSlice(context.allocator) };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformPathPlugin)
        .build();

    var app = TestRegistry.init();
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var context = zcli.Context.init(allocator, std.testing.io, &stdio, &test_environ);
    defer context.deinit();

    // Without environ on base Context, tilde expansion uses /home/user fallback
    const args = [_][]const u8{ "~/Documents/file.txt", "~/Downloads", "/absolute/path" };
    const result = try app.transformArgs(&context, &args);
    defer {
        // Only free the allocated ones (~/... paths)
        for (result.args, 0..) |arg, i| {
            if (i < 2) { // First two were expanded from ~/...
                context.allocator.free(arg);
            }
        }
        context.allocator.free(result.args);
    }

    try testing.expectEqualStrings(result.args[0], "/home/user/Documents/file.txt");
    try testing.expectEqualStrings(result.args[1], "/home/user/Downloads");
    try testing.expectEqualStrings(result.args[2], "/absolute/path");
}

// Test argument injection transformation
test "argument injection transformation" {
    const allocator = testing.allocator;

    const TransformInjectionPlugin = struct {
        pub fn transformArgs(
            context: anytype,
            args: []const []const u8,
        ) !zcli.TransformResult {
            // If user runs "commit", inject -m if not present
            if (args.len > 0 and std.mem.eql(u8, args[0], "commit")) {
                var has_message = false;
                for (args) |arg| {
                    if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
                        has_message = true;
                        break;
                    }
                }

                if (!has_message) {
                    var new_args = try context.allocator.alloc([]const u8, args.len + 2);
                    @memcpy(new_args[0..args.len], args);
                    new_args[args.len] = "-m";
                    new_args[args.len + 1] = "Auto-generated commit message";
                    return .{ .args = new_args };
                }
            }
            return .{ .args = args };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformInjectionPlugin)
        .build();

    var app = TestRegistry.init();
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var context = zcli.Context.init(allocator, std.testing.io, &stdio, &test_environ);
    defer context.deinit();

    // Test injection when -m is missing
    const args1 = [_][]const u8{ "commit", "file.txt" };
    const result1 = try app.transformArgs(&context, &args1);
    defer context.allocator.free(result1.args);

    try testing.expect(result1.args.len == 4);
    try testing.expectEqualStrings(result1.args[0], "commit");
    try testing.expectEqualStrings(result1.args[1], "file.txt");
    try testing.expectEqualStrings(result1.args[2], "-m");
    try testing.expectEqualStrings(result1.args[3], "Auto-generated commit message");

    // Test no injection when -m is present
    const args2 = [_][]const u8{ "commit", "-m", "User message", "file.txt" };
    const result2 = try app.transformArgs(&context, &args2);

    try testing.expect(result2.args.len == 4);
    try testing.expectEqualStrings(result2.args[2], "User message");
}

// Test transformation error handling
test "transformation error handling" {
    const allocator = testing.allocator;

    const TransformErrorPlugin = struct {
        pub fn transformArgs(
            context: anytype,
            args: []const []const u8,
        ) !zcli.TransformResult {
            _ = context;
            if (args.len > 0 and std.mem.eql(u8, args[0], "error")) {
                return error.TransformationFailed;
            }
            return .{ .args = args };
        }
    };

    const TestRegistry = zcli.Registry.init(.{
        .app_name = "test-app",
        .app_version = "1.0.0",
        .app_description = "Test application",
    })
        .registerPlugin(TransformErrorPlugin)
        .build();

    var app = TestRegistry.init();
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);

    const test_environ = std.process.Environ.Map.init(allocator);
    var context = zcli.Context.init(allocator, std.testing.io, &stdio, &test_environ);
    defer context.deinit();

    const args = [_][]const u8{ "error", "command" };
    const result = app.transformArgs(&context, &args);

    try testing.expectError(error.TransformationFailed, result);
}
