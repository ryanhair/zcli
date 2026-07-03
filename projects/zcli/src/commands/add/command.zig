const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const zinput = zcli.zinput;
const ztheme = zcli.ztheme;
const Theme = ztheme.Theme;

// The shared arg/option spec model plus its rendering, type, name, and path
// helpers live in the `scaffold` library (single source of truth, shared with
// `add option`/`add arg`). Aliased here so this file's call sites are unchanged.
const scaffold = @import("scaffold");
const ArgSpec = scaffold.spec.ArgSpec;
const OptSpec = scaffold.spec.OptSpec;
const buildEnumType = scaffold.spec.buildEnumType;
const writeEscaped = scaffold.spec.writeEscaped;
const quoteString = scaffold.spec.quoteString;
const writeArgField = scaffold.spec.writeArgFieldType;
const writeOptField = scaffold.spec.writeOptFieldType;
const writeDashed = scaffold.spec.writeDashed;
const parsePath = scaffold.spec.parsePath;
const buildFilePath = scaffold.spec.buildFilePath;
const isValidIdentifier = scaffold.spec.isValidIdentifier;
const isReservedWord = scaffold.spec.isReservedWord;
const toFieldName = scaffold.spec.toFieldName;
const normalizeName = scaffold.spec.normalizeName;

pub const meta = .{
    .description = "Add a new command to your zcli project",
    .examples = &.{
        "add command",
        "add command deploy",
        "add command users/create --description \"Create a user\"",
    },
    .args = .{
        .path = "Command path (e.g., 'deploy' or 'users/create'). Omit to be prompted.",
    },
    .options = .{
        .description = .{ .description = "Description of the command", .short = 'd' },
    },
};

pub const Args = struct {
    path: ?[]const u8 = null,
};

pub const Options = struct {
    description: ?[]const u8 = null,
};

