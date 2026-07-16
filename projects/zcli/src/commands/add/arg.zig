const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const themed = zcli.theme.styled;
const ThemeContext = zcli.theme.ThemeContext;

const scaffold = @import("scaffold");
const spec = scaffold.spec;
const splice = scaffold.splice;

pub const meta = .{
    .description = "Add a positional argument to an existing command",
    .examples = &.{
        "add arg users/create name --type []const u8",
        "add arg deploy target --type []const u8 --before env",
        "add arg run rest --type []const u8 --multiple",
    },
    .args = .{
        .command = "Target command path (e.g. 'users/create')",
        .name = "Argument name (snake_case or kebab-case)",
    },
    .options = .{
        .type = .{ .description = "Element/scalar Zig type (e.g. u32, []const u8; default: []const u8)", .short = 't' },
        .multiple = .{ .description = "Variadic: captures all remaining positionals ([]const u8 only)" },
        .nullable = .{ .description = "Optional: renders as ?T = null" },
        .before = .{ .description = "Insert before this existing argument" },
        .after = .{ .description = "Insert after this existing argument" },
        .description = .{ .description = "Argument description", .short = 'd' },
    },
};

pub const Args = struct {
    command: []const u8,
    name: []const u8,
};

pub const Options = struct {
    // Defaults to a string arg — the same default the wizard uses for its
    // "text" choice.
    type: []const u8 = "[]const u8",
    // See option.zig: `description` precedes any other d-word so `-d` stays its
    // short. (No collision here, but kept for consistency with `add option`.)
    description: ?[]const u8 = null,
    multiple: bool = false,
    nullable: bool = false,
    before: ?[]const u8 = null,
    after: ?[]const u8 = null,
};

/// Maximum bytes read from a command source file before splicing.
const max_source_bytes = 1024 * 1024;

pub fn execute(args: Args, options: Options, context: *Context) !void {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = context.io;
    const stderr = context.stderr();

    // Preflight: must be inside a zcli project.
    std.Io.Dir.cwd().access(io, "src/commands", .{}) catch {
        return context.fail("Error: Not in a zcli project directory\nRun this command from the root of your zcli project (where build.zig is)", .{});
    };

    const parts = spec.parsePath(arena, args.command) catch {
        return context.fail("Error: Invalid command path: '{s}'", .{args.command});
    };
    const file_path = try spec.buildFilePath(arena, parts);

    const name = spec.normalizeName(arena, args.name) catch |err| {
        return context.fail("Error: Invalid argument name '{s}': {s}", .{ args.name, @errorName(err) });
    };

    // buildSpec / resolveAnchor print the specific problem; their validation
    // failures are user mistakes, so exit cleanly (no trace).
    const arg = buildSpec(arena, stderr, name, options) catch |err| switch (err) {
        error.MissingType,
        error.ContradictoryFlags,
        error.PositionalMultipleMustBeString,
        => return error.CommandFailed,
        else => return err,
    };
    const anchor = resolveAnchor(arena, stderr, options) catch |err| switch (err) {
        error.ContradictoryFlags => return error.CommandFailed,
        else => return err,
    };

    // Read the target command's source (NUL-terminated for the AST parser).
    const raw = std.Io.Dir.cwd().readFileAlloc(io, file_path, arena, .limited(max_source_bytes)) catch {
        return context.fail("Error: Command not found: {s}\nCreate it first with `zcli add command {s}`", .{ file_path, args.command });
    };
    const source = try arena.dupeZ(u8, raw);

    // Validate placement against the real file before touching it: duplicate
    // name, unknown anchor, and the ordering rules (required-before-optional,
    // `multiple` last). validateOrder prints the specific problem; all its
    // failures are user mistakes, so exit cleanly (no trace).
    const existing = try splice.fieldShapes(arena, source, "Args");
    validateOrder(arena, stderr, file_path, existing, arg, anchor) catch |err| switch (err) {
        splice.SpliceError.DuplicateField,
        splice.SpliceError.AnchorNotFound,
        error.MultipleNotLast,
        error.BadArgOrder,
        => return error.CommandFailed,
        else => return err,
    };

    const updated = splice.insertArg(arena, source, arg, anchor) catch |err| switch (err) {
        splice.SpliceError.DuplicateField => return context.fail("Error: {s} already has an argument named '{s}'", .{ file_path, name }),
        splice.SpliceError.ResultDoesNotParse => return context.fail("Error: adding this argument would make {s} fail to compile (check --type '{s}')\nNo changes were written.", .{ file_path, arg.elem_type }),
        else => {
            try stderr.print("Error: could not edit {s}: {s}\n", .{ file_path, @errorName(err) });
            return err;
        },
    };

    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, updated);

    try finish(context.stdout(), &context.theme, file_path, arg);
}

