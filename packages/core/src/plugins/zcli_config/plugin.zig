const std = @import("std");
const zcli = @import("zcli");

/// zcli-config Plugin
///
/// Transparent config file loading. Supports JSON, TOML, and YAML.
/// Add this plugin and option values automatically cascade:
/// CLI flags > config file > struct defaults.
///
/// Config file discovery (by extension):
///   1. --config <path>
///   2. ./{app_name}.config.json / .toml / .yaml / .yml
///   3. $XDG_CONFIG_HOME/{app_name}/config.json / .toml / .yaml / .yml
pub const plugin_id = "zcli_config";

pub const Format = enum { json, toml, yaml };

pub const ContextData = struct {
    custom_path: ?[]const u8 = null,
    loaded_path: ?[]const u8 = null,
    raw_content: ?[]const u8 = null,
    format: ?Format = null,
    path_allocated: bool = false,
    // Stores parsed arena to keep string references alive across formats
    _parse_arena: ?*std.heap.ArenaAllocator = null,
};

pub fn deinitContextData(data: *ContextData, allocator: std.mem.Allocator) void {
    if (data._parse_arena) |arena| {
        arena.deinit();
        allocator.destroy(arena);
    }
    if (data.raw_content) |c| allocator.free(c);
    if (data.path_allocated) {
        if (data.loaded_path) |p| allocator.free(p);
    }
}

pub const global_options = [_]zcli.GlobalOption{
    zcli.option("config", []const u8, .{
        .description = "Path to config file",
        .default = "",
    }),
};

pub fn handleGlobalOption(context: anytype, option_name: []const u8, value: anytype) !void {
    if (std.mem.eql(u8, option_name, "config")) {
        const path: []const u8 = if (@TypeOf(value) == []const u8) value else "";
        if (path.len > 0) {
            context.plugins.zcli_config.custom_path = path;
        }
    }
}

pub fn preExecute(context: anytype, args: zcli.ParsedArgs) !?zcli.ParsedArgs {
    const allocator = context.allocator;
    const data = &context.plugins.zcli_config;

    var path_allocated = false;
    const path = findConfigFile(allocator, context.io, context.environ, context.app_name, data.custom_path, &path_allocated) orelse return args;

    const format = detectFormat(path) orelse {
        // Unrecognized extension — warn and skip
        const stderr = context.stderr();
        try stderr.print("Warning: Config file '{s}' has unrecognized extension. Use .json, .toml, .yaml, or .yml\n", .{path});
        if (path_allocated) allocator.free(path);
        return args;
    };

    const content = std.Io.Dir.cwd().readFileAlloc(context.io, path, allocator, .limited(1024 * 1024)) catch {
        if (path_allocated) allocator.free(path);
        return args;
    };

    data.raw_content = content;
    data.loaded_path = path;
    data.path_allocated = path_allocated;
    data.format = format;

    return args;
}

/// Called by the registry after CLI option parsing.
/// Applies config values scoped to the current command, plus global values.
/// Config structure:
///   { "output": "json",            // global — applies to all commands
///     "list": { "all": true } }    // scoped — applies only to "list" command
pub fn applyConfigDefaults(context: anytype, comptime OptionsType: type, options: *OptionsType) void {
    const data = &context.plugins.zcli_config;
    const content = data.raw_content orelse return;
    const format = data.format orelse return;

    // Build command name from path (e.g., ["sprint", "create"] -> "sprint create")
    const cmd_path = context.command_path;

    switch (format) {
        .json => applyFromJsonScoped(OptionsType, options, content, context.allocator, data, cmd_path),
        .toml => applyFromTomlScoped(OptionsType, options, content, context.allocator, cmd_path),
        .yaml => applyFromYamlScoped(OptionsType, options, content, context.allocator, data, cmd_path),
    }
}

fn applyFromJsonScoped(comptime OptionsType: type, options: *OptionsType, content: []const u8, allocator: std.mem.Allocator, data: *ContextData, cmd_path: []const []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{
        .allocate = .alloc_always,
    }) catch return;
    data._parse_arena = parsed.arena;

    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    // Apply global values (top-level keys that match option fields)
    applyJsonObject(OptionsType, options, obj);

    // Apply command-scoped values by traversing nested objects matching command path
    // e.g., {"sprint": {"create": {"verbose": true}}} for path ["sprint", "create"]
    if (cmd_path.len > 0) {
        var current = obj;
        for (cmd_path) |segment| {
            if (current.get(segment)) |val| {
                if (val == .object) {
                    current = val.object;
                } else break;
            } else break;
        } else {
            applyJsonObject(OptionsType, options, current);
        }
    }
}