// Wizard prompts pass `.interrupt_keys = back_keys` so Escape aborts with
// `error.Interrupted`; the gather state machines catch that to rewind a step.
// "Go back" is the wizard's interpretation — zinput just reports the key.
const back_keys = &[_]zinput.terminal.Key{.escape};

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

    // Interactive on a TTY, classic skeleton when piped. Args and options are
    // added afterward with `add arg`/`add option` (ADR-0005) or, interactively,
    // through the wizard's own prompts.
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
                const new_groups = try writeCommandFile(arena, io, path.parts, file_path, content);
                try finish(w, theme, path.parts, file_path, new_groups);
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
    const new_groups = try writeCommandFile(arena, io, parts, file_path, content);
    try finish(context.stdout(), &context.theme, parts, file_path, new_groups);
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
            const d = zinput.text(w, r, arena, .{ .message = "  Description:", .interrupt_keys = back_keys }) catch |e| {
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
                multiple = zinput.confirm(w, r, .{ .message = "  Multiple? (captures all remaining positionals)", .default = false, .interrupt_keys = back_keys }) catch |e| {
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
                const req = zinput.confirm(w, r, .{ .message = "  Required?", .default = true, .interrupt_keys = back_keys }) catch |e| {
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
    const idx = try zinput.select(w, r, .{
        .message = "  Type:",
        .interrupt_keys = back_keys,
        .choices = &.{
            "Text          ([]const u8)",
            "Integer       (i64)",
            "Decimal       (f64)",
            "Custom Zig type\u{2026}",
        },
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
            const d = zinput.text(w, r, arena, .{ .message = "  Description:", .interrupt_keys = back_keys }) catch |e| {
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
                multiple = zinput.confirm(w, r, .{ .message = "  Multiple? (repeatable)", .default = false, .interrupt_keys = back_keys }) catch |e| {
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
            nullable = zinput.confirm(w, r, .{ .message = if (multiple) "  Nullable? (omit \u{2192} empty list)" else "  Nullable? (omit \u{2192} null)", .default = false, .interrupt_keys = back_keys }) catch |e| {
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
            const want = zinput.confirm(w, r, .{ .message = "  Short flag?", .default = false, .interrupt_keys = back_keys }) catch |e| {
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
        .flag => if (try zinput.confirm(w, r, .{ .message = "  Default on?", .default = false, .interrupt_keys = back_keys })) "true" else "false",
        .text => try quoteString(arena, std.mem.trim(u8, try zinput.text(w, r, arena, .{ .message = "  Default value:", .interrupt_keys = back_keys }), " \t\r\n")),
        .integer => try std.fmt.allocPrint(arena, "{d}", .{try zinput.number(w, r, .{ .message = "  Default value:", .default = 0, .interrupt_keys = back_keys })}),
        .decimal => try std.fmt.allocPrint(arena, "{d}", .{try readFloat(arena, w, r, theme, "  Default value:", 0)}),
        .choice => try std.fmt.allocPrint(arena, ".{s}", .{choices[try zinput.select(w, r, .{ .message = "  Default:", .choices = choices, .interrupt_keys = back_keys })]}),
        .custom => try arena.dupe(u8, std.mem.trim(u8, try zinput.text(w, r, arena, .{ .message = "  Default (Zig expression):", .interrupt_keys = back_keys }), " \t\r\n")),
    };
}

fn selectOptKind(w: *std.Io.Writer, r: *std.Io.Reader) !OptKind {
    const idx = try zinput.select(w, r, .{
        .message = "  Type:",
        .interrupt_keys = back_keys,
        .choices = &.{
            "Flag          (bool)",
            "Text          ([]const u8)",
            "Integer       (i64)",
            "Decimal       (f64)",
            "Choice        (enum)",
            "Custom Zig type\u{2026}",
        },
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

fn finish(
    w: *std.Io.Writer,
    theme: *const Theme,
    parts: []const []const u8,
    file_path: []const u8,
    new_groups: []const NewGroup,
) !void {
    try w.writeAll("\n  ");
    {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "\u{2714} Created {s}", .{file_path}) catch "\u{2714} Created command";
        try ztheme.theme(line).success().render(w, theme);
    }

    // A nested path can bring new group directories into being; a fresh group
    // has no index.zig, so it has no description in help or `tree`.
    for (new_groups) |g| {
        try w.writeAll("\n  ");
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "Note: new group '{s}' has no description.", .{g.name}) catch "Note: new group has no description.";
        try ztheme.theme(line).warning().render(w, theme);
        try w.print("\n    Describe it with `zcli add group {s} -d \"...\"`.\n", .{g.name});
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
    try w.writeAll("\",\n    },\n");
    // Surface the rest of the authored meta so the shell shows the full
    // surface `tree --show-options` reads back (commented until the author
    // wants them).
    try w.writeAll("    // .aliases = &.{\"alias\"}, // alternate names this command answers to\n");
    try w.writeAll("    // .hidden = true,          // omit from help and tree listings\n");
    try w.writeAll("};\n\n");

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

    // Co-located unit test — runs under `zig build test` (init wires the step).
    try writeTestBlock(w, parts);

    return aw.written();
}

/// Emit a co-located placeholder `test` block — a starting point the author
/// fleshes out. It always compiles and passes; the comment shows the
/// `zcli-testing` runCommand pattern for a real assertion. `zig build test`
/// (wired by `zcli.addCommandTests`) discovers and runs it.
fn writeTestBlock(w: *std.Io.Writer, parts: []const []const u8) !void {
    try w.writeAll("\ntest \"");
    try writeExamplePath(w, parts);
    try w.writeAll(
        \\" {
        \\    // Scaffolded smoke test — replace with real assertions. Example:
        \\    //   const zcli_testing = @import("zcli-testing");
        \\    //   var r = try zcli_testing.runCommand(@This(), &.{}, .{});
        \\    //   defer r.deinit();
        \\    //   try std.testing.expect(r.success);
        \\    // For a command with arguments, pass them via the config's args field.
        \\    _ = @This();
        \\}
        \\
    );
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

// ---------------------------------------------------------------------------
// Filesystem
// ---------------------------------------------------------------------------

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// A command group directory this invocation created from scratch. Because a
/// fresh directory has no `index.zig`, it has no description — the caller hints
/// how to give it one (ADR-0007: a group's description comes from index meta).
const NewGroup = struct {
    /// The group's path, slash-joined (e.g. "users" or "gh/pr") — the form
    /// `zcli add group` accepts as a single argument.
    name: []const u8,
};

/// Write the command file, creating any missing parent group directories.
/// Returns the groups that were newly created (and are therefore undescribed).
fn writeCommandFile(
    arena: std.mem.Allocator,
    io: std.Io,
    parts: []const []const u8,
    file_path: []const u8,
    content: []const u8,
) ![]const NewGroup {
    const cwd = std.Io.Dir.cwd();
    var new_groups = std.ArrayList(NewGroup).empty;

    if (parts.len > 1) {
        var dir = std.ArrayList(u8).empty;
        try dir.appendSlice(arena, "src/commands");
        for (parts[0 .. parts.len - 1], 0..) |segment, i| {
            try dir.append(arena, '/');
            try dir.appendSlice(arena, segment);
            cwd.createDir(io, dir.items, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            // createDir succeeded, so this group is brand new and undescribed.
            try new_groups.append(arena, .{
                .name = try std.mem.join(arena, "/", parts[0 .. i + 1]),
            });
        }
    }

    var file = try cwd.createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);

    return new_groups.items;
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
        const raw = std.mem.trim(u8, try zinput.text(w, r, arena, .{ .message = message, .interrupt_keys = back_keys }), " \t\r\n");
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
        const t = std.mem.trim(u8, try zinput.text(w, r, arena, .{ .message = "  Zig type:", .interrupt_keys = back_keys }), " \t\r\n");
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
        const raw = std.mem.trim(u8, try zinput.text(w, r, arena, .{ .message = "  Short character:", .interrupt_keys = back_keys }), " \t\r\n");
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
        const raw = std.mem.trim(u8, try zinput.text(w, r, arena, .{ .message = message, .interrupt_keys = back_keys }), " \t\r\n");
        if (raw.len == 0) return default;
        return std.fmt.parseFloat(f64, raw) catch {
            try warn(w, theme, "  Enter a number (e.g. 1.5).");
            continue;
        };
    }
}

fn readChoices(arena: std.mem.Allocator, w: *std.Io.Writer, r: *std.Io.Reader, theme: *const Theme) ![]const []const u8 {
    while (true) {
        const raw = try zinput.text(w, r, arena, .{ .message = "  Choices (comma-separated):", .interrupt_keys = back_keys });
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
    // A co-located placeholder test is scaffolded alongside the command; it
    // always compiles and passes, and `zig build test` discovers it.
    try expectContains(src, "test \"ping\" {");
    try expectContains(src, "_ = @This();");
    try expectContains(src, "runCommand(@This()"); // the example pattern in the comment
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
fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\nexpected to find:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
        return error.SubstringNotFound;
    }
}