/// Assemble the ArgSpec from the flags. Positionals have no default and no short
/// flag: `--nullable` makes an arg optional, its absence makes it required. A
/// `--multiple` positional is the varargs tail, which zcli only supports as
/// `[]const u8`, and it can't also be `--nullable` (a variadic already captures
/// zero or more).
fn buildSpec(arena: std.mem.Allocator, stderr: *std.Io.Writer, name: []const u8, options: Options) !spec.ArgSpec {
    const elem_type = std.mem.trim(u8, options.type, " \t");
    if (elem_type.len == 0) {
        try stderr.print("Error: --type is required\n", .{});
        return error.MissingType;
    }

    if (options.multiple) {
        if (options.nullable) {
            try stderr.print("Error: --multiple and --nullable are contradictory (a variadic already captures zero or more)\n", .{});
            return error.ContradictoryFlags;
        }
        if (!std.mem.eql(u8, elem_type, "[]const u8")) {
            try stderr.print("Error: a --multiple positional must be []const u8 (it captures the remaining arguments)\n", .{});
            return error.PositionalMultipleMustBeString;
        }
    }

    return .{
        .name = name,
        .elem_type = try arena.dupe(u8, elem_type),
        .multiple = options.multiple,
        .nullable = options.nullable,
        .description = try arena.dupe(u8, options.description orelse ""),
    };
}

/// `--before`/`--after` are mutually exclusive; their targets are field names,
/// so they are normalized the same way the stored field names were.
fn resolveAnchor(arena: std.mem.Allocator, stderr: *std.Io.Writer, options: Options) !splice.Anchor {
    if (options.before != null and options.after != null) {
        try stderr.print("Error: pass only one of --before/--after\n", .{});
        return error.ContradictoryFlags;
    }
    if (options.before) |b| return .{ .before = try spec.toFieldName(arena, b) };
    if (options.after) |a| return .{ .after = try spec.toFieldName(arena, a) };
    return .append;
}

/// Enforce the ADR-0005 ordering rules against the file's real arguments, with
/// the new arg placed at `anchor`: a `multiple` argument must be last, and a
/// required argument may not follow an optional one.
fn validateOrder(
    arena: std.mem.Allocator,
    stderr: *std.Io.Writer,
    file_path: []const u8,
    existing: []const splice.FieldShape,
    arg: spec.ArgSpec,
    anchor: splice.Anchor,
) !void {
    for (existing) |e| {
        if (std.mem.eql(u8, e.name, arg.name)) {
            try stderr.print("Error: {s} already has an argument named '{s}'\n", .{ file_path, arg.name });
            return splice.SpliceError.DuplicateField;
        }
    }

    const idx = switch (anchor) {
        .append => existing.len,
        .before => |t| indexOfName(existing, t) orelse return anchorNotFound(stderr, file_path, t),
        .after => |t| (indexOfName(existing, t) orelse return anchorNotFound(stderr, file_path, t)) + 1,
    };

    // The resulting order, with the new arg spliced in at idx.
    var order = std.ArrayList(splice.FieldShape).empty;
    try order.appendSlice(arena, existing[0..idx]);
    try order.append(arena, .{ .name = arg.name, .optional = arg.nullable, .multiple = arg.multiple });
    try order.appendSlice(arena, existing[idx..]);

    var last_multiple: ?[]const u8 = null;
    var last_optional: ?[]const u8 = null;
    for (order.items) |s| {
        if (last_multiple) |m| {
            try stderr.print("Error: a multiple argument must be last, but '{s}' would follow '{s}'\n", .{ s.name, m });
            return error.MultipleNotLast;
        }
        if (!s.optional and !s.multiple) {
            if (last_optional) |o| {
                try stderr.print("Error: required argument '{s}' cannot follow optional argument '{s}'\n", .{ s.name, o });
                return error.BadArgOrder;
            }
        }
        if (s.optional) last_optional = s.name;
        if (s.multiple) last_multiple = s.name;
    }
}

