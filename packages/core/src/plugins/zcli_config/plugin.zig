const std = @import("std");
const zcli = @import("zcli");

/// zcli-config Plugin
///
/// Transparent config file loading. Supports JSON, TOML, and YAML.
/// Add this plugin and option values automatically cascade with the same
/// precedence every source shares:
///
///   CLI flag > env var (option's `.env`) > config file > struct default.
///
/// Config only fills an option that no higher source supplied — a value passed
/// on the CLI, or read from the option's env fallback, always wins, even when it
/// happens to equal the struct default (`--count 5` beats a config `count = 10`
/// for `count: u32 = 5`).
///
/// Config file discovery (by extension):
///   1. --config <path>
///   2. .{app_name}.config.json / .toml / .yaml / .yml (in the current directory — note the leading dot)
///   3. {user config dir}/{app_name}/config.json / .toml / .yaml / .yml
///      ($XDG_CONFIG_HOME or ~/.config on POSIX; %APPDATA% on Windows)
///
/// Case 2 is discovered from the process's cwd, which an attacker can control
/// (e.g. a cloned repo containing a `.myapp.config.toml`) — so, unlike cases 1
/// and 3, applying it prints a one-line `note:` to stderr naming the file.
/// CLI/env still always win (see above), so this is a visibility fix, not a
/// trust boundary change.
///
/// Coercion: a config scalar is stringified and run through the *same* value
/// parser the CLI and env use, so every option type works from config — bools,
/// all int widths, floats, enums (incl. optionals), custom `parse` types, and
/// arrays/multi-value (from a config list). Config stays lenient: a value that
/// won't parse (bad format, out of range, unknown enum variant) is skipped with
/// a warning, never injected — see docs/DESIGN.md.
///
/// Consumer note — cwd-controlled defaults: case 2 above means anyone who can
/// get a victim to run the CLI inside a directory they control (a cloned repo,
/// an extracted archive, a shared build dir) can set the *default* for any
/// Option this plugin covers, for that one invocation. This is bounded — every
/// value still flows through the normal typed parser (no code execution),
/// content is capped at 1 MB, and a CLI flag or env var always overrides it —
/// but it is still an attacker-influenced default. Consequently: do not model
/// security-sensitive behavior (e.g. "skip verification", "disable a safety
/// check", a trusted path/URL/repo) as a plain config-overridable Option field.
/// Either keep it out of Options entirely (comptime/build-time config, as the
/// upgrade plugin does for its repo and signing key), or gate it so config
/// alone cannot flip it.
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
    const stderr = context.stderr();

    var path_allocated = false;
    var is_project_local = false;
    const path = findConfigFile(allocator, context.io, context.environ, context.app_name, data.custom_path, stderr, &path_allocated, &is_project_local) orelse return args;

    const format = detectFormat(path) orelse {
        // Unrecognized extension — warn and skip
        try stderr.print("Warning: Config file '{s}' has unrecognized extension. Use .json, .toml, .yaml, or .yml\n", .{path});
        if (path_allocated) allocator.free(path);
        return args;
    };

    const content = std.Io.Dir.cwd().readFileAlloc(context.io, path, allocator, .limited(1024 * 1024)) catch |err| {
        try stderr.print("Warning: Could not read config file '{s}': {s}\n", .{ path, @errorName(err) });
        if (path_allocated) allocator.free(path);
        return args;
    };

    data.raw_content = content;
    data.loaded_path = path;
    data.path_allocated = path_allocated;
    data.format = format;

    // Project-local config is discovered silently by cwd — the cwd is often
    // outside the user's control (e.g. a freshly cloned repo), so surface that
    // it's in effect. Global/user-level config lives in a path the user set up
    // themselves and stays silent, as does an explicit --config (already visible
    // on the command line). One line, once per invocation — not per option.
    if (is_project_local) {
        try stderr.print("note: applied config from ./{s}\n", .{path});
    }

    return args;
}