fn applyJsonObject(comptime OptionsType: type, options: *OptionsType, obj: std.json.ObjectMap) void {
    const info = @typeInfo(OptionsType);
    if (info != .@"struct") return;

    inline for (info.@"struct".fields) |field| {
        if (obj.get(field.name)) |value| {
            const should_apply = if (field.default_value_ptr) |default_ptr| blk: {
                const default: *const field.type = @ptrCast(@alignCast(default_ptr));
                const dest_val = @field(options, field.name);
                // Only apply if dest still has default (CLI didn't set it)
                break :blk std.meta.eql(dest_val, default.*);
            } else true;

            if (should_apply) {
                // Apply the JSON value to the option field
                if (field.type == bool) {
                    if (value == .bool) @field(options, field.name) = value.bool;
                } else if (field.type == []const u8) {
                    if (value == .string) @field(options, field.name) = value.string;
                } else if (field.type == u32 or field.type == i32 or field.type == u64 or field.type == i64) {
                    if (value == .integer) @field(options, field.name) = @intCast(value.integer);
                } else if (field.type == ?[]const u8) {
                    if (value == .string) @field(options, field.name) = value.string;
                } else if (field.type == ?u32 or field.type == ?i32 or field.type == ?u64 or field.type == ?i64) {
                    if (value == .integer) @field(options, field.name) = @intCast(value.integer);
                } else if (field.type == ?bool) {
                    if (value == .bool) @field(options, field.name) = value.bool;
                }
            }
        }
    }
}

fn applyFromTomlScoped(comptime OptionsType: type, options: *OptionsType, content: []const u8, allocator: std.mem.Allocator, _: []const []const u8) void {
    // Parse TOML directly into the options struct type using serde
    const serde = zcli.serde;
    const parsed = serde.toml.fromSlice(OptionsType, allocator, content) catch return;
    applyNonDefaults(OptionsType, options, parsed);
}

fn applyFromYamlScoped(comptime OptionsType: type, options: *OptionsType, content: []const u8, allocator: std.mem.Allocator, _: *ContextData, _: []const []const u8) void {
    // Parse YAML directly into the options struct type using serde
    const serde = zcli.serde;
    const parsed = serde.yaml.fromSlice(OptionsType, allocator, content) catch return;
    applyNonDefaults(OptionsType, options, parsed);
}

fn yamlParseBool(raw: []const u8) ?bool {
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "True") or std.mem.eql(u8, raw, "yes") or std.mem.eql(u8, raw, "on")) return true;
    if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "False") or std.mem.eql(u8, raw, "no") or std.mem.eql(u8, raw, "off")) return false;
    return null;
}

/// Copy fields from source to dest where source differs from compile-time defaults.
/// This ensures config values only override struct defaults, not CLI-provided values.
fn applyNonDefaults(comptime T: type, dest: *T, source: T) void {
    const info = @typeInfo(T);
    if (info != .@"struct") return;

    inline for (info.@"struct".fields) |field| {
        if (field.default_value_ptr) |default_ptr| {
            const default: *const field.type = @ptrCast(@alignCast(default_ptr));
            const dest_val = @field(dest, field.name);
            // Only apply config if dest still has the struct default
            // (meaning CLI didn't set it)
            if (std.meta.eql(dest_val, default.*)) {
                const src_val = @field(source, field.name);
                if (!std.meta.eql(src_val, default.*)) {
                    @field(dest, field.name) = src_val;
                }
            }
        }
    }
}

fn detectFormat(path: []const u8) ?Format {
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    if (std.mem.endsWith(u8, path, ".toml")) return .toml;
    if (std.mem.endsWith(u8, path, ".yaml")) return .yaml;
    if (std.mem.endsWith(u8, path, ".yml")) return .yaml;
    return null;
}

