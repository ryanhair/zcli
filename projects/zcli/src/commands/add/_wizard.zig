//! The interactive `add command` wizard: prompt for a path (with live file
//! preview), description, positional arguments and options — Escape rewinds a
//! step, Ctrl+C cancels — then review and create. All terminal UI lives here;
//! source rendering and file placement are generate.zig's.

const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const prompts = zcli.prompts;
const themed = zcli.theme.styled;
const ThemeContext = zcli.theme.ThemeContext;

const generate = @import("_generate.zig");
const scaffold = @import("scaffold");
const ArgSpec = scaffold.spec.ArgSpec;
const OptSpec = scaffold.spec.OptSpec;
const buildEnumType = scaffold.spec.buildEnumType;
const quoteString = scaffold.spec.quoteString;
const writeDashed = scaffold.spec.writeDashed;
const parsePath = scaffold.spec.parsePath;
const buildFilePath = scaffold.spec.buildFilePath;
const isValidIdentifier = scaffold.spec.isValidIdentifier;
const isReservedWord = scaffold.spec.isReservedWord;
const toFieldName = scaffold.spec.toFieldName;
const normalizeName = scaffold.spec.normalizeName;

// Wizard prompts pass `.interrupt_keys = back_keys` so Escape aborts with
// `error.Interrupted`; the gather state machines catch that to rewind a step.
// "Go back" is the wizard's interpretation — prompts just reports the key.
const back_keys = &[_]prompts.terminal.Key{.escape};

// ---------------------------------------------------------------------------
// Interactive wizard
// ---------------------------------------------------------------------------