/// Called by the registry after CLI/env option parsing. `provided` is one flag
/// per Options field (in field-declaration order), true when the CLI or the
/// option's env fallback set it; config only fills fields it left false, so
/// CLI > env > config falls out of a single check.
///
/// `applied` (same keying, caller-zeroed) is the hook's report back: every
/// field this pass fills is marked, and the registry's required-option and
/// constraint checks read it directly — an explicit signal, not a value diff,
/// so a config value equal to a field's placeholder still counts as supplied
/// (#388). It doubles as config's own two-tier precedence tracker: the
/// command-scope pass runs first and marks fields it fills; the global pass
/// then skips them (without this, the second pass would overwrite a more
/// specific value).
///
/// Applies config values scoped to the current command, plus global values,
/// identically for JSON, TOML, and YAML. Top-level keys are global (apply to
/// every command); keys nested under the command path are command-scoped and
/// take precedence over global. In JSON that looks like:
///   { "output": "json",            // global — applies to all commands
///     "list": { "all": true } }    // scoped — applies only to "list" command
/// and the equivalent TOML `[list]` table / YAML `list:` mapping.
/// Precedence: CLI flag > env > command-scoped config > global config > struct default.
pub fn applyConfigDefaults(context: anytype, comptime OptionsType: type, options: *OptionsType, provided: []const bool, applied: []bool) void {
    const data = &context.plugins.zcli_config;
    const content = data.raw_content orelse return;
    const format = data.format orelse return;

    const ctx: ApplyCtx = .{
        .allocator = context.allocator,
        .stderr = context.stderr(),
        .path = data.loaded_path orelse "config",
    };

    // Command path segments, e.g. ["sprint", "create"]; used to locate the
    // command-scoped section within the config tree.
    const cmd_path = context.command_path;

    switch (format) {
        .json => applyFromJsonScoped(OptionsType, options, content, ctx, data, cmd_path, provided, applied),
        .toml => applyFromTomlScoped(OptionsType, options, content, ctx, data, cmd_path, provided, applied),
        .yaml => applyFromYamlScoped(OptionsType, options, content, ctx, data, cmd_path, provided, applied),
    }
}

/// Everything the apply pass needs beyond the parsed tree: the (arena) allocator
/// backing multi-value coercion — always the same arena that holds the parsed
/// tree, so array slices die with `deinitContextData` — a writer for
/// lenient-skip warnings, and the file path for those warnings.
const ApplyCtx = struct {
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    path: []const u8,
};

fn applyFromJsonScoped(comptime OptionsType: type, options: *OptionsType, content: []const u8, ctx_in: ApplyCtx, data: *ContextData, cmd_path: []const []const u8, provided: []const bool, applied: []bool) void {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx_in.allocator, content, .{
        .allocate = .alloc_always,
    }) catch |err| {
        warnParse(ctx_in, err);
        return;
    };
    data._parse_arena = parsed.arena;

    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    // Coerced arrays are allocated from the parse arena so they outlive `ctx`'s
    // scalar buffers and are reclaimed by deinitContextData.
    var ctx = ctx_in;
    ctx.allocator = parsed.arena.allocator();

    // Precedence: command-scoped > global > struct default (CLI/env already win,
    // since `provided` gates every field). Apply the more specific command scope
    // FIRST and mark the fields it fills (`applied`) so the global pass only
    // touches what it left untouched.
    //
    // Command scope: traverse nested objects matching the command path,
    // e.g. {"sprint": {"create": {"verbose": true}}} for path ["sprint", "create"].
    if (cmd_path.len > 0) {
        var current = obj;
        for (cmd_path) |segment| {
            if (current.get(segment)) |val| {
                if (val == .object) {
                    current = val.object;
                } else break;
            } else break;
        } else {
            applyMap(OptionsType, options, JsonMap{ .obj = current }, ctx, provided, applied);
        }
    }

    // Global values (top-level keys that match option fields).
    applyMap(OptionsType, options, JsonMap{ .obj = obj }, ctx, provided, applied);
}

fn applyFromTomlScoped(comptime OptionsType: type, options: *OptionsType, content: []const u8, ctx_in: ApplyCtx, data: *ContextData, cmd_path: []const []const u8, provided: []const bool, applied: []bool) void {
    // Parse into a dynamic table tree and keep it alive via an arena — applied
    // string values point into it, mirroring the JSON path.
    const arena = ctx_in.allocator.create(std.heap.ArenaAllocator) catch return;
    arena.* = std.heap.ArenaAllocator.init(ctx_in.allocator);
    const table = zcli.plugin_abi.config_parse.parseToml(arena.allocator(), content) catch |err| {
        arena.deinit();
        ctx_in.allocator.destroy(arena);
        warnParse(ctx_in, err);
        return;
    };
    data._parse_arena = arena;

    var ctx = ctx_in;
    ctx.allocator = arena.allocator();

    // Command scope first, then global — see applyFromJsonScoped for the ordering
    // rationale. e.g. [sprint.create] \n verbose = true  for path ["sprint", "create"].
    if (cmd_path.len > 0) {
        var current = table;
        for (cmd_path) |segment| {
            if (current.get(segment)) |val| {
                if (val == .table) {
                    current = val.table;
                } else break;
            } else break;
        } else {
            applyMap(OptionsType, options, DynMap(@TypeOf(table)){ .map = current }, ctx, provided, applied);
        }
    }

    // Global values (top-level keys that match option fields).
    applyMap(OptionsType, options, DynMap(@TypeOf(table)){ .map = table }, ctx, provided, applied);
}