fn findConfigFile(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, app_name: []const u8, custom_path: ?[]const u8, allocated: *bool) ?[]const u8 {
    allocated.* = false;
    const cwd = std.Io.Dir.cwd();

    if (custom_path) |p| {
        if (p.len > 0) {
            cwd.access(io, p, .{}) catch return null;
            return p;
        }
    }

    // Project-local: ./{app_name}.config.{ext}
    const extensions = [_][]const u8{ ".json", ".toml", ".yaml", ".yml" };
    for (extensions) |ext| {
        const local_name = std.fmt.allocPrint(allocator, ".{s}.config{s}", .{ app_name, ext }) catch continue;
        if (cwd.access(io, local_name, .{})) |_| {
            allocated.* = true;
            return local_name;
        } else |_| {
            allocator.free(local_name);
        }
    }

    // User-level: $XDG_CONFIG_HOME/{app_name}/config.{ext}
    const home = environ.get("HOME") orelse return null;
    const xdg_env = environ.get("XDG_CONFIG_HOME");
    const xdg_fallback = if (xdg_env == null)
        std.fmt.allocPrint(allocator, "{s}/.config", .{home}) catch return null
    else
        null;
    defer if (xdg_fallback) |fb| allocator.free(fb);
    const xdg_base = xdg_env orelse xdg_fallback.?;

    for (extensions) |ext| {
        const user_path = std.fmt.allocPrint(allocator, "{s}/{s}/config{s}", .{ xdg_base, app_name, ext }) catch continue;
        if (cwd.access(io, user_path, .{})) |_| {
            allocated.* = true;
            return user_path;
        } else |_| {
            allocator.free(user_path);
        }
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "global_options"));
    try std.testing.expect(@hasDecl(@This(), "handleGlobalOption"));
    try std.testing.expect(@hasDecl(@This(), "preExecute"));
    try std.testing.expect(@hasDecl(@This(), "applyConfigDefaults"));
    try std.testing.expect(@hasDecl(@This(), "ContextData"));
    try std.testing.expect(@hasDecl(@This(), "deinitContextData"));
}

test "detectFormat" {
    try std.testing.expect(detectFormat("config.json").? == .json);
    try std.testing.expect(detectFormat("config.toml").? == .toml);
    try std.testing.expect(detectFormat("config.yaml").? == .yaml);
    try std.testing.expect(detectFormat("config.yml").? == .yaml);
    try std.testing.expect(detectFormat("config.txt") == null);
    try std.testing.expect(detectFormat("config") == null);
}

test "findConfigFile: returns null when no config exists" {
    var allocated = false;
    const result = findConfigFile(std.testing.allocator, "nonexistent_xyz", null, &allocated);
    try std.testing.expect(result == null);
}

test "findConfigFile: custom path returns null for missing file" {
    var allocated = false;
    const result = findConfigFile(std.testing.allocator, "test", "/nonexistent/path.json", &allocated);
    try std.testing.expect(result == null);
}

test "ContextData defaults" {
    const data = ContextData{};
    try std.testing.expect(data.custom_path == null);
    try std.testing.expect(data.raw_content == null);
    try std.testing.expect(data.format == null);
}

test "deinitContextData: safe on empty data" {
    var data = ContextData{};
    deinitContextData(&data, std.testing.allocator);
}

test "applyNonDefaults: applies config values" {
    const Opts = struct {
        verbose: bool = false,
        count: u32 = 1,
        name: []const u8 = "default",
    };

    var dest = Opts{};
    const source = Opts{ .verbose = true, .count = 5, .name = "default" };

    applyNonDefaults(Opts, &dest, source);

    try std.testing.expect(dest.verbose == true); // changed from default
    try std.testing.expectEqual(@as(u32, 5), dest.count); // changed from default
    try std.testing.expectEqualStrings("default", dest.name); // same as default, not changed
}

test "applyNonDefaults: preserves CLI values" {
    const Opts = struct {
        verbose: bool = false,
        count: u32 = 1,
    };

    // Simulate: CLI set verbose=true, config has count=10
    var dest = Opts{ .verbose = true, .count = 1 };
    const source = Opts{ .verbose = false, .count = 10 };

    applyNonDefaults(Opts, &dest, source);

    // verbose was changed from default by CLI — config should NOT override it
    // But our logic checks if dest == default, and dest.verbose = true != default false
    // So config won't touch it. Correct!
    try std.testing.expect(dest.verbose == true);
    try std.testing.expectEqual(@as(u32, 10), dest.count); // config applied
}

test "applyJsonObject: parses and applies" {
    const Opts = struct {
        all: bool = false,
        status: []const u8 = "todo",
    };

    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"all\": true}", .{ .allocate = .alloc_always });
    defer parsed.deinit();

    var opts = Opts{};
    applyJsonObject(Opts, &opts, parsed.value.object);

    try std.testing.expect(opts.all == true);
    try std.testing.expectEqualStrings("todo", opts.status);
}

