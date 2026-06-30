const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const zinput = zcli.zinput;
const ztheme = zcli.ztheme;
const Theme = ztheme.Theme;

pub const meta = .{
    .description = "Add a new command to your zcli project",
    .examples = &.{
        "add command",
        "add command deploy",
        "add command users/create --description \"Create a user\"",
        "add command search --arg '{\"name\":\"query\",\"type\":\"[]const u8\"}' --option '{\"name\":\"limit\",\"type\":\"u32\",\"nullable\":true}'",
    },
    .args = .{
        .path = "Command path (e.g., 'deploy' or 'users/create'). Omit to be prompted.",
    },
    .options = .{
        .description = .{ .description = "Description of the command", .short = 'd' },
        .arg = .{ .description = "Declarative positional arg as JSON {name,type,multiple?,nullable?,description?}. Repeatable." },
        .option = .{ .description = "Declarative option as JSON {name,type,multiple?,nullable?,default?,short?,description?}. Repeatable." },
    },
};

pub const Args = struct {
    path: ?[]const u8 = null,
};

pub const Options = struct {
    description: ?[]const u8 = null,
    arg: [][]const u8 = &.{},
    option: [][]const u8 = &.{},
};

// ---------------------------------------------------------------------------
// Gathered specs — the single model both front-ends (wizard, JSON flags) build.
// `elem_type` is the element/scalar Zig type; `multiple` lifts it to a slice
// (varargs `[][]const u8` for positionals, `[]elem` for options).
// ---------------------------------------------------------------------------

const ArgSpec = struct {
    name: []const u8,
    elem_type: []const u8,
    multiple: bool,
    nullable: bool,
    description: []const u8,
};

const OptSpec = struct {
    name: []const u8,
    elem_type: []const u8,
    multiple: bool,
    nullable: bool,
    /// Rendered Zig expression for the default; present iff scalar and not nullable.
    default_expr: ?[]const u8 = null,
    short: ?u8 = null,
    description: []const u8 = "",
};

/// Option array element types zcli's parser can accumulate (see
/// packages/core/src/options/array_utils.zig).
const supported_array_elems = [_][]const u8{
    "[]const u8", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "f32", "f64",
};