fn applyFromYamlScoped(comptime OptionsType: type, options: *OptionsType, content: []const u8, ctx_in: ApplyCtx, data: *ContextData, cmd_path: []const []const u8, provided: []const bool, applied: []bool) void {
    const arena = ctx_in.allocator.create(std.heap.ArenaAllocator) catch return;
    arena.* = std.heap.ArenaAllocator.init(ctx_in.allocator);
    const root = zcli.plugin_abi.config_parse.parseYaml(arena.allocator(), content) catch |err| {
        arena.deinit();
        ctx_in.allocator.destroy(arena);
        warnParse(ctx_in, err);
        return;
    };
    data._parse_arena = arena;

    if (root != .mapping) return;
    const map = root.mapping;

    var ctx = ctx_in;
    ctx.allocator = arena.allocator();

    // Command scope first, then global — see applyFromJsonScoped for the ordering
    // rationale. e.g. sprint: \n create: \n verbose: true  for path ["sprint", "create"].
    if (cmd_path.len > 0) {
        var current = map;
        for (cmd_path) |segment| {
            if (current.get(segment)) |val| {
                if (val == .mapping) {
                    current = val.mapping;
                } else break;
            } else break;
        } else {
            applyMap(OptionsType, options, DynMap(@TypeOf(map)){ .map = current }, ctx, provided, applied);
        }
    }

    // Global values (top-level keys that match option fields).
    applyMap(OptionsType, options, DynMap(@TypeOf(map)){ .map = map }, ctx, provided, applied);
}

fn warnParse(ctx: ApplyCtx, err: anyerror) void {
    ctx.stderr.print("Warning: Could not parse config file '{s}': {s}\n", .{ ctx.path, @errorName(err) }) catch {};
}

// ---------------------------------------------------------------------------
// Format-agnostic apply
//
// Each format's value union differs only in tag names (JSON `.bool`/`.object`/
// `.array` vs serde's `.boolean`/`.table`|`.mapping`/`.array`|`.sequence`). Two
// thin adapters (`JsonMap`, `DynMap`) expose one shape — `get(name) -> ?FieldVal`
// where `FieldVal` is a scalar string, a list of scalar strings, or an
// unsupported container — so a single `applyMap` handles all three formats and
// routes every scalar through the one CLI/env value parser.
// ---------------------------------------------------------------------------

/// A config field's value, normalized across formats: a scalar rendered to its
/// string form (the shape the value parser consumes), a homogeneous list of such
/// strings (for array/multi-value options), or a container/unsupported value the
/// apply pass ignores. `buf` backs scalar renderings that aren't already strings
/// (numbers, bools); `list` slots are arena-allocated.
const FieldVal = union(enum) {
    scalar: []const u8,
    list: []const []const u8,
    unsupported,
};

/// Adapter over a `std.json.ObjectMap`.
const JsonMap = struct {
    obj: std.json.ObjectMap,

    fn get(self: JsonMap, name: []const u8, allocator: std.mem.Allocator, buf: []u8) ?FieldVal {
        const v = self.obj.get(name) orelse return null;
        return jsonValueToField(v, allocator, buf);
    }

    fn jsonValueToField(v: std.json.Value, allocator: std.mem.Allocator, buf: []u8) FieldVal {
        return switch (v) {
            .bool => |b| .{ .scalar = if (b) "true" else "false" },
            .integer => |i| .{ .scalar = std.fmt.bufPrint(buf, "{d}", .{i}) catch return .unsupported },
            .float => |f| .{ .scalar = std.fmt.bufPrint(buf, "{d}", .{f}) catch return .unsupported },
            .number_string => |s| .{ .scalar = s },
            .string => |s| .{ .scalar = s },
            .array => |arr| listFromScalars(std.json.Value, arr.items, allocator),
            .null, .object => .unsupported,
        };
    }
};

/// Adapter over a serde dynamic map (TOML `Table` / YAML `Mapping`). Both value
/// unions name their scalar tags identically, so one adapter serves both.
fn DynMap(comptime MapType: type) type {
    return struct {
        const Self = @This();
        map: MapType,

        fn get(self: Self, name: []const u8, allocator: std.mem.Allocator, buf: []u8) ?FieldVal {
            const v = self.map.get(name) orelse return null;
            return dynValueToField(@TypeOf(v), v, allocator, buf);
        }
    };
}

fn dynValueToField(comptime ValueType: type, v: ValueType, allocator: std.mem.Allocator, buf: []u8) FieldVal {
    // TOML names its list tag `.array`, YAML names it `.sequence`; each union
    // has exactly one, so pick it at comptime (referencing both in one switch
    // is a compile error against either union).
    const list_tag = if (@hasField(ValueType, "array")) "array" else "sequence";
    return switch (v) {
        .boolean => |b| .{ .scalar = if (b) "true" else "false" },
        .integer => |i| .{ .scalar = std.fmt.bufPrint(buf, "{d}", .{i}) catch return .unsupported },
        .float => |f| .{ .scalar = std.fmt.bufPrint(buf, "{d}", .{f}) catch return .unsupported },
        .string => |s| .{ .scalar = s },
        inline else => |payload, tag| if (comptime std.mem.eql(u8, @tagName(tag), list_tag))
            listFromScalars(ValueType, payload, allocator)
        else
            .unsupported, // .table / .mapping / .null_val
    };
}