fn indexOfName(list: []const splice.FieldShape, name: []const u8) ?usize {
    for (list, 0..) |s, i| {
        if (std.mem.eql(u8, s.name, name)) return i;
    }
    return null;
}

fn anchorNotFound(stderr: *std.Io.Writer, file_path: []const u8, name: []const u8) anyerror {
    stderr.print("Error: {s} has no argument named '{s}' to anchor against\n", .{ file_path, name }) catch {};
    return splice.SpliceError.AnchorNotFound;
}

fn finish(w: *std.Io.Writer, theme: *const ThemeContext, file_path: []const u8, arg: spec.ArgSpec) !void {
    try w.writeAll("\n  ");
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\u{2714} Added argument '{s}' to {s}", .{ arg.name, file_path }) catch "\u{2714} Added argument";
    try themed(line).success().render(w, theme);
    try w.writeAll("\n\n  Next steps\n");
    try w.print("    1. Read the argument back with `zcli tree --show-options`\n", .{});
    try w.writeAll("    2. zig build\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn shapes(arena: std.mem.Allocator, comptime pairs: anytype) ![]const splice.FieldShape {
    var list = std.ArrayList(splice.FieldShape).empty;
    inline for (pairs) |p| {
        try list.append(arena, .{ .name = p[0], .optional = p[1], .multiple = p[2] });
    }
    return list.items;
}

fn requiredArg(name: []const u8) spec.ArgSpec {
    return .{ .name = name, .elem_type = "[]const u8", .multiple = false, .nullable = false, .description = "" };
}

test "buildSpec: multiple must be a string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var aw = std.Io.Writer.Allocating.init(arena.allocator());
    try testing.expectError(error.PositionalMultipleMustBeString, buildSpec(arena.allocator(), &aw.writer, "nums", .{ .type = "u32", .multiple = true }));
}

test "buildSpec: multiple and nullable are contradictory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var aw = std.Io.Writer.Allocating.init(arena.allocator());
    try testing.expectError(error.ContradictoryFlags, buildSpec(arena.allocator(), &aw.writer, "rest", .{ .type = "[]const u8", .multiple = true, .nullable = true }));
}

test "validateOrder: required cannot append after an optional" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw = std.Io.Writer.Allocating.init(a);
    const existing = try shapes(a, .{.{ "first", true, false }}); // one optional arg
    try testing.expectError(error.BadArgOrder, validateOrder(a, &aw.writer, "x.zig", existing, requiredArg("second"), .append));
}

test "validateOrder: nothing may follow a variadic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw = std.Io.Writer.Allocating.init(a);
    const existing = try shapes(a, .{.{ "rest", false, true }}); // existing variadic (last)
    // Appending after it is illegal.
    try testing.expectError(error.MultipleNotLast, validateOrder(a, &aw.writer, "x.zig", existing, requiredArg("late"), .append));
}

test "validateOrder: unknown anchor is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw = std.Io.Writer.Allocating.init(a);
    const existing = try shapes(a, .{.{ "name", false, false }});
    try testing.expectError(splice.SpliceError.AnchorNotFound, validateOrder(a, &aw.writer, "x.zig", existing, requiredArg("x"), .{ .after = "missing" }));
}

test "validateOrder: required before an optional is accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw = std.Io.Writer.Allocating.init(a);
    const existing = try shapes(a, .{.{ "opt", true, false }});
    // Inserting a required arg *before* the optional keeps the order valid.
    try validateOrder(a, &aw.writer, "x.zig", existing, requiredArg("req"), .{ .before = "opt" });
}