pub fn run(
    arena: std.mem.Allocator,
    context: *Context,
    theme: *const ThemeContext,
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
    theme: *const ThemeContext,
    seed_path: ?[]const u8,
    seed_description: ?[]const u8,
) !WizardResult {
    const w = context.stdout();
    const r = context.stdin();
    const io = context.io;

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
        const d = std.mem.trim(u8, try prompts.text(w, r, arena, .{ .message = "Description:" }), " \t\r\n");
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
        const action = try prompts.select(w, r, .{ .message = "What next?", .choices = &.{
            "Create it",
            "Add another argument",
            "Add another option",
            "Start over",
            "Cancel",
        } });
        switch (action) {
            0 => {
                const content = try generate.generateSource(arena, path.parts, description, args_list.items, opts_list.items);
                const new_groups = try generate.writeCommandFile(arena, io, path.parts, file_path, content);
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
// Step 1: command path (with live preview)
// ---------------------------------------------------------------------------

const PathResult = struct { parts: []const []const u8, prompted: bool };

const PathPreview = struct {
    theme: *const ThemeContext,

    fn render(ctx: *anyopaque, input: []const u8, w: *std.Io.Writer) anyerror!void {
        const self: *PathPreview = @ptrCast(@alignCast(ctx));
        const trimmed = std.mem.trim(u8, input, " \t/");
        if (trimmed.len == 0) return;
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "  \u{2192} creates src/commands/{s}.zig", .{trimmed}) catch return;
        try themed(line).dim().render(w, self.theme);
    }
};

fn resolveCommandPath(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    theme: *const ThemeContext,
    io: std.Io,
    seed: ?[]const u8,
) !PathResult {
    var pp = PathPreview{ .theme = theme };
    var seed_opt = seed;
    var prompted = false;
    while (true) {
        const raw = if (seed_opt) |s| s else blk: {
            prompted = true;
            break :blk try prompts.text(w, r, arena, .{
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
        if (generate.fileExists(io, file_path)) {
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
    theme: *const ThemeContext,
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
        if (!try prompts.confirm(w, r, .{ .message = prompt, .default = list.items.len == 0 })) break;

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
    theme: *const ThemeContext,
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
            const d = prompts.text(w, r, arena, .{ .message = "  Description:", .interrupt_keys = back_keys }) catch |e| {
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
                multiple = prompts.confirm(w, r, .{ .message = "  Multiple? (captures all remaining positionals)", .default = false, .interrupt_keys = back_keys }) catch |e| {
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
                const req = prompts.confirm(w, r, .{ .message = "  Required?", .default = true, .interrupt_keys = back_keys }) catch |e| {
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
    const idx = try prompts.select(w, r, .{
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
    theme: *const ThemeContext,
    list: *std.ArrayList(OptSpec),
) !void {
    try heading(w, theme, "Options (flags)");
    try hint(w, theme, "Esc to go back");

    while (true) {
        const prompt = if (list.items.len == 0) "Add an option?" else "Add another option?";
        if (!try prompts.confirm(w, r, .{ .message = prompt, .default = list.items.len == 0 })) break;

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
    theme: *const ThemeContext,
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
            const d = prompts.text(w, r, arena, .{ .message = "  Description:", .interrupt_keys = back_keys }) catch |e| {
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
                multiple = prompts.confirm(w, r, .{ .message = "  Multiple? (repeatable)", .default = false, .interrupt_keys = back_keys }) catch |e| {
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
            nullable = prompts.confirm(w, r, .{ .message = if (multiple) "  Nullable? (omit \u{2192} empty list)" else "  Nullable? (omit \u{2192} null)", .default = false, .interrupt_keys = back_keys }) catch |e| {
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
            const want = prompts.confirm(w, r, .{ .message = "  Short flag?", .default = false, .interrupt_keys = back_keys }) catch |e| {
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
    theme: *const ThemeContext,
    kind: OptKind,
    choices: []const []const u8,
) ![]const u8 {
    return switch (kind) {
        .flag => if (try prompts.confirm(w, r, .{ .message = "  Default on?", .default = false, .interrupt_keys = back_keys })) "true" else "false",
        .text => try quoteString(arena, std.mem.trim(u8, try prompts.text(w, r, arena, .{ .message = "  Default value:", .interrupt_keys = back_keys }), " \t\r\n")),
        .integer => try std.fmt.allocPrint(arena, "{d}", .{try prompts.number(w, r, .{ .message = "  Default value:", .default = 0, .interrupt_keys = back_keys })}),
        .decimal => try std.fmt.allocPrint(arena, "{d}", .{try readFloat(arena, w, r, theme, "  Default value:", 0)}),
        .choice => try std.fmt.allocPrint(arena, ".{s}", .{choices[try prompts.select(w, r, .{ .message = "  Default:", .choices = choices, .interrupt_keys = back_keys })]}),
        .custom => try arena.dupe(u8, std.mem.trim(u8, try prompts.text(w, r, arena, .{ .message = "  Default (Zig expression):", .interrupt_keys = back_keys }), " \t\r\n")),
    };
}

fn selectOptKind(w: *std.Io.Writer, r: *std.Io.Reader) !OptKind {
    const idx = try prompts.select(w, r, .{
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
    theme: *const ThemeContext,
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

pub fn finish(
    w: *std.Io.Writer,
    theme: *const ThemeContext,
    parts: []const []const u8,
    file_path: []const u8,
    new_groups: []const generate.NewGroup,
) !void {
    try w.writeAll("\n  ");
    {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "\u{2714} Created {s}", .{file_path}) catch "\u{2714} Created command";
        try themed(line).success().render(w, theme);
    }

    // A nested path can bring new group directories into being; a fresh group
    // has no index.zig, so it has no description in help or `tree`.
    for (new_groups) |g| {
        try w.writeAll("\n  ");
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "Note: new group '{s}' has no description.", .{g.name}) catch "Note: new group has no description.";
        try themed(line).warning().render(w, theme);
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
// Prompt helpers (validation + re-prompt loops)
// ---------------------------------------------------------------------------

fn readFieldName(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    theme: *const ThemeContext,
    message: []const u8,
    allow_dash: bool,
    existing: []const []const u8,
) ![]const u8 {
    while (true) {
        const raw = std.mem.trim(u8, try prompts.text(w, r, arena, .{ .message = message, .interrupt_keys = back_keys }), " \t\r\n");
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

fn readZigType(arena: std.mem.Allocator, w: *std.Io.Writer, r: *std.Io.Reader, theme: *const ThemeContext) ![]const u8 {
    while (true) {
        const t = std.mem.trim(u8, try prompts.text(w, r, arena, .{ .message = "  Zig type:", .interrupt_keys = back_keys }), " \t\r\n");
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
    theme: *const ThemeContext,
    used: []const u8,
) !u8 {
    while (true) {
        const raw = std.mem.trim(u8, try prompts.text(w, r, arena, .{ .message = "  Short character:", .interrupt_keys = back_keys }), " \t\r\n");
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
    theme: *const ThemeContext,
    message: []const u8,
    default: f64,
) !f64 {
    while (true) {
        const raw = std.mem.trim(u8, try prompts.text(w, r, arena, .{ .message = message, .interrupt_keys = back_keys }), " \t\r\n");
        if (raw.len == 0) return default;
        return std.fmt.parseFloat(f64, raw) catch {
            try warn(w, theme, "  Enter a number (e.g. 1.5).");
            continue;
        };
    }
}

fn readChoices(arena: std.mem.Allocator, w: *std.Io.Writer, r: *std.Io.Reader, theme: *const ThemeContext) ![]const []const u8 {
    while (true) {
        const raw = try prompts.text(w, r, arena, .{ .message = "  Choices (comma-separated):", .interrupt_keys = back_keys });
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

fn paint(w: *std.Io.Writer, theme: *const ThemeContext, text: []const u8, style: PaintStyle) !void {
    const t = themed(text);
    switch (style) {
        .bold => try t.bold().render(w, theme),
        .dim => try t.dim().render(w, theme),
        .success => try t.success().render(w, theme),
        .warning => try t.warning().render(w, theme),
        .command => try t.command().render(w, theme),
    }
}

fn heading(w: *std.Io.Writer, theme: *const ThemeContext, text: []const u8) !void {
    try w.writeAll("\r\n  ");
    try paint(w, theme, text, .bold);
    try w.writeAll("\r\n");
}

fn hint(w: *std.Io.Writer, theme: *const ThemeContext, text: []const u8) !void {
    try w.writeAll("  ");
    try paint(w, theme, text, .dim);
    try w.writeAll("\r\n");
}

fn warn(w: *std.Io.Writer, theme: *const ThemeContext, text: []const u8) !void {
    try w.writeAll("  ");
    try paint(w, theme, text, .warning);
    try w.writeAll("\r\n");
}

fn okArg(arena: std.mem.Allocator, w: *std.Io.Writer, theme: *const ThemeContext, a: ArgSpec) !void {
    const line = try std.fmt.allocPrint(arena, "  \u{2714} {s}  {s} \u{00b7} {s}", .{ a.name, argFieldType(a), argTail(a) });
    try w.writeAll(" ");
    try paint(w, theme, line, .success);
    try w.writeAll("\r\n");
}

fn okOpt(arena: std.mem.Allocator, w: *std.Io.Writer, theme: *const ThemeContext, o: OptSpec) !void {
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