/// Render an array/sequence of *scalar* values to a list of strings for
/// multi-value coercion. A non-scalar element (nested list/table) makes the
/// whole list unsupported. Each string is arena-allocated so it outlives `buf`.
fn listFromScalars(comptime ValueType: type, items: anytype, allocator: std.mem.Allocator) FieldVal {
    const out = allocator.alloc([]const u8, items.len) catch return .unsupported;
    for (items, 0..) |item, idx| {
        var elem_buf: [64]u8 = undefined;
        const fv = if (ValueType == std.json.Value)
            JsonMap.jsonValueToField(item, allocator, &elem_buf)
        else
            dynValueToField(ValueType, item, allocator, &elem_buf);
        switch (fv) {
            .scalar => |s| out[idx] = allocator.dupe(u8, s) catch return .unsupported,
            else => return .unsupported,
        }
    }
    return .{ .list = out };
}

/// Apply a normalized map onto option fields. A field is touched only if no
/// higher source set it (`provided`) and no earlier config pass already set it
/// (`applied` — command scope runs before global). Fields this pass fills are
/// marked in `applied`. Every value is coerced through the shared CLI/env value
/// parser; anything that won't parse is skipped with a warning (config is
/// lenient — never injects a bad value, and a skip does not mark the field).
fn applyMap(comptime OptionsType: type, options: *OptionsType, map: anytype, ctx: ApplyCtx, provided: []const bool, applied: []bool) void {
    const info = @typeInfo(OptionsType);
    if (info != .@"struct") return;

    inline for (info.@"struct".fields, 0..) |field, field_index| {
        // `provided`/`applied` are keyed by field-declaration order (same as the
        // parser's bitset), so index i is this field.
        if (!provided[field_index] and !applied[field_index]) {
            var buf: [64]u8 = undefined;
            if (map.get(field.name, ctx.allocator, &buf)) |fv| {
                if (applyField(field.type, &@field(options, field.name), field.name, fv, ctx)) {
                    applied[field_index] = true;
                }
            }
        }
    }
}

/// Coerce and store one field. Returns true when a value was actually applied
/// (so the caller marks it), false on a lenient skip (bad value, wrong shape).
fn applyField(comptime T: type, dest: *T, field_name: []const u8, fv: FieldVal, ctx: ApplyCtx) bool {
    if (comptime zcli.plugin_abi.config_coerce.isArrayType(T)) {
        // Multi-value option: coerce each element through the element parser.
        const Child = @typeInfo(T).pointer.child;
        switch (fv) {
            .list => |items| {
                const out = ctx.allocator.alloc(Child, items.len) catch return false;
                for (items, 0..) |s, idx| {
                    out[idx] = zcli.plugin_abi.config_coerce.parseOptionValue(Child, s) catch {
                        warnValue(ctx, field_name, s);
                        return false; // Lenient: one bad element skips the whole option.
                    };
                }
                dest.* = out;
                return true;
            },
            // A scalar for an array option: treat as a single-element list.
            .scalar => |s| {
                const parsed = zcli.plugin_abi.config_coerce.parseOptionValue(Child, s) catch {
                    warnValue(ctx, field_name, s);
                    return false;
                };
                const out = ctx.allocator.alloc(Child, 1) catch return false;
                out[0] = parsed;
                dest.* = out;
                return true;
            },
            .unsupported => return false,
        }
    }

    // Boolean flags parse by presence on the CLI, so the value parser doesn't
    // handle them; a config boolean maps directly. `bool`/`?bool` both accept
    // the "true"/"false" strings the adapters render for a config boolean.
    if (comptime zcli.plugin_abi.config_coerce.isBooleanFlag(T)) {
        switch (fv) {
            .scalar => |s| {
                if (std.mem.eql(u8, s, "true")) {
                    dest.* = true;
                    return true;
                } else if (std.mem.eql(u8, s, "false")) {
                    dest.* = false;
                    return true;
                }
                warnValue(ctx, field_name, s);
                return false;
            },
            .list, .unsupported => return false,
        }
    }

    // Scalar option (ints, floats, enums, strings, optionals, custom parse).
    switch (fv) {
        .scalar => |s| {
            dest.* = zcli.plugin_abi.config_coerce.parseOptionValue(T, s) catch {
                warnValue(ctx, field_name, s);
                return false;
            };
            return true;
        },
        .list, .unsupported => return false, // a list for a scalar option is ignored
    }
}

fn warnValue(ctx: ApplyCtx, field_name: []const u8, value: []const u8) void {
    ctx.stderr.print(
        "Warning: config '{s}' has an invalid value '{s}' for '{s}' — ignoring\n",
        .{ ctx.path, value, field_name },
    ) catch {};
}

