const std = @import("std");
const zcli = @import("zcli.zig");
const identifier = @import("identifier.zig");
const testing = std.testing;

// ============================================================================
// Core Plugin Types
// ============================================================================

/// Global option that can be registered by plugins
pub const GlobalOption = struct {
    name: []const u8,
    short: ?u8 = null,
    type: type,
    default: DefaultValue,
    description: []const u8,
    category: ?[]const u8 = null,

    pub fn validate(self: @This(), value: anytype) !void {
        // Default validation - can be overridden
        _ = self;
        _ = value;
    }

    pub fn getDefaultAsString(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
        return self.default.toString(allocator);
    }
};

/// Union to store default values of different types
pub const DefaultValue = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    unsigned: u64,
    float: f64,
    none,

    pub fn toString(self: DefaultValue, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| s,
            .boolean => |b| if (b) "true" else "false",
            .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
            .unsigned => |u| try std.fmt.allocPrint(allocator, "{d}", .{u}),
            .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
            .none => "",
        };
    }
};

/// Unified helper function for creating GlobalOptions with better ergonomics
/// The types a global option may declare: bool, integers, floats, strings,
/// and optionals of those — exactly what the registry's converter handles.
fn validateGlobalOptionType(comptime name: []const u8, comptime T: type) void {
    // Labeled switch: optionals re-dispatch on their child instead of
    // duplicating the base-type arms — mirroring convertGlobalValue's
    // recursion, so validator and converter agree on nested optionals.
    const ok = blk: switch (@typeInfo(T)) {
        .bool, .int, .float => true,
        .pointer => |ptr| ptr.size == .slice and ptr.child == u8 and ptr.is_const,
        .optional => |opt| continue :blk @typeInfo(opt.child),
        else => false,
    };
    if (!ok) {
        @compileError("global option '" ++ name ++ "' has unsupported type `" ++ @typeName(T) ++
            "`. Supported: bool, integers, floats, []const u8, and optionals of those.");
    }
}