test "applyJsonObject: ignores unknown fields" {
    const Opts = struct {
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"verbose\": true, \"unknown\": 42}", .{ .allocate = .alloc_always });
    defer parsed.deinit();

    var opts = Opts{};
    applyJsonObject(Opts, &opts, parsed.value.object);

    try std.testing.expect(opts.verbose == true);
}

test "applyJsonObject: respects CLI-set values (non-default)" {
    const Opts = struct {
        verbose: bool = false,
        count: u32 = 1,
    };

    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"verbose\": true, \"count\": 99}", .{ .allocate = .alloc_always });
    defer parsed.deinit();

    // Simulate CLI setting verbose=true (differs from default)
    var opts = Opts{ .verbose = true, .count = 1 };
    applyJsonObject(Opts, &opts, parsed.value.object);

    // verbose was already non-default, should NOT be overwritten
    try std.testing.expect(opts.verbose == true);
    // count was still at default, should be overwritten by config
    try std.testing.expectEqual(@as(u32, 99), opts.count);
}

test "applyFromJsonScoped: applies global values" {
    const Opts = struct {
        output: []const u8 = "text",
        all: bool = false,
    };

    const allocator = std.testing.allocator;
    const content = "{\"output\": \"json\", \"all\": true}";
    var data = ContextData{};
    var opts = Opts{};
    const cmd_path = [_][]const u8{};

    applyFromJsonScoped(Opts, &opts, content, allocator, &data, &cmd_path);

    try std.testing.expectEqualStrings("json", opts.output);
    try std.testing.expect(opts.all == true);

    // Clean up arena allocated by applyFromJsonScoped
    if (data._parse_arena) |arena| {
        arena.deinit();
        allocator.destroy(arena);
    }
}

test "applyFromJsonScoped: applies command-scoped values" {
    const Opts = struct {
        all: bool = false,
        status: []const u8 = "todo",
    };

    const allocator = std.testing.allocator;
    // "list" command section overrides "all" for that command
    const content = "{\"status\": \"done\", \"list\": {\"all\": true}}";
    var data = ContextData{};
    var opts = Opts{};
    const cmd_path = [_][]const u8{"list"};

    applyFromJsonScoped(Opts, &opts, content, allocator, &data, &cmd_path);

    // Global "status" applied
    try std.testing.expectEqualStrings("done", opts.status);
    // Command-scoped "all" applied
    try std.testing.expect(opts.all == true);

    if (data._parse_arena) |arena| {
        arena.deinit();
        allocator.destroy(arena);
    }
}

test "applyFromJsonScoped: command scope overrides global" {
    const Opts = struct {
        output: []const u8 = "text",
    };

    const allocator = std.testing.allocator;
    // Global says "json", but "list" command says "table"
    const content = "{\"output\": \"json\", \"list\": {\"output\": \"table\"}}";
    var data = ContextData{};
    var opts = Opts{};
    const cmd_path = [_][]const u8{"list"};

    applyFromJsonScoped(Opts, &opts, content, allocator, &data, &cmd_path);

    // Command-scoped value wins over global (applied second)
    try std.testing.expectEqualStrings("table", opts.output);

    if (data._parse_arena) |arena| {
        arena.deinit();
        allocator.destroy(arena);
    }
}

test "applyFromJsonScoped: nested command path" {
    const Opts = struct {
        verbose: bool = false,
    };

    const allocator = std.testing.allocator;
    // Nested path: {"sprint": {"create": {"verbose": true}}}
    const content = "{\"sprint\": {\"create\": {\"verbose\": true}}}";
    var data = ContextData{};
    var opts = Opts{};
    const cmd_path = [_][]const u8{ "sprint", "create" };

    applyFromJsonScoped(Opts, &opts, content, allocator, &data, &cmd_path);

    try std.testing.expect(opts.verbose == true);

    if (data._parse_arena) |arena| {
        arena.deinit();
        allocator.destroy(arena);
    }
}

test "applyFromJsonScoped: unrelated command section ignored" {
    const Opts = struct {
        all: bool = false,
    };

    const allocator = std.testing.allocator;
    // "delete" section should not apply to "list" command
    const content = "{\"delete\": {\"all\": true}}";
    var data = ContextData{};
    var opts = Opts{};
    const cmd_path = [_][]const u8{"list"};

    applyFromJsonScoped(Opts, &opts, content, allocator, &data, &cmd_path);

    try std.testing.expect(opts.all == false);

    if (data._parse_arena) |arena| {
        arena.deinit();
        allocator.destroy(arena);
    }
}