fn detectFormat(path: []const u8) ?Format {
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    if (std.mem.endsWith(u8, path, ".toml")) return .toml;
    if (std.mem.endsWith(u8, path, ".yaml")) return .yaml;
    if (std.mem.endsWith(u8, path, ".yml")) return .yaml;
    return null;
}

/// Resolve the user-level config base directory per platform.
///   - Windows: %APPDATA% (the roaming XDG-config equivalent), else %USERPROFILE%.
///   - POSIX:   $XDG_CONFIG_HOME, else $HOME/.config.
/// The caller owns the returned string only when `allocated` is set (the
/// $HOME/.config fallback allocates; every other branch borrows from `environ`).
fn userConfigDir(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, allocated: *bool) ?[]const u8 {
    allocated.* = false;
    if (@import("builtin").os.tag == .windows) {
        if (environ.get("APPDATA")) |appdata| return appdata;
        if (environ.get("USERPROFILE")) |up| {
            const dir = std.fmt.allocPrint(allocator, "{s}\\.config", .{up}) catch return null;
            allocated.* = true;
            return dir;
        }
        return null;
    }

    if (environ.get("XDG_CONFIG_HOME")) |xdg| return xdg;
    const home = environ.get("HOME") orelse return null;
    const dir = std.fmt.allocPrint(allocator, "{s}/.config", .{home}) catch return null;
    allocated.* = true;
    return dir;
}

fn findConfigFile(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, app_name: []const u8, custom_path: ?[]const u8, stderr: *std.Io.Writer, allocated: *bool, is_project_local: *bool) ?[]const u8 {
    allocated.* = false;
    is_project_local.* = false;
    const cwd = std.Io.Dir.cwd();

    if (custom_path) |p| {
        if (p.len > 0) {
            cwd.access(io, p, .{}) catch return null;
            return p;
        }
    }

    const extensions = [_][]const u8{ ".json", ".toml", ".yaml", ".yml" };

    // Project-local: ./.{app_name}.config.{ext}
    if (firstExisting(allocator, io, cwd, stderr, "", app_name, &extensions, allocated)) |p| {
        is_project_local.* = true;
        return p;
    }

    // User-level: {config dir}/{app_name}/config.{ext}
    var base_allocated = false;
    const base = userConfigDir(allocator, environ, &base_allocated) orelse return null;
    defer if (base_allocated) allocator.free(base);

    return firstExisting(allocator, io, cwd, stderr, base, app_name, &extensions, allocated);
}