pub fn option(comptime name: []const u8, comptime T: type, comptime config: anytype) GlobalOption {
    // Reject types the global-option pipeline cannot convert, at the point
    // of declaration — not at some later use site with a baffling error.
    comptime validateGlobalOptionType(name, T);

    // Extract fields from config, providing defaults if not present
    const short = if (@hasField(@TypeOf(config), "short")) config.short else null;
    const description = if (@hasField(@TypeOf(config), "description")) config.description else "";
    const category = if (@hasField(@TypeOf(config), "category")) config.category else null;
    const has_default = @hasField(@TypeOf(config), "default");
    const default_value = if (!has_default) blk: {
        // No default provided, create appropriate "zero" value
        break :blk switch (@typeInfo(T)) {
            .bool => DefaultValue{ .boolean = false },
            .int => |int_info| if (int_info.signedness == .signed)
                DefaultValue{ .integer = 0 }
            else
                DefaultValue{ .unsigned = 0 },
            .float => DefaultValue{ .float = 0.0 },
            .pointer => |ptr_info| if (ptr_info.size == .slice and ptr_info.child == u8)
                DefaultValue{ .string = "" }
            else
                DefaultValue{ .none = {} },
            .optional => DefaultValue{ .none = {} },
            else => DefaultValue{ .none = {} },
        };
    } else blk: {
        // Convert provided default to DefaultValue
        const default_val = config.default;
        break :blk switch (@TypeOf(default_val)) {
            bool => DefaultValue{ .boolean = default_val },
            comptime_int, u8, u16, u32, u64, usize => DefaultValue{ .unsigned = @as(u64, default_val) },
            i8, i16, i32, i64, isize => DefaultValue{ .integer = @as(i64, default_val) },
            f32, f64, comptime_float => DefaultValue{ .float = @as(f64, default_val) },
            []const u8 => DefaultValue{ .string = default_val },
            else => blk_inner: {
                // Handle string literals and other pointer types
                const type_info = @typeInfo(@TypeOf(default_val));
                if (type_info == .pointer) {
                    const ptr_info = type_info.pointer;
                    // Handle both string slices and string literals
                    if (ptr_info.child == u8 or @typeInfo(ptr_info.child) == .array) {
                        const array_info = @typeInfo(ptr_info.child);
                        if (array_info == .array and array_info.array.child == u8) {
                            break :blk_inner DefaultValue{ .string = default_val };
                        } else if (ptr_info.child == u8) {
                            break :blk_inner DefaultValue{ .string = default_val };
                        } else {
                            @compileError("Unsupported pointer type: " ++ @typeName(@TypeOf(default_val)));
                        }
                    } else {
                        @compileError("Unsupported pointer type: " ++ @typeName(@TypeOf(default_val)));
                    }
                } else {
                    @compileError("Unsupported default value type: " ++ @typeName(@TypeOf(default_val)));
                }
            },
        };
    };

    return GlobalOption{
        .name = name,
        .short = short,
        .type = T,
        .default = default_value,
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
const hook_names = [_][]const u8{
    "transformArgs",
    "handleGlobalOption",
    "preParse",
    "postParse",
    "preExecute",
    "postExecute",
    "onError",
};

/// Non-hook decl names that are part of the plugin contract (never flagged).
const contract_names = hook_names ++ [_][]const u8{
    "global_options",
    "commands",
    "priority",
    "plugin_id",
    "ContextData",
    "deinitContextData",
    "init",
};

/// Comptime backstop against silently-dead hooks. Hooks are detected by exact
/// name (`@hasDecl`), so a typo'd hook — `preExeucte` — compiles fine and
/// simply never fires. Called by Registry.registerPlugin: any *function* decl
/// whose name is within edit distance 2 of a hook (but isn't one) is rejected
/// with a pointer at the hook it resembles.
pub fn validatePlugin(comptime Plugin: type) void {
    comptime {
        if (@typeInfo(Plugin) != .@"struct") return;
        for (@typeInfo(Plugin).@"struct".decls) |decl| {
            if (isContractName(decl.name)) continue;
            // Only functions can be hooks; consts near a hook name are inert.
            if (@typeInfo(@TypeOf(@field(Plugin, decl.name))) != .@"fn") continue;
            for (hook_names) |hook| {
                // Cheap length gate before the DP — comptime branch quota.
                const len_diff = if (decl.name.len > hook.len) decl.name.len - hook.len else hook.len - decl.name.len;
                if (len_diff > 2) continue;
                if (editDistance(decl.name, hook) <= 2) {
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
        if (@hasDecl(Plugin, "ContextData") and !@hasDecl(Plugin, "plugin_id")) {
            @compileError("plugin '" ++ @typeName(Plugin) ++ "' declares ContextData but no plugin_id. " ++
                "ContextData is exposed as a typed field on context.plugins named by plugin_id. Add:\n" ++
                "    pub const plugin_id = \"my_plugin\";");
        }
        // deinitContextData is the cleanup hook for ContextData and only runs
        // when ContextData exists — without it the function is silently dead,
        // the same failure shape as a misspelled lifecycle hook above.
        if (@hasDecl(Plugin, "deinitContextData") and !@hasDecl(Plugin, "ContextData")) {
            @compileError("plugin '" ++ @typeName(Plugin) ++ "' declares deinitContextData but no ContextData. " ++
                "deinitContextData is the cleanup hook for a plugin's ContextData and would never be called as written. " ++
                "Add a ContextData, or remove deinitContextData.");
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

/// Comptime Levenshtein distance (names here are short; the DP is tiny).
fn editDistance(comptime a: []const u8, comptime b: []const u8) usize {
    comptime {
        var prev: [b.len + 1]usize = undefined;
        for (0..b.len + 1) |j| prev[j] = j;
        for (a, 0..) |ca, i| {
            var curr: [b.len + 1]usize = undefined;
            curr[0] = i + 1;
            for (b, 0..) |cb, j| {
                const cost: usize = if (ca == cb) 0 else 1;
                curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
            }
            prev = curr;
        }
        return prev[b.len];
    }
}

test "editDistance catches the classic transposition typo" {
    comptime {
        std.debug.assert(editDistance("preExeucte", "preExecute") == 2);
        std.debug.assert(editDistance("postExecute", "preExecute") == 3);
        std.debug.assert(editDistance("preExecute", "preExecute") == 0);
        std.debug.assert(editDistance("onErorr", "onError") == 2);
    }
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

// ============================================================================
// Plugin Registry Entry
// ============================================================================

/// Entry in the plugin registry (compile-time)
pub fn PluginEntry(comptime T: type) type {
    return struct {
        const PluginType = T;

        pub const has_global_options = hasGlobalOptions(T);
        pub const has_transform_args = hasTransformArgs(T);
        pub const has_handle_global_option = hasHandleGlobalOption(T);
        pub const has_pre_parse = hasPreParse(T);
        pub const has_post_parse = hasPostParse(T);
        pub const has_pre_execute = hasPreExecute(T);
        pub const has_post_execute = hasPostExecute(T);
        pub const has_on_error = hasOnError(T);
        pub const has_commands = hasCommands(T);
        pub const priority = getPriority(T);

        pub const global_options = if (has_global_options) T.global_options else [_]GlobalOption{};
        pub const commands = if (has_commands) T.commands else struct {};
    };
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