fn isSupportedArrayElem(elem: []const u8) bool {
    for (supported_array_elems) |e| {
        if (std.mem.eql(u8, elem, e)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Interruptible prompt wrappers.
//
// "Go back a step" is the wizard's interpretation of Escape, not something
// zinput knows about. zinput just surfaces `back_keys` as `error.Interrupted`;
// the gather state machines catch that to rewind a step. These wrappers attach
// `back_keys` so call sites stay terse.
// ---------------------------------------------------------------------------

const back_keys = &[_]zinput.terminal.Key{.escape};

fn askText(w: *std.Io.Writer, r: *std.Io.Reader, arena: std.mem.Allocator, message: []const u8) ![]u8 {
    return zinput.text(w, r, arena, .{ .message = message, .interrupt_keys = back_keys });
}

fn askConfirm(w: *std.Io.Writer, r: *std.Io.Reader, message: []const u8, default: bool) !bool {
    return zinput.confirm(w, r, .{ .message = message, .default = default, .interrupt_keys = back_keys });
}

fn askNumber(w: *std.Io.Writer, r: *std.Io.Reader, message: []const u8, default: i64) !i64 {
    return zinput.number(w, r, .{ .message = message, .default = default, .interrupt_keys = back_keys });
}

fn askSelect(w: *std.Io.Writer, r: *std.Io.Reader, message: []const u8, choices: []const []const u8) !usize {
    return zinput.select(w, r, .{ .message = message, .choices = choices, .interrupt_keys = back_keys });
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn execute(args: Args, options: Options, context: *Context) !void {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = context.io.io;
    const stderr = context.stderr();

    // Preflight: must be inside a zcli project.
    std.Io.Dir.cwd().access(io, "src/commands", .{}) catch {
        try stderr.print("Error: Not in a zcli project directory\n", .{});
        try stderr.print("Run this command from the root of your zcli project (where build.zig is)\n", .{});
        return error.NotInZcliProject;
    };

    // Declarative mode: any --arg/--option fully specifies the command up front.
    if (options.arg.len > 0 or options.option.len > 0) {
        return declarative(arena, context, args, options);
    }

    // Otherwise: interactive on a TTY, classic skeleton when piped.
    if (!zinput.terminal.isStdinTty()) {
        return skeleton(arena, context, args, options);
    }

    return wizard(arena, context, &context.theme, args.path, options.description);
}

// ---------------------------------------------------------------------------
// Interactive wizard
// ---------------------------------------------------------------------------

fn wizard(
    arena: std.mem.Allocator,
    context: *Context,
    theme: *const Theme,
    seed_path: ?[]const u8,
    seed_description: ?[]const u8,
) !void {
    var path = seed_path;
    var description = seed_description;
    while (true) {
        switch (try runWizardOnce(arena, context, theme, path, description)) {
            .created, .cancelled => return,
            .restart => {
                path = null;
                description = null;
            },
        }
    }
}

const WizardResult = enum { created, cancelled, restart };

fn runWizardOnce(
    arena: std.mem.Allocator,
    context: *Context,
    theme: *const Theme,
    seed_path: ?[]const u8,
    seed_description: ?[]const u8,
) !WizardResult {
    const w = context.stdout();
    const r = context.stdin();
    const io = context.io.io;

    try heading(w, theme, "Add a command");
    try hint(w, theme, "src/commands/ \u{00b7} Ctrl+C to cancel any time");
    try w.writeAll("\r\n");

    // Step 1 — command path (live preview shows the file it will create).
    const path = try resolveCommandPath(arena, w, r, theme, io, seed_path);
    const file_path = try buildFilePath(arena, path.parts);
    if (!path.prompted) {
        const line = try std.fmt.allocPrint(arena, "  \u{2192} creates {s}", .{file_path});
        try paint(w, theme, line, .dim);
        try w.writeAll("\r\n");
    }

    // Step 2 — description.
    const description = blk: {
        if (seed_description) |d| break :blk d;
        const d = std.mem.trim(u8, try zinput.text(w, r, arena, .{ .message = "Description:" }), " \t\r\n");
        break :blk if (d.len == 0) "TODO: Add description" else d;
    };

    // Steps 3 & 4 — positional arguments and options.
    var args_list = std.ArrayList(ArgSpec).empty;
    try gatherArgs(arena, w, r, theme, &args_list);

    var opts_list = std.ArrayList(OptSpec).empty;
    try gatherOptions(arena, w, r, theme, &opts_list);

    // Step 5 — review, then choose what to do.
    while (true) {
        try review(arena, w, theme, path.parts, file_path, description, args_list.items, opts_list.items);
        const action = try zinput.select(w, r, .{ .message = "What next?", .choices = &.{
            "Create it",
            "Add another argument",
            "Add another option",
            "Start over",
            "Cancel",
        } });
        switch (action) {
            0 => {
                const content = try generateSource(arena, path.parts, description, args_list.items, opts_list.items);
                try writeCommandFile(arena, io, path.parts, file_path, content);
                try finish(w, theme, path.parts, file_path);
                return .created;
            },
            1 => try gatherArgs(arena, w, r, theme, &args_list),
            2 => try gatherOptions(arena, w, r, theme, &opts_list),
            3 => return .restart,
            else => {
                try w.writeAll("\r\n");
                try warn(w, theme, "  Cancelled \u{2014} nothing was written.");
                try w.writeAll("\r\n");
                return .cancelled;
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Non-interactive skeleton (piped stdin; preserves the scriptable behavior)
// ---------------------------------------------------------------------------

fn skeleton(arena: std.mem.Allocator, context: *Context, args: Args, options: Options) !void {
    const stderr = context.stderr();
    const io = context.io.io;

    const raw_path = args.path orelse {
        try stderr.print("Error: A command path is required when input is not interactive\n", .{});
        try stderr.print("Usage: zcli add command <path> [--description \"...\"]\n", .{});
        return error.MissingCommandPath;
    };

    const parts = parsePath(arena, raw_path) catch {
        try stderr.print("Error: Invalid command path: '{s}'\n", .{raw_path});
        return error.InvalidCommandPath;
    };

    const file_path = try buildFilePath(arena, parts);
    if (fileExists(io, file_path)) {
        try stderr.print("Error: Command already exists: {s}\n", .{file_path});
        return error.CommandAlreadyExists;
    }

    const description = options.description orelse "TODO: Add description";
    const content = try generateSource(arena, parts, description, &.{}, &.{});
    try writeCommandFile(arena, io, parts, file_path, content);
    try finish(context.stdout(), &context.theme, parts, file_path);
}

// ---------------------------------------------------------------------------
// Declarative mode (--arg / --option JSON)
// ---------------------------------------------------------------------------

fn declarative(arena: std.mem.Allocator, context: *Context, args: Args, options: Options) !void {
    const stderr = context.stderr();
    const io = context.io.io;

    const raw_path = args.path orelse {
        try stderr.print("Error: A command path is required\n", .{});
        try stderr.print("Usage: zcli add command <path> --arg '{{...}}' --option '{{...}}'\n", .{});
        return error.MissingCommandPath;
    };

    const parts = parsePath(arena, raw_path) catch {
        try stderr.print("Error: Invalid command path: '{s}'\n", .{raw_path});
        return error.InvalidCommandPath;
    };

    const file_path = try buildFilePath(arena, parts);
    if (fileExists(io, file_path)) {
        try stderr.print("Error: Command already exists: {s}\n", .{file_path});
        return error.CommandAlreadyExists;
    }

    var args_list = std.ArrayList(ArgSpec).empty;
    for (options.arg, 0..) |json, i| {
        const spec = parseArgJson(arena, json) catch |err| {
            try stderr.print("Error: --arg #{d} {s}: {s}\n", .{ i + 1, @errorName(err), json });
            return err;
        };
        try validateArg(stderr, &args_list, spec, i);
        try args_list.append(arena, spec);
    }

    var opts_list = std.ArrayList(OptSpec).empty;
    for (options.option, 0..) |json, i| {
        const spec = parseOptJson(arena, json) catch |err| {
            try stderr.print("Error: --option #{d} {s}: {s}\n", .{ i + 1, @errorName(err), json });
            return err;
        };
        try validateOpt(stderr, &opts_list, spec, i);
        try opts_list.append(arena, spec);
    }

    const description = options.description orelse "TODO: Add description";
    const content = try generateSource(arena, parts, description, args_list.items, opts_list.items);
    try writeCommandFile(arena, io, parts, file_path, content);
    try finish(context.stdout(), &context.theme, parts, file_path);
}

fn parseArgJson(arena: std.mem.Allocator, json: []const u8) !ArgSpec {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };

    const name = try normalizeName(arena, try jsonString(obj, "name", error.MissingName));
    const elem_type = try arena.dupe(u8, try jsonString(obj, "type", error.MissingType));
    if (elem_type.len == 0) return error.EmptyType;
    const multiple = jsonBool(obj, "multiple", false);
    // Positional varargs are []const u8 slices only.
    if (multiple and !std.mem.eql(u8, elem_type, "[]const u8")) return error.PositionalMultipleMustBeString;
    const nullable = jsonBool(obj, "nullable", false);
    const description = try arena.dupe(u8, jsonStringOr(obj, "description", ""));

    return .{
        .name = name,
        .elem_type = elem_type,
        .multiple = multiple,
        .nullable = nullable,
        .description = description,
    };
}

fn parseOptJson(arena: std.mem.Allocator, json: []const u8) !OptSpec {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };

    const name = try normalizeName(arena, try jsonString(obj, "name", error.MissingName));
    const elem_type = try arena.dupe(u8, try jsonString(obj, "type", error.MissingType));
    if (elem_type.len == 0) return error.EmptyType;
    const multiple = jsonBool(obj, "multiple", false);
    if (multiple and !isSupportedArrayElem(elem_type)) return error.UnsupportedArrayElement;
    const nullable = jsonBool(obj, "nullable", false);
    const description = try arena.dupe(u8, jsonStringOr(obj, "description", ""));

    var short: ?u8 = null;
    if (obj.get("short")) |v| switch (v) {
        .string => |s| {
            if (s.len != 1 or !std.ascii.isAlphabetic(s[0])) return error.BadShort;
            short = s[0];
        },
        else => return error.BadShort,
    };

    var default_expr: ?[]const u8 = null;
    if (multiple) {
        // List option: non-nullable defaults to an empty slice; no scalar default.
        if (!nullable) default_expr = "&.{}";
    } else if (!nullable) {
        const v = obj.get("default") orelse return error.MissingDefault; // non-nullable scalar requires a default
        default_expr = try renderDefault(arena, elem_type, v);
    }

    return .{
        .name = name,
        .elem_type = elem_type,
        .multiple = multiple,
        .nullable = nullable,
        .default_expr = default_expr,
        .short = short,
        .description = description,
    };
}

/// Render a JSON default value as a Zig expression, using light type awareness.
/// Whether `name` is a member of an `enum { a, b = 1, ... }` type string.
fn enumHasMember(enum_type: []const u8, name: []const u8) bool {
    const open = std.mem.indexOfScalar(u8, enum_type, '{') orelse return false;
    const close = std.mem.lastIndexOfScalar(u8, enum_type, '}') orelse return false;
    if (close <= open) return false;
    var it = std.mem.splitScalar(u8, enum_type[open + 1 .. close], ',');
    while (it.next()) |raw| {
        var member = std.mem.trim(u8, raw, " \t");
        // Drop an explicit value, e.g. `a = 1` -> `a`.
        if (std.mem.indexOfScalar(u8, member, '=')) |eq| {
            member = std.mem.trim(u8, member[0..eq], " \t");
        }
        if (member.len > 0 and std.mem.eql(u8, member, name)) return true;
    }
    return false;
}

fn renderDefault(arena: std.mem.Allocator, elem_type: []const u8, v: std.json.Value) ![]const u8 {
    if (std.mem.eql(u8, elem_type, "[]const u8")) {
        const s = switch (v) {
            .string => |x| x,
            else => return error.BadDefault,
        };
        return quoteString(arena, s);
    }
    if (std.mem.startsWith(u8, elem_type, "enum")) {
        const s = switch (v) {
            .string => |x| x,
            else => return error.BadDefault,
        };
        // The default must name one of the enum's members, or the generated
        // `= .<default>` won't compile.
        if (!enumHasMember(elem_type, s)) return error.BadDefault;
        return std.fmt.allocPrint(arena, ".{s}", .{s});
    }
    if (std.mem.eql(u8, elem_type, "bool")) {
        return switch (v) {
            .bool => |b| if (b) "true" else "false",
            else => error.BadDefault,
        };
    }
    // Numeric or custom type: emit the JSON scalar verbatim.
    return switch (v) {
        .integer => |x| std.fmt.allocPrint(arena, "{d}", .{x}),
        .float => |x| std.fmt.allocPrint(arena, "{d}", .{x}),
        .number_string => |x| arena.dupe(u8, x),
        .string => |x| arena.dupe(u8, x), // custom type → raw Zig expression
        .bool => |x| if (x) "true" else "false",
        else => error.BadDefault,
    };
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8, miss: anyerror) ![]const u8 {
    const v = obj.get(key) orelse return miss;
    return switch (v) {
        .string => |s| s,
        else => error.NotAString,
    };
}

fn jsonStringOr(obj: std.json.ObjectMap, key: []const u8, fallback: []const u8) []const u8 {
    const v = obj.get(key) orelse return fallback;
    return switch (v) {
        .string => |s| s,
        else => fallback,
    };
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8, fallback: bool) bool {
    const v = obj.get(key) orelse return fallback;
    return switch (v) {
        .bool => |b| b,
        else => fallback,
    };
}

fn validateArg(stderr: *std.Io.Writer, list: *std.ArrayList(ArgSpec), spec: ArgSpec, index: usize) !void {
    for (list.items) |e| {
        if (std.mem.eql(u8, e.name, spec.name)) {
            try stderr.print("Error: --arg #{d}: duplicate name '{s}'\n", .{ index + 1, spec.name });
            return error.DuplicateArg;
        }
        if (e.multiple) {
            try stderr.print("Error: --arg #{d}: a multiple argument must be last\n", .{index + 1});
            return error.MultipleNotLast;
        }
    }
    if (!spec.nullable and !spec.multiple) {
        for (list.items) |e| {
            if (e.nullable and !e.multiple) {
                try stderr.print("Error: --arg #{d}: required '{s}' cannot follow an optional argument\n", .{ index + 1, spec.name });
                return error.BadArgOrder;
            }
        }
    }
}

fn validateOpt(stderr: *std.Io.Writer, list: *std.ArrayList(OptSpec), spec: OptSpec, index: usize) !void {
    for (list.items) |e| {
        if (std.mem.eql(u8, e.name, spec.name)) {
            try stderr.print("Error: --option #{d}: duplicate name '{s}'\n", .{ index + 1, spec.name });
            return error.DuplicateOption;
        }
        if (spec.short) |c| if (e.short == c) {
            try stderr.print("Error: --option #{d}: duplicate short flag '-{c}'\n", .{ index + 1, c });
            return error.DuplicateShort;
        };
    }
}

// ---------------------------------------------------------------------------
// Step 1: command path (with live preview)
// ---------------------------------------------------------------------------

const PathResult = struct { parts: []const []const u8, prompted: bool };

const PathPreview = struct {
    theme: *const Theme,

    fn render(ctx: *anyopaque, input: []const u8, w: *std.Io.Writer) anyerror!void {
        const self: *PathPreview = @ptrCast(@alignCast(ctx));
        const trimmed = std.mem.trim(u8, input, " \t/");
        if (trimmed.len == 0) return;
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  \u{2192} creates src/commands/{s}.zig", .{trimmed}) catch return;
        try ztheme.theme(line).dim().render(w, self.theme);
    }
};

fn resolveCommandPath(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    theme: *const Theme,
    io: std.Io,
    seed: ?[]const u8,
) !PathResult {
    var pp = PathPreview{ .theme = theme };
    var seed_opt = seed;
    var prompted = false;
    while (true) {
        const raw = if (seed_opt) |s| s else blk: {
            prompted = true;
            break :blk try zinput.text(w, r, arena, .{
                .message = "Command path:",
                .preview = .{ .context = &pp, .render = PathPreview.render },
            });
        };
        seed_opt = null;

        const parts = parsePath(arena, raw) catch {
            try warn(w, theme, "  Use letters, digits, '_' and '/' (e.g. users/create).");
            try w.writeAll("\r\n");
            continue;
        };

        const file_path = try buildFilePath(arena, parts);
        if (fileExists(io, file_path)) {
            const msg = try std.fmt.allocPrint(arena, "  {s} already exists \u{2014} pick another name.", .{file_path});
            try warn(w, theme, msg);
            try w.writeAll("\r\n");
            continue;
        }

        return .{ .parts = parts, .prompted = prompted };
    }
}

/// Split a `/`-separated path into validated identifier segments.
fn parsePath(arena: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n/");
    if (trimmed.len == 0) return error.InvalidCommandPath;

    var parts = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (!isValidIdentifier(segment)) return error.InvalidCommandPath;
        try parts.append(arena, segment);
    }
    if (parts.items.len == 0) return error.InvalidCommandPath;
    return parts.items;
}

// ---------------------------------------------------------------------------
// Step 3: positional arguments
//
// Each item is gathered by a small state machine so that pressing Escape at a
// prompt (which surfaces as `error.Interrupted`) re-runs the previous prompt of that
// item. Escape at the first prompt (name) abandons the in-progress item.
// ---------------------------------------------------------------------------

const ArgKind = enum { text, integer, decimal, custom };

fn gatherArgs(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    theme: *const Theme,
    list: *std.ArrayList(ArgSpec),
) !void {
    var seen_optional = false;
    for (list.items) |a| {
        if (a.multiple) {
            try heading(w, theme, "Positional arguments");
            try hint(w, theme, "already has a multiple argument \u{2014} it must be last, so no more can be added");
            return;
        }
        if (a.nullable) seen_optional = true;
    }

    try heading(w, theme, "Positional arguments");
    try hint(w, theme, "in order; required must come before optional \u{00b7} Esc to go back");

    while (true) {
        const prompt = if (list.items.len == 0) "Add a positional argument?" else "Add another positional argument?";
        if (!try zinput.confirm(w, r, .{ .message = prompt, .default = list.items.len == 0 })) break;

        const spec = (try gatherOneArg(arena, w, r, theme, try argNames(arena, list.items), seen_optional)) orelse continue;
        try list.append(arena, spec);
        try okArg(arena, w, theme, spec);
        if (spec.multiple) {
            try hint(w, theme, "  (multiple argument must be last \u{2014} no more positionals)");
            break;
        }
        if (spec.nullable) seen_optional = true;
    }
}

const ArgStep = enum { name, description, type, multiple, required };

/// Gather one positional argument with Escape-to-go-back. Returns null if the
/// user backed out of the item (Escape at the name prompt).
fn gatherOneArg(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    theme: *const Theme,
    existing_names: []const []const u8,
    seen_optional: bool,
) !?ArgSpec {
    var name: []const u8 = "";
    var description: []const u8 = "";
    var kind: ArgKind = .text;
    var elem_type: []const u8 = "[]const u8";
    var multiple = false;
    var nullable = false;

    var step: ArgStep = .name;
    while (true) switch (step) {
        .name => {
            name = readFieldName(arena, w, r, theme, "  Name:", false, existing_names) catch |e| {
                if (e == error.Interrupted) return null;
                return e;
            };
            step = .description;
        },
        .description => {
            const d = askText(w, r, arena, "  Description:") catch |e| {
                if (e == error.Interrupted) {
                    step = .name;
                    continue;
                }
                return e;
            };
            description = std.mem.trim(u8, d, " \t\r\n");
            step = .type;
        },
        .type => {
            kind = selectArgKind(w, r) catch |e| {
                if (e == error.Interrupted) {
                    step = .description;
                    continue;
                }
                return e;
            };
            switch (kind) {
                .text => elem_type = "[]const u8",
                .integer => elem_type = "i64",
                .decimal => elem_type = "f64",
                .custom => elem_type = readZigType(arena, w, r, theme) catch |e| {
                    if (e == error.Interrupted) continue; // re-select the type
                    return e;
                },
            }
            step = .multiple;
        },
        .multiple => {
            // A positional can only repeat as []const u8 varargs.
            if (kind == .text) {
                multiple = askConfirm(w, r, "  Multiple? (captures all remaining positionals)", false) catch |e| {
                    if (e == error.Interrupted) {
                        step = .type;
                        continue;
                    }
                    return e;
                };
            } else {
                multiple = false;
            }
            step = .required;
        },
        .required => {
            if (multiple) {
                nullable = false;
            } else if (seen_optional) {
                nullable = true;
                try hint(w, theme, "  (optional \u{2014} follows an earlier optional argument)");
            } else {
                const req = askConfirm(w, r, "  Required?", true) catch |e| {
                    if (e == error.Interrupted) {
                        step = if (kind == .text) .multiple else .type;
                        continue;
                    }
                    return e;
                };
                nullable = !req;
            }
            return .{ .name = name, .elem_type = elem_type, .multiple = multiple, .nullable = nullable, .description = description };
        },
    };
}

fn selectArgKind(w: *std.Io.Writer, r: *std.Io.Reader) !ArgKind {
    const idx = try askSelect(w, r, "  Type:", &.{
        "Text          ([]const u8)",
        "Integer       (i64)",
        "Decimal       (f64)",
        "Custom Zig type\u{2026}",
    });
    return switch (idx) {
        0 => .text,
        1 => .integer,
        2 => .decimal,
        else => .custom,
    };
}

// ---------------------------------------------------------------------------
// Step 4: options
// ---------------------------------------------------------------------------

const OptKind = enum { flag, text, integer, decimal, choice, custom };

fn gatherOptions(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    theme: *const Theme,
    list: *std.ArrayList(OptSpec),
) !void {
    try heading(w, theme, "Options (flags)");
    try hint(w, theme, "Esc to go back");

    while (true) {
        const prompt = if (list.items.len == 0) "Add an option?" else "Add another option?";
        if (!try zinput.confirm(w, r, .{ .message = prompt, .default = list.items.len == 0 })) break;

        const spec = (try gatherOneOption(arena, w, r, theme, try optNames(arena, list.items), try optShorts(arena, list.items))) orelse continue;
        try list.append(arena, spec);
        try okOpt(arena, w, theme, spec);
    }
}

const OptStep = enum { name, description, type, multiple, nullable, default, short };

/// Gather one option with Escape-to-go-back. Returns null if the user backed out
/// of the item (Escape at the name prompt).
fn gatherOneOption(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    theme: *const Theme,
    existing_names: []const []const u8,
    existing_shorts: []const u8,
) !?OptSpec {
    var name: []const u8 = "";
    var description: []const u8 = "";
    var kind: OptKind = .flag;
    var elem_type: []const u8 = "bool";
    var choices: []const []const u8 = &.{};
    var multiple = false;
    var nullable = false;
    var default_expr: ?[]const u8 = null;
    var short: ?u8 = null;

    const multiple_capable = struct {
        fn f(k: OptKind) bool {
            return k == .text or k == .integer or k == .decimal;
        }
    }.f;

    var step: OptStep = .name;
    while (true) switch (step) {
        .name => {
            name = readFieldName(arena, w, r, theme, "  Name:", true, existing_names) catch |e| {
                if (e == error.Interrupted) return null;
                return e;
            };
            step = .description;
        },
        .description => {
            const d = askText(w, r, arena, "  Description:") catch |e| {
                if (e == error.Interrupted) {
                    step = .name;
                    continue;
                }
                return e;
            };
            description = std.mem.trim(u8, d, " \t\r\n");
            step = .type;
        },
        .type => {
            kind = selectOptKind(w, r) catch |e| {
                if (e == error.Interrupted) {
                    step = .description;
                    continue;
                }
                return e;
            };
            switch (kind) {
                .flag => elem_type = "bool",
                .text => elem_type = "[]const u8",
                .integer => elem_type = "i64",
                .decimal => elem_type = "f64",
                .choice => {
                    choices = readChoices(arena, w, r, theme) catch |e| {
                        if (e == error.Interrupted) continue; // re-select the type
                        return e;
                    };
                    elem_type = try buildEnumType(arena, choices);
                },
                .custom => elem_type = readZigType(arena, w, r, theme) catch |e| {
                    if (e == error.Interrupted) continue;
                    return e;
                },
            }
            step = .multiple;
        },
        .multiple => {
            if (multiple_capable(kind)) {
                multiple = askConfirm(w, r, "  Multiple? (repeatable)", false) catch |e| {
                    if (e == error.Interrupted) {
                        step = .type;
                        continue;
                    }
                    return e;
                };
            } else {
                multiple = false;
            }
            step = .nullable;
        },
        .nullable => {
            nullable = askConfirm(w, r, if (multiple) "  Nullable? (omit \u{2192} empty list)" else "  Nullable? (omit \u{2192} null)", false) catch |e| {
                if (e == error.Interrupted) {
                    step = if (multiple_capable(kind)) .multiple else .type;
                    continue;
                }
                return e;
            };
            step = .default;
        },
        .default => {
            if (nullable) {
                default_expr = null;
            } else if (multiple) {
                default_expr = "&.{}";
            } else {
                default_expr = promptOptionDefault(arena, w, r, theme, kind, choices) catch |e| {
                    if (e == error.Interrupted) {
                        step = .nullable;
                        continue;
                    }
                    return e;
                };
            }
            step = .short;
        },
        .short => {
            const want = askConfirm(w, r, "  Short flag?", false) catch |e| {
                if (e == error.Interrupted) {
                    // Skip back over the non-prompting default step when needed.
                    step = if (!nullable and !multiple) .default else .nullable;
                    continue;
                }
                return e;
            };
            if (want) {
                short = readShort(arena, w, r, theme, existing_shorts) catch |e| {
                    if (e == error.Interrupted) continue; // re-ask the short-flag yes/no
                    return e;
                };
            } else {
                short = null;
            }
            return .{
                .name = name,
                .elem_type = elem_type,
                .multiple = multiple,
                .nullable = nullable,
                .default_expr = default_expr,
                .short = short,
                .description = description,
            };
        },
    };
}

/// Prompt for an option's default value (scalar, non-nullable). Any Escape
/// surfaces as `error.Interrupted` for the caller to handle.
fn promptOptionDefault(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    theme: *const Theme,
    kind: OptKind,
    choices: []const []const u8,
) ![]const u8 {
    return switch (kind) {
        .flag => if (try askConfirm(w, r, "  Default on?", false)) "true" else "false",
        .text => try quoteString(arena, std.mem.trim(u8, try askText(w, r, arena, "  Default value:"), " \t\r\n")),
        .integer => try std.fmt.allocPrint(arena, "{d}", .{try askNumber(w, r, "  Default value:", 0)}),
        .decimal => try std.fmt.allocPrint(arena, "{d}", .{try readFloat(arena, w, r, theme, "  Default value:", 0)}),
        .choice => try std.fmt.allocPrint(arena, ".{s}", .{choices[try askSelect(w, r, "  Default:", choices)]}),
        .custom => try arena.dupe(u8, std.mem.trim(u8, try askText(w, r, arena, "  Default (Zig expression):"), " \t\r\n")),
    };
}

fn selectOptKind(w: *std.Io.Writer, r: *std.Io.Reader) !OptKind {
    const idx = try askSelect(w, r, "  Type:", &.{
        "Flag          (bool)",
        "Text          ([]const u8)",
        "Integer       (i64)",
        "Decimal       (f64)",
        "Choice        (enum)",
        "Custom Zig type\u{2026}",
    });
    return switch (idx) {
        0 => .flag,
        1 => .text,
        2 => .integer,
        3 => .decimal,
        4 => .choice,
        else => .custom,
    };
}

// ---------------------------------------------------------------------------
// Step 5: review
// ---------------------------------------------------------------------------

fn review(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    theme: *const Theme,
    parts: []const []const u8,
    file_path: []const u8,
    description: []const u8,
    args_list: []const ArgSpec,
    opts_list: []const OptSpec,
) !void {
    try heading(w, theme, "Review");

    try w.writeAll("  ");
    try paint(w, theme, try joinSpaced(arena, parts), .command);
    try w.print("  \u{2014} {s}\r\n", .{description});
    try w.writeAll("  ");
    try paint(w, theme, file_path, .dim);
    try w.writeAll("\r\n");

    if (args_list.len > 0) {
        try w.writeAll("\r\n  ");
        try paint(w, theme, "Arguments", .bold);
        try w.writeAll("\r\n");
        for (args_list) |a| {
            try w.print("    {s}  {s}  {s}  {s}\r\n", .{ a.name, argFieldType(a), argTail(a), a.description });
        }
    }

    if (opts_list.len > 0) {
        try w.writeAll("\r\n  ");
        try paint(w, theme, "Options", .bold);
        try w.writeAll("\r\n");
        for (opts_list) |o| {
            try w.writeAll("    --");
            try writeDashed(w, o.name);
            if (o.short) |c| try w.print(" -{c}", .{c});
            try w.print("  {s}  {s}  {s}\r\n", .{ try optFieldType(arena, o), try optTail(arena, o), o.description });
        }
    }
    try w.writeAll("\r\n");
}

fn finish(w: *std.Io.Writer, theme: *const Theme, parts: []const []const u8, file_path: []const u8) !void {
    try w.writeAll("\n  ");
    {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "\u{2714} Created {s}", .{file_path}) catch "\u{2714} Created command";
        try ztheme.theme(line).success().render(w, theme);
    }
    try w.writeAll("\n\n  Next steps\n");
    try w.print("    1. Implement execute() in {s}\n", .{file_path});
    try w.writeAll("    2. zig build\n");
    try w.writeAll("    3. ./zig-out/bin/<app> ");
    for (parts, 0..) |p, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(p);
    }
    try w.writeAll(" --help\n");
}

// ---------------------------------------------------------------------------
// Source generation
// ---------------------------------------------------------------------------

fn generateSource(
    arena: std.mem.Allocator,
    parts: []const []const u8,
    description: []const u8,
    args_list: []const ArgSpec,
    opts_list: []const OptSpec,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;

    try w.writeAll(
        \\const std = @import("std");
        \\const zcli = @import("zcli");
        \\const Context = @import("command_registry").Context;
        \\
        \\pub const meta = .{
        \\    .description = "
    );
    try writeEscaped(w, description);
    try w.writeAll("\",\n");

    if (args_list.len > 0) {
        try w.writeAll("    .args = .{\n");
        for (args_list) |a| {
            try w.print("        .{s} = \"", .{a.name});
            try writeEscaped(w, a.description);
            try w.writeAll("\",\n");
        }
        try w.writeAll("    },\n");
    }

    if (opts_list.len > 0) {
        try w.writeAll("    .options = .{\n");
        for (opts_list) |o| {
            try w.print("        .{s} = .{{ .description = \"", .{o.name});
            try writeEscaped(w, o.description);
            try w.writeAll("\"");
            if (o.short) |c| try w.print(", .short = '{c}'", .{c});
            try w.writeAll(" },\n");
        }
        try w.writeAll("    },\n");
    }

    try w.writeAll("    .examples = &.{\n        \"");
    try writeExample(w, parts, args_list);
    try w.writeAll("\",\n    },\n};\n\n");

    // Args struct.
    try w.writeAll("pub const Args = struct {");
    if (args_list.len == 0) {
        try w.writeAll("};\n\n");
    } else {
        try w.writeAll("\n");
        for (args_list) |a| {
            try w.print("    {s}: ", .{a.name});
            try writeArgField(w, a);
            try w.writeAll(",\n");
        }
        try w.writeAll("};\n\n");
    }

    // Options struct.
    try w.writeAll("pub const Options = struct {");
    if (opts_list.len == 0) {
        try w.writeAll("};\n\n");
    } else {
        try w.writeAll("\n");
        for (opts_list) |o| {
            try w.print("    {s}: ", .{o.name});
            try writeOptField(w, o);
            try w.writeAll(",\n");
        }
        try w.writeAll("};\n\n");
    }

    // execute. `args`/`options` are discarded until the user implements the
    // body (Zig rejects unused parameters); the hint comment names the fields.
    try w.writeAll("pub fn execute(args: Args, options: Options, context: *Context) !void {\n");
    try w.writeAll("    _ = args;\n    _ = options;\n");
    if (args_list.len == 0 and opts_list.len == 0) {
        try w.writeAll("\n");
    } else {
        try w.writeAll("    // TODO: implement. Available:");
        var first = true;
        for (args_list) |a| {
            try w.writeAll(if (first) " " else ", ");
            first = false;
            try w.print("args.{s}", .{a.name});
        }
        for (opts_list) |o| {
            try w.writeAll(if (first) " " else ", ");
            first = false;
            try w.print("options.{s}", .{o.name});
        }
        try w.writeAll("\n");
    }
    try w.writeAll("    const stdout = context.stdout();\n");
    try w.writeAll("    try stdout.print(\"TODO: Implement ");
    try writeExamplePath(w, parts);
    try w.writeAll("\\n\", .{});\n}\n");

    return aw.written();
}

fn writeArgField(w: *std.Io.Writer, a: ArgSpec) !void {
    if (a.multiple) {
        try w.writeAll("[][]const u8");
    } else if (a.nullable) {
        try w.print("?{s} = null", .{a.elem_type});
    } else {
        try w.writeAll(a.elem_type);
    }
}

fn writeOptField(w: *std.Io.Writer, o: OptSpec) !void {
    if (o.multiple) {
        if (o.nullable) {
            try w.print("?[]{s} = null", .{o.elem_type});
        } else {
            try w.print("[]{s} = &.{{}}", .{o.elem_type});
        }
    } else if (o.nullable) {
        try w.print("?{s} = null", .{o.elem_type});
    } else {
        // A non-nullable scalar option always carries a default (the wizard sets
        // one at the .default step; declarative requires it). Fail loudly rather
        // than writing `= undefined` into the user's source if that ever breaks.
        try w.print("{s} = {s}", .{ o.elem_type, o.default_expr orelse unreachable });
    }
}

fn writeExample(w: *std.Io.Writer, parts: []const []const u8, args_list: []const ArgSpec) !void {
    try writeExamplePath(w, parts);
    for (args_list) |a| {
        if (a.multiple) {
            try w.print(" {s}...", .{a.name});
        } else if (a.nullable) {
            try w.print(" [{s}]", .{a.name});
        } else {
            try w.print(" <{s}>", .{a.name});
        }
    }
}

fn writeExamplePath(w: *std.Io.Writer, parts: []const []const u8) !void {
    for (parts, 0..) |p, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(p);
    }
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => {},
        else => try w.writeByte(ch),
    };
}

fn quoteString(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.writeByte('"');
    try writeEscaped(w, s);
    try w.writeByte('"');
    return aw.written();
}

fn buildEnumType(arena: std.mem.Allocator, choices: []const []const u8) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.writeAll("enum {");
    for (choices, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(" {s}", .{c});
    }
    try w.writeAll(" }");
    return aw.written();
}

// ---------------------------------------------------------------------------
// Filesystem
// ---------------------------------------------------------------------------

fn buildFilePath(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(arena, "src/commands");
    for (parts) |p| {
        try buf.append(arena, '/');
        try buf.appendSlice(arena, p);
    }
    try buf.appendSlice(arena, ".zig");
    return buf.items;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn writeCommandFile(
    arena: std.mem.Allocator,
    io: std.Io,
    parts: []const []const u8,
    file_path: []const u8,
    content: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();

    if (parts.len > 1) {
        var dir = std.ArrayList(u8).empty;
        try dir.appendSlice(arena, "src/commands");
        for (parts[0 .. parts.len - 1]) |segment| {
            try dir.append(arena, '/');
            try dir.appendSlice(arena, segment);
            cwd.createDir(io, dir.items, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    var file = try cwd.createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

// ---------------------------------------------------------------------------
// Prompt helpers (validation + re-prompt loops)
// ---------------------------------------------------------------------------

fn readFieldName(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    theme: *const Theme,
    message: []const u8,
    allow_dash: bool,
    existing: []const []const u8,
) ![]const u8 {
    while (true) {
        const raw = std.mem.trim(u8, try askText(w, r, arena, message), " \t\r\n");
        if (raw.len == 0) {
            try warn(w, theme, "  Name cannot be empty.");
            continue;
        }
        const field = try toFieldName(arena, raw);
        if (!isValidIdentifier(field)) {
            if (allow_dash) {
                try warn(w, theme, "  Use letters, digits, '_' or '-' (must start with a letter).");
            } else {
                try warn(w, theme, "  Use letters, digits and '_' (must start with a letter).");
            }
            continue;
        }
        if (isReservedWord(field)) {
            try warn(w, theme, "  That's a Zig keyword \u{2014} pick another name.");
            continue;
        }
        var duplicate = false;
        for (existing) |e| {
            if (std.mem.eql(u8, e, field)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try warn(w, theme, "  Already used \u{2014} pick another name.");
            continue;
        }
        return field;
    }
}

fn readZigType(arena: std.mem.Allocator, w: *std.Io.Writer, r: *std.Io.Reader, theme: *const Theme) ![]const u8 {
    while (true) {
        const t = std.mem.trim(u8, try askText(w, r, arena, "  Zig type:"), " \t\r\n");
        if (t.len == 0) {
            try warn(w, theme, "  Type cannot be empty (e.g. u8, []const u8, enum { a, b }).");
            continue;
        }
        return t;
    }
}

fn readShort(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    theme: *const Theme,
    used: []const u8,
) !u8 {
    while (true) {
        const raw = std.mem.trim(u8, try askText(w, r, arena, "  Short character:"), " \t\r\n");
        if (raw.len != 1 or !std.ascii.isAlphabetic(raw[0])) {
            try warn(w, theme, "  Enter a single letter (a-z).");
            continue;
        }
        const c = raw[0];
        var duplicate = false;
        for (used) |u| {
            if (u == c) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try warn(w, theme, "  Short flag already used \u{2014} pick another.");
            continue;
        }
        return c;
    }
}

fn readFloat(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    theme: *const Theme,
    message: []const u8,
    default: f64,
) !f64 {
    while (true) {
        const raw = std.mem.trim(u8, try askText(w, r, arena, message), " \t\r\n");
        if (raw.len == 0) return default;
        return std.fmt.parseFloat(f64, raw) catch {
            try warn(w, theme, "  Enter a number (e.g. 1.5).");
            continue;
        };
    }
}

fn readChoices(arena: std.mem.Allocator, w: *std.Io.Writer, r: *std.Io.Reader, theme: *const Theme) ![]const []const u8 {
    while (true) {
        const raw = try askText(w, r, arena, "  Choices (comma-separated):");
        var list = std.ArrayList([]const u8).empty;
        var ok = true;
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |piece| {
            const choice = std.mem.trim(u8, piece, " \t\r\n");
            if (choice.len == 0) continue;
            if (!isValidIdentifier(choice) or isReservedWord(choice)) {
                ok = false;
                break;
            }
            try list.append(arena, choice);
        }
        if (!ok or list.items.len < 2) {
            try warn(w, theme, "  Enter at least two identifier choices (e.g. json, yaml).");
            continue;
        }
        return list.items;
    }
}

// ---------------------------------------------------------------------------
// Names & validation
// ---------------------------------------------------------------------------

fn isValidIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;
    for (name[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

/// Normalize a name to a Zig field name (dashes → underscores) and validate it.
fn normalizeName(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const field = try toFieldName(arena, trimmed);
    if (!isValidIdentifier(field)) return error.InvalidName;
    if (isReservedWord(field)) return error.ReservedName;
    return field;
}

fn toFieldName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, name);
    for (out) |*ch| {
        if (ch.* == '-') ch.* = '_';
    }
    return out;
}

fn writeDashed(w: *std.Io.Writer, field: []const u8) !void {
    for (field) |ch| {
        try w.writeByte(if (ch == '_') '-' else ch);
    }
}

const reserved_words = [_][]const u8{
    "addrspace", "align",       "allowzero",      "and",      "anyframe",    "anytype",
    "asm",       "async",       "await",          "break",    "callconv",    "catch",
    "comptime",  "const",       "continue",       "defer",    "else",        "enum",
    "errdefer",  "error",       "export",         "extern",   "fn",          "for",
    "if",        "inline",      "noalias",        "noinline", "nosuspend",   "opaque",
    "or",        "orelse",      "packed",         "pub",      "resume",      "return",
    "struct",    "suspend",     "switch",         "test",     "threadlocal", "try",
    "union",     "unreachable", "usingnamespace", "var",      "volatile",    "while",
};

fn isReservedWord(name: []const u8) bool {
    for (reserved_words) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}

fn argNames(arena: std.mem.Allocator, list: []const ArgSpec) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (list) |a| try out.append(arena, a.name);
    return out.items;
}

fn optNames(arena: std.mem.Allocator, list: []const OptSpec) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (list) |o| try out.append(arena, o.name);
    return out.items;
}

fn optShorts(arena: std.mem.Allocator, list: []const OptSpec) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (list) |o| if (o.short) |c| try out.append(arena, c);
    return out.items;
}

// ---------------------------------------------------------------------------
// Display helpers
// ---------------------------------------------------------------------------

fn argFieldType(a: ArgSpec) []const u8 {
    return if (a.multiple) "[][]const u8" else a.elem_type;
}

fn optFieldType(arena: std.mem.Allocator, o: OptSpec) ![]const u8 {
    return if (o.multiple) std.fmt.allocPrint(arena, "[]{s}", .{o.elem_type}) else o.elem_type;
}

fn argTail(a: ArgSpec) []const u8 {
    if (a.multiple) return "multiple (rest)";
    return if (a.nullable) "optional" else "required";
}

fn optTail(arena: std.mem.Allocator, o: OptSpec) ![]const u8 {
    if (o.multiple) return if (o.nullable) "nullable list" else "repeatable";
    if (o.nullable) return "nullable";
    return std.fmt.allocPrint(arena, "default {s}", .{o.default_expr orelse "?"});
}

// ---------------------------------------------------------------------------
// Styling helpers
// ---------------------------------------------------------------------------

const PaintStyle = enum { bold, dim, success, warning, command };

fn paint(w: *std.Io.Writer, theme: *const Theme, text: []const u8, style: PaintStyle) !void {
    const t = ztheme.theme(text);
    switch (style) {
        .bold => try t.bold().render(w, theme),
        .dim => try t.dim().render(w, theme),
        .success => try t.success().render(w, theme),
        .warning => try t.warning().render(w, theme),
        .command => try t.command().render(w, theme),
    }
}

fn heading(w: *std.Io.Writer, theme: *const Theme, text: []const u8) !void {
    try w.writeAll("\r\n  ");
    try paint(w, theme, text, .bold);
    try w.writeAll("\r\n");
}

fn hint(w: *std.Io.Writer, theme: *const Theme, text: []const u8) !void {
    try w.writeAll("  ");
    try paint(w, theme, text, .dim);
    try w.writeAll("\r\n");
}

fn warn(w: *std.Io.Writer, theme: *const Theme, text: []const u8) !void {
    try w.writeAll("  ");
    try paint(w, theme, text, .warning);
    try w.writeAll("\r\n");
}

fn okArg(arena: std.mem.Allocator, w: *std.Io.Writer, theme: *const Theme, a: ArgSpec) !void {
    const line = try std.fmt.allocPrint(arena, "  \u{2714} {s}  {s} \u{00b7} {s}", .{ a.name, argFieldType(a), argTail(a) });
    try w.writeAll(" ");
    try paint(w, theme, line, .success);
    try w.writeAll("\r\n");
}

fn okOpt(arena: std.mem.Allocator, w: *std.Io.Writer, theme: *const Theme, o: OptSpec) !void {
    var flag = std.ArrayList(u8).empty;
    try flag.appendSlice(arena, "--");
    for (o.name) |ch| try flag.append(arena, if (ch == '_') '-' else ch);
    if (o.short) |c| {
        try flag.appendSlice(arena, " / -");
        try flag.append(arena, c);
    }
    const line = try std.fmt.allocPrint(arena, "  \u{2714} {s}  {s} \u{00b7} {s}", .{ flag.items, try optFieldType(arena, o), try optTail(arena, o) });
    try w.writeAll(" ");
    try paint(w, theme, line, .success);
    try w.writeAll("\r\n");
}

fn joinSpaced(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (parts, 0..) |p, i| {
        if (i > 0) try buf.append(arena, ' ');
        try buf.appendSlice(arena, p);
    }
    return buf.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "isValidIdentifier accepts identifiers, rejects junk" {
    try testing.expect(isValidIdentifier("deploy"));
    try testing.expect(isValidIdentifier("_hidden"));
    try testing.expect(!isValidIdentifier("2cool"));
    try testing.expect(!isValidIdentifier("has-dash"));
    try testing.expect(!isValidIdentifier(""));
}

test "parsePath splits and validates segments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parts = try parsePath(a, "users/create");
    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expectEqualStrings("users", parts[0]);
    try testing.expectEqualStrings("create", parts[1]);
    try testing.expectError(error.InvalidCommandPath, parsePath(a, ""));
    try testing.expectError(error.InvalidCommandPath, parsePath(a, "bad-seg"));
}

test "generateSource: empty command is the minimal skeleton" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parts = try parsePath(a, "ping");
    const src = try generateSource(a, parts, "TODO: Add description", &.{}, &.{});

    try expectContains(src, "pub const Args = struct {};");
    try expectContains(src, "pub const Options = struct {};");
    try expectContains(src, "_ = args;");
    try expectContains(src, "\"ping\"");
    try expectContains(src, "TODO: Implement ping");
    try testing.expect(std.mem.indexOf(u8, src, ".args = .{") == null);
}

test "generateSource: multiple is independent of element type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parts = try parsePath(a, "users/create");
    const args_list = [_]ArgSpec{
        .{ .name = "email", .elem_type = "[]const u8", .multiple = false, .nullable = false, .description = "Email" },
        .{ .name = "age", .elem_type = "u8", .multiple = false, .nullable = true, .description = "Age" },
        .{ .name = "names", .elem_type = "[]const u8", .multiple = true, .nullable = false, .description = "Names" },
    };
    const opts_list = [_]OptSpec{
        .{ .name = "verbose", .elem_type = "bool", .multiple = false, .nullable = false, .default_expr = "false", .short = 'v', .description = "Verbose" },
        .{ .name = "format", .elem_type = "enum { json, yaml }", .multiple = false, .nullable = false, .default_expr = ".yaml", .description = "Format" },
        .{ .name = "ports", .elem_type = "u32", .multiple = true, .nullable = false, .description = "Ports" },
        .{ .name = "ratios", .elem_type = "f64", .multiple = true, .nullable = true, .description = "Ratios" },
        .{ .name = "tags", .elem_type = "[]const u8", .multiple = true, .nullable = false, .description = "Tags" },
    };

    const src = try generateSource(a, parts, "Create a user", &args_list, &opts_list);

    try expectContains(src, "email: []const u8,");
    try expectContains(src, "age: ?u8 = null,");
    try expectContains(src, "names: [][]const u8,"); // positional varargs
    try expectContains(src, "verbose: bool = false,");
    try expectContains(src, "format: enum { json, yaml } = .yaml,");
    try expectContains(src, "ports: []u32 = &.{},"); // multiple integer option
    try expectContains(src, "ratios: ?[]f64 = null,"); // nullable multiple
    try expectContains(src, "tags: [][]const u8 = &.{},"); // multiple string option
    try expectContains(src, "\"users create <email> [age] names...\"");
}

test "parseOptJson: multiple is a separate flag, not a type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ints = try parseOptJson(a, "{\"name\":\"ports\",\"type\":\"u32\",\"multiple\":true}");
    try testing.expect(ints.multiple);
    try testing.expectEqualStrings("u32", ints.elem_type);
    try testing.expectEqualStrings("&.{}", ints.default_expr.?);

    const nullable_list = try parseOptJson(a, "{\"name\":\"ports\",\"type\":\"i64\",\"multiple\":true,\"nullable\":true}");
    try testing.expect(nullable_list.default_expr == null);

    const scalar = try parseOptJson(a, "{\"name\":\"retries\",\"type\":\"u32\",\"default\":3}");
    try testing.expectEqualStrings("3", scalar.default_expr.?);
    try testing.expectError(error.UnsupportedArrayElement, parseOptJson(a, "{\"name\":\"x\",\"type\":\"bool\",\"multiple\":true}"));
    try testing.expectError(error.MissingDefault, parseOptJson(a, "{\"name\":\"x\",\"type\":\"u32\"}"));
}

test "parseOptJson: enum default must name a member" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = try parseOptJson(a, "{\"name\":\"format\",\"type\":\"enum { json, yaml }\",\"default\":\"yaml\"}");
    try testing.expectEqualStrings(".yaml", ok.default_expr.?);
    // A default that isn't a member would generate `= .xml`, which won't compile.
    try testing.expectError(error.BadDefault, parseOptJson(a, "{\"name\":\"format\",\"type\":\"enum { json, yaml }\",\"default\":\"xml\"}"));
}

test "enumHasMember handles explicit values and spacing" {
    try testing.expect(enumHasMember("enum { json, yaml }", "json"));
    try testing.expect(enumHasMember("enum { a = 1, b = 2 }", "b"));
    try testing.expect(!enumHasMember("enum { json, yaml }", "xml"));
    try testing.expect(!enumHasMember("enum {}", "x"));
}

test "parseArgJson: positional multiple must be a string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = try parseArgJson(a, "{\"name\":\"names\",\"type\":\"[]const u8\",\"multiple\":true}");
    try testing.expect(ok.multiple);
    try testing.expectError(error.PositionalMultipleMustBeString, parseArgJson(a, "{\"name\":\"nums\",\"type\":\"u8\",\"multiple\":true}"));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\nexpected to find:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
        return error.SubstringNotFound;
    }
}