/// Return the first existing config file across the extension list, warning if
/// more than one candidate exists (ambiguous — first-in-list wins silently
/// otherwise). `base` empty selects the project-local `.{app}.config{ext}`
/// naming; a non-empty base selects `{base}/{app}/config{ext}`. The returned
/// path is always heap-allocated (`allocated` set true).
fn firstExisting(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    stderr: *std.Io.Writer,
    base: []const u8,
    app_name: []const u8,
    extensions: []const []const u8,
    allocated: *bool,
) ?[]const u8 {
    var chosen: ?[]const u8 = null;
    var extra_count: usize = 0;

    for (extensions) |ext| {
        const candidate = if (base.len == 0)
            std.fmt.allocPrint(allocator, ".{s}.config{s}", .{ app_name, ext }) catch continue
        else
            std.fmt.allocPrint(allocator, "{s}/{s}/config{s}", .{ base, app_name, ext }) catch continue;

        if (cwd.access(io, candidate, .{})) |_| {
            if (chosen == null) {
                chosen = candidate;
            } else {
                extra_count += 1;
                allocator.free(candidate);
            }
        } else |_| {
            allocator.free(candidate);
        }
    }

    if (chosen) |c| {
        if (extra_count > 0) {
            stderr.print(
                "Warning: multiple config files found; using '{s}' (found {d} more)\n",
                .{ c, extra_count },
            ) catch {};
        }
        allocated.* = true;
        return c;
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// A no-op writer for tests that don't assert on warnings.
fn nullWriter() *std.Io.Writer {
    return &nullWriterState.writer;
}
var nullWriterState = std.Io.Writer.Discarding.init(&.{});

fn testCtx(allocator: std.mem.Allocator) ApplyCtx {
    return .{ .allocator = allocator, .stderr = &nullWriterState.writer, .path = "test.cfg" };
}

// Thin test wrappers that supply the config-internal `applied` bitset (the
// registry never passes it — `applyConfigDefaults` owns it), keeping the tests
// focused on the format-specific apply behavior.
fn applyJson(comptime O: type, opts: *O, content: []const u8, ctx: ApplyCtx, data: *ContextData, cmd_path: []const []const u8, provided: []const bool) void {
    var applied = [_]bool{false} ** @typeInfo(O).@"struct".fields.len;
    applyFromJsonScoped(O, opts, content, ctx, data, cmd_path, provided, &applied);
}
fn applyToml(comptime O: type, opts: *O, content: []const u8, ctx: ApplyCtx, data: *ContextData, cmd_path: []const []const u8, provided: []const bool) void {
    var applied = [_]bool{false} ** @typeInfo(O).@"struct".fields.len;
    applyFromTomlScoped(O, opts, content, ctx, data, cmd_path, provided, &applied);
}
fn applyYaml(comptime O: type, opts: *O, content: []const u8, ctx: ApplyCtx, data: *ContextData, cmd_path: []const []const u8, provided: []const bool) void {
    var applied = [_]bool{false} ** @typeInfo(O).@"struct".fields.len;
    applyFromYamlScoped(O, opts, content, ctx, data, cmd_path, provided, &applied);
}

test "plugin structure" {
    try testing.expect(@hasDecl(@This(), "global_options"));
    try testing.expect(@hasDecl(@This(), "handleGlobalOption"));
    try testing.expect(@hasDecl(@This(), "preExecute"));
    try testing.expect(@hasDecl(@This(), "applyConfigDefaults"));
    try testing.expect(@hasDecl(@This(), "ContextData"));
    try testing.expect(@hasDecl(@This(), "deinitContextData"));
}

test "detectFormat" {
    try testing.expect(detectFormat("config.json").? == .json);
    try testing.expect(detectFormat("config.toml").? == .toml);
    try testing.expect(detectFormat("config.yaml").? == .yaml);
    try testing.expect(detectFormat("config.yml").? == .yaml);
    try testing.expect(detectFormat("config.txt") == null);
    try testing.expect(detectFormat("config") == null);
}

test "findConfigFile: returns null when no config exists" {
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    var allocated = false;
    var is_project_local = false;
    const result = findConfigFile(testing.allocator, testing.io, &environ, "nonexistent_xyz", null, nullWriter(), &allocated, &is_project_local);
    try testing.expect(result == null);
}

test "findConfigFile: custom path returns null for missing file" {
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    var allocated = false;
    var is_project_local = false;
    const result = findConfigFile(testing.allocator, testing.io, &environ, "test", "/nonexistent/path.json", nullWriter(), &allocated, &is_project_local);
    try testing.expect(result == null);
}

test "userConfigDir: POSIX XDG_CONFIG_HOME wins" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", "/custom/xdg");
    try environ.put("HOME", "/home/u");
    var allocated = false;
    const dir = userConfigDir(testing.allocator, &environ, &allocated).?;
    defer if (allocated) testing.allocator.free(dir);
    try testing.expectEqualStrings("/custom/xdg", dir);
    try testing.expect(!allocated);
}

test "userConfigDir: POSIX HOME fallback allocates ~/.config" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/home/u");
    var allocated = false;
    const dir = userConfigDir(testing.allocator, &environ, &allocated).?;
    defer if (allocated) testing.allocator.free(dir);
    try testing.expect(allocated);
    try testing.expectEqualStrings("/home/u/.config", dir);
}

test "userConfigDir: Windows APPDATA wins" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var environ = std.process.Environ.Map.init(testing.allocator);
    defer environ.deinit();
    try environ.put("APPDATA", "C:\\Users\\u\\AppData\\Roaming");
    var allocated = false;
    const dir = userConfigDir(testing.allocator, &environ, &allocated).?;
    defer if (allocated) testing.allocator.free(dir);
    try testing.expectEqualStrings("C:\\Users\\u\\AppData\\Roaming", dir);
}

test "ContextData defaults" {
    const data = ContextData{};
    try testing.expect(data.custom_path == null);
    try testing.expect(data.raw_content == null);
    try testing.expect(data.format == null);
}

test "deinitContextData: safe on empty data" {
    var data = ContextData{};
    deinitContextData(&data, testing.allocator);
}

// --- Precedence vs. CLI/env (the defect-1 regression) ---
//
// `provided[i] == true` means a higher source (CLI or env) already set the
// field; config must not touch it, even when the field equals its struct
// default. Run for all three formats.

test "JSON: provided field survives config (equal to default)" {
    const Opts = struct { count: u32 = 5 };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{ .count = 5 }; // user passed --count 5 (== default)
    const provided = [_]bool{true}; // CLI set it
    const cmd_path = [_][]const u8{};

    applyJson(Opts, &opts, "{\"count\": 10}", testCtx(allocator), &data, &cmd_path, &provided);
    try testing.expectEqual(@as(u32, 5), opts.count); // config did NOT override
}

test "TOML: provided field survives config (equal to default)" {
    const Opts = struct { count: u32 = 5 };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{ .count = 5 };
    const provided = [_]bool{true};
    const cmd_path = [_][]const u8{};

    applyToml(Opts, &opts, "count = 10\n", testCtx(allocator), &data, &cmd_path, &provided);
    try testing.expectEqual(@as(u32, 5), opts.count);
}

test "YAML: provided field survives config (equal to default)" {
    const Opts = struct { count: u32 = 5 };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{ .count = 5 };
    const provided = [_]bool{true};
    const cmd_path = [_][]const u8{};

    applyYaml(Opts, &opts, "count: 10\n", testCtx(allocator), &data, &cmd_path, &provided);
    try testing.expectEqual(@as(u32, 5), opts.count);
}

test "JSON: not-provided field IS filled from config" {
    const Opts = struct { count: u32 = 5 };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{};
    const provided = [_]bool{false};
    const cmd_path = [_][]const u8{};

    applyJson(Opts, &opts, "{\"count\": 10}", testCtx(allocator), &data, &cmd_path, &provided);
    try testing.expectEqual(@as(u32, 10), opts.count);
}

// --- Coercion matrix: every option type, from JSON and TOML/YAML ---

const Color = enum { red, green, blue };

const AllTypes = struct {
    flag: bool = false,
    name: []const u8 = "default",
    color: Color = .red,
    maybe_color: ?Color = null,
    ratio: f64 = 0.0,
    small: u16 = 0,
    tiny: i8 = 0,
    tags: []const []const u8 = &.{},
    ports: []const u16 = &.{},
};

test "JSON: full coercion matrix" {
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = AllTypes{};
    const provided = [_]bool{false} ** @typeInfo(AllTypes).@"struct".fields.len;
    const cmd_path = [_][]const u8{};
    const content =
        \\{ "flag": true, "name": "x", "color": "green", "maybe_color": "blue",
        \\  "ratio": 1.5, "small": 300, "tiny": -5,
        \\  "tags": ["a", "b"], "ports": [80, 443] }
    ;
    applyJson(AllTypes, &opts, content, testCtx(allocator), &data, &cmd_path, &provided);

    try testing.expect(opts.flag);
    try testing.expectEqualStrings("x", opts.name);
    try testing.expect(opts.color == .green);
    try testing.expect(opts.maybe_color == .blue);
    try testing.expectEqual(@as(f64, 1.5), opts.ratio);
    try testing.expectEqual(@as(u16, 300), opts.small);
    try testing.expectEqual(@as(i8, -5), opts.tiny);
    try testing.expectEqual(@as(usize, 2), opts.tags.len);
    try testing.expectEqualStrings("a", opts.tags[0]);
    try testing.expectEqual(@as(usize, 2), opts.ports.len);
    try testing.expectEqual(@as(u16, 443), opts.ports[1]);
}

test "TOML: full coercion matrix" {
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = AllTypes{};
    const provided = [_]bool{false} ** @typeInfo(AllTypes).@"struct".fields.len;
    const cmd_path = [_][]const u8{};
    const content =
        \\flag = true
        \\name = "x"
        \\color = "green"
        \\maybe_color = "blue"
        \\ratio = 1.5
        \\small = 300
        \\tiny = -5
        \\tags = ["a", "b"]
        \\ports = [80, 443]
        \\
    ;
    applyToml(AllTypes, &opts, content, testCtx(allocator), &data, &cmd_path, &provided);

    try testing.expect(opts.flag);
    try testing.expect(opts.color == .green);
    try testing.expect(opts.maybe_color == .blue);
    try testing.expectEqual(@as(f64, 1.5), opts.ratio);
    try testing.expectEqual(@as(u16, 300), opts.small);
    try testing.expectEqual(@as(i8, -5), opts.tiny);
    try testing.expectEqual(@as(usize, 2), opts.tags.len);
    try testing.expectEqual(@as(u16, 443), opts.ports[1]);
}

test "YAML: full coercion matrix" {
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = AllTypes{};
    const provided = [_]bool{false} ** @typeInfo(AllTypes).@"struct".fields.len;
    const cmd_path = [_][]const u8{};
    const content =
        \\flag: true
        \\name: x
        \\color: green
        \\maybe_color: blue
        \\ratio: 1.5
        \\small: 300
        \\tiny: -5
        \\tags:
        \\  - a
        \\  - b
        \\ports:
        \\  - 80
        \\  - 443
        \\
    ;
    applyYaml(AllTypes, &opts, content, testCtx(allocator), &data, &cmd_path, &provided);

    try testing.expect(opts.flag);
    try testing.expect(opts.color == .green);
    try testing.expect(opts.maybe_color == .blue);
    try testing.expectEqual(@as(f64, 1.5), opts.ratio);
    try testing.expectEqual(@as(u16, 300), opts.small);
    try testing.expectEqual(@as(usize, 2), opts.tags.len);
    try testing.expectEqual(@as(u16, 443), opts.ports[1]);
}

// --- Custom parse type from config ---

const Doubled = struct {
    n: u32,
    pub fn parse(s: []const u8) !Doubled {
        return .{ .n = (try std.fmt.parseInt(u32, s, 10)) * 2 };
    }
};

test "JSON: custom parse type from config string" {
    const Opts = struct { d: Doubled = .{ .n = 0 } };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{};
    const provided = [_]bool{false};
    const cmd_path = [_][]const u8{};
    applyJson(Opts, &opts, "{\"d\": \"21\"}", testCtx(allocator), &data, &cmd_path, &provided);
    try testing.expectEqual(@as(u32, 42), opts.d.n);
}

// --- Lenient skip: out-of-range and negative-into-unsigned, no panic ---

test "JSON: out-of-range int is skipped (no panic), warns" {
    const Opts = struct { count: u8 = 7 };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{};
    const provided = [_]bool{false};
    const cmd_path = [_][]const u8{};

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var ctx = testCtx(allocator);
    ctx.stderr = &aw.writer;

    applyJson(Opts, &opts, "{\"count\": 300}", ctx, &data, &cmd_path, &provided);
    try testing.expectEqual(@as(u8, 7), opts.count); // unchanged
    try testing.expect(std.mem.indexOf(u8, aw.written(), "invalid value") != null);
}

test "JSON: negative into unsigned is skipped (no panic)" {
    const Opts = struct { count: u32 = 7 };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{};
    const provided = [_]bool{false};
    const cmd_path = [_][]const u8{};
    applyJson(Opts, &opts, "{\"count\": -1}", testCtx(allocator), &data, &cmd_path, &provided);
    try testing.expectEqual(@as(u32, 7), opts.count);
}

test "JSON: unknown enum variant is skipped, warns" {
    const Opts = struct { color: Color = .red };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{};
    const provided = [_]bool{false};
    const cmd_path = [_][]const u8{};

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var ctx = testCtx(allocator);
    ctx.stderr = &aw.writer;

    applyJson(Opts, &opts, "{\"color\": \"purple\"}", ctx, &data, &cmd_path, &provided);
    try testing.expect(opts.color == .red);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "invalid value") != null);
}

// --- Malformed config warns (but the run continues) ---

test "JSON: malformed content warns" {
    const Opts = struct { x: u32 = 1 };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{};
    const provided = [_]bool{false};
    const cmd_path = [_][]const u8{};

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var ctx = testCtx(allocator);
    ctx.stderr = &aw.writer;

    applyJson(Opts, &opts, "{ this is not json", ctx, &data, &cmd_path, &provided);
    try testing.expectEqual(@as(u32, 1), opts.x);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "Could not parse") != null);
}

// --- Command scoping still works (mirrors the original suite) ---

test "JSON scoped: command scope overrides global" {
    const Opts = struct { output: []const u8 = "text" };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{};
    const provided = [_]bool{false};
    const cmd_path = [_][]const u8{"list"};

    applyJson(Opts, &opts, "{\"output\": \"json\", \"list\": {\"output\": \"table\"}}", testCtx(allocator), &data, &cmd_path, &provided);
    try testing.expectEqualStrings("table", opts.output);
}

test "JSON scoped: nested command path" {
    const Opts = struct { verbose: bool = false };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{};
    const provided = [_]bool{false};
    const cmd_path = [_][]const u8{ "sprint", "create" };

    applyJson(Opts, &opts, "{\"sprint\": {\"create\": {\"verbose\": true}}}", testCtx(allocator), &data, &cmd_path, &provided);
    try testing.expect(opts.verbose);
}

test "JSON scoped: unrelated command section ignored" {
    const Opts = struct { all: bool = false };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{};
    const provided = [_]bool{false};
    const cmd_path = [_][]const u8{"list"};

    applyJson(Opts, &opts, "{\"delete\": {\"all\": true}}", testCtx(allocator), &data, &cmd_path, &provided);
    try testing.expect(!opts.all);
}

test "TOML scoped: command scope overrides global" {
    const Opts = struct {
        output: []const u8 = "text",
        all: bool = false,
    };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{};
    const provided = [_]bool{false} ** 2;
    const cmd_path = [_][]const u8{"list"};

    applyToml(Opts, &opts, "output = \"json\"\n[list]\noutput = \"table\"\nall = true\n", testCtx(allocator), &data, &cmd_path, &provided);
    try testing.expectEqualStrings("table", opts.output);
    try testing.expect(opts.all);
}

test "YAML scoped: command scope overrides global" {
    const Opts = struct {
        output: []const u8 = "text",
        all: bool = false,
    };
    const allocator = testing.allocator;
    var data = ContextData{};
    defer deinitContextData(&data, allocator);
    var opts = Opts{};
    const provided = [_]bool{false} ** 2;
    const cmd_path = [_][]const u8{"list"};

    applyYaml(Opts, &opts, "output: json\nlist:\n  output: table\n  all: true\n", testCtx(allocator), &data, &cmd_path, &provided);
    try testing.expectEqualStrings("table", opts.output);
    try testing.expect(opts.all);
}
