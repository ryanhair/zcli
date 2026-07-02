const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const ztheme = zcli.ztheme;

const scaffold = @import("scaffold");
const spec = scaffold.spec;
const splice = scaffold.splice;

pub const meta = .{
    .description = "Add an option to an existing command",
    .examples = &.{
        "add option users/create verbose --type bool --default false --short v",
        "add option deploy region --type []const u8 --nullable",
        "add option search tag --type []const u8 --multiple",
    },
    .args = .{
        .command = "Target command path (e.g. 'users/create')",
        .name = "Option name (snake_case or kebab-case)",
    },
    .options = .{
        .type = .{ .description = "Element/scalar Zig type (e.g. u32, bool, []const u8)", .short = 't' },
        .multiple = .{ .description = "Accumulate repeated flags into a slice" },
        .nullable = .{ .description = "Optional: renders as ?T = null" },
        .default = .{ .description = "Default value, a Zig expression (required for a non-nullable scalar)" },
        .short = .{ .description = "Single-character short flag", .short = 's' },
        .description = .{ .description = "Option description", .short = 'd' },
    },
};

pub const Args = struct {
    command: []const u8,
    name: []const u8,
};

pub const Options = struct {
    type: []const u8,
    // `description` MUST precede `default`: zcli auto-derives a short flag from
    // each field's first letter, so `default` would otherwise claim `-d`. Short
    // flags resolve to the first matching field, so declaring `description`
    // (explicit `-d`) first makes `-d` mean description; `default` keeps only
    // its long form.
    description: ?[]const u8 = null,
    multiple: bool = false,
    nullable: bool = false,
    default: ?[]const u8 = null,
    short: ?[]const u8 = null,
};

/// Maximum bytes read from a command source file before splicing.
const max_source_bytes = 1024 * 1024;

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

    const parts = spec.parsePath(arena, args.command) catch {
        try stderr.print("Error: Invalid command path: '{s}'\n", .{args.command});
        return error.InvalidCommandPath;
    };
    const file_path = try spec.buildFilePath(arena, parts);

    const name = spec.normalizeName(arena, args.name) catch |err| {
        try stderr.print("Error: Invalid option name '{s}': {s}\n", .{ args.name, @errorName(err) });
        return err;
    };

    const opt = try buildSpec(arena, stderr, name, options);

    // Read the target command's source (NUL-terminated for the AST parser).
    const raw = std.Io.Dir.cwd().readFileAlloc(io, file_path, arena, .limited(max_source_bytes)) catch {
        try stderr.print("Error: Command not found: {s}\n", .{file_path});
        try stderr.print("Create it first with `zcli add command {s}`\n", .{args.command});
        return error.CommandNotFound;
    };
    const source = try arena.dupeZ(u8, raw);

    const updated = splice.insertOption(arena, source, opt) catch |err| switch (err) {
        splice.SpliceError.DuplicateField => {
            try stderr.print("Error: {s} already has an option named '{s}'\n", .{ file_path, name });
            return err;
        },
        else => {
            try stderr.print("Error: could not edit {s}: {s}\n", .{ file_path, @errorName(err) });
            return err;
        },
    };

    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, updated);

    try finish(context.stdout(), &context.theme, file_path, opt);
}

/// Assemble the OptSpec from the flags, enforcing the ADR-0005 rules:
/// `--default` and `--nullable` are contradictory; a non-nullable scalar needs
/// a `--default`; a `--multiple` element type must be one the parser accumulates.
fn buildSpec(arena: std.mem.Allocator, stderr: *std.Io.Writer, name: []const u8, options: Options) !spec.OptSpec {
    const elem_type = std.mem.trim(u8, options.type, " \t");
    if (elem_type.len == 0) {
        try stderr.print("Error: --type is required\n", .{});
        return error.MissingType;
    }

    if (options.nullable and options.default != null) {
        try stderr.print("Error: --nullable and --default are contradictory (a nullable option defaults to null)\n", .{});
        return error.ContradictoryFlags;
    }

    if (options.multiple and !spec.isSupportedArrayElem(elem_type)) {
        try stderr.print("Error: --multiple only supports these element types: {s}\n", .{"[]const u8, i8..u64, f32, f64"});
        return error.UnsupportedArrayElement;
    }

    var short: ?u8 = null;
    if (options.short) |s| {
        if (s.len != 1 or !std.ascii.isAlphabetic(s[0])) {
            try stderr.print("Error: --short must be a single letter, got '{s}'\n", .{s});
            return error.BadShort;
        }
        short = s[0];
    }

    // Default expression: only meaningful for a non-nullable scalar, where it is
    // required. A non-nullable multiple defaults to an empty slice.
    var default_expr: ?[]const u8 = null;
    if (options.multiple) {
        if (!options.nullable) default_expr = "&.{}";
    } else if (!options.nullable) {
        default_expr = options.default orelse {
            try stderr.print("Error: a non-nullable scalar option needs a --default (or pass --nullable)\n", .{});
            return error.MissingDefault;
        };
    }

    return .{
        .name = name,
        .elem_type = try arena.dupe(u8, elem_type),
        .multiple = options.multiple,
        .nullable = options.nullable,
        .default_expr = default_expr,
        .short = short,
        .description = try arena.dupe(u8, options.description orelse ""),
    };
}

fn finish(w: *std.Io.Writer, theme: *const ztheme.Theme, file_path: []const u8, opt: spec.OptSpec) !void {
    try w.writeAll("\n  ");
    var buf: [512]u8 = undefined;
    const field = std.fmt.bufPrint(&buf, "\u{2714} Added option --{s} to {s}", .{ opt.name, file_path }) catch "\u{2714} Added option";
    try ztheme.theme(field).success().render(w, theme);
    try w.writeAll("\n\n  Next steps\n");
    try w.print("    1. Read the option back with `zcli tree --show-options`\n", .{});
    try w.writeAll("    2. zig build\n");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectBuildError(err: anyerror, name: []const u8, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var aw = std.Io.Writer.Allocating.init(arena.allocator());
    try testing.expectError(err, buildSpec(arena.allocator(), &aw.writer, name, options));
}

test "buildSpec: nullable + default is contradictory" {
    try expectBuildError(error.ContradictoryFlags, "region", .{
        .type = "[]const u8",
        .nullable = true,
        .default = "\"us\"",
    });
}

test "buildSpec: non-nullable scalar requires a default" {
    try expectBuildError(error.MissingDefault, "count", .{ .type = "u32" });
}

test "buildSpec: multiple rejects unsupported element types" {
    try expectBuildError(error.UnsupportedArrayElement, "flags", .{ .type = "bool", .multiple = true });
}

test "buildSpec: bad short flag" {
    try expectBuildError(error.BadShort, "loud", .{ .type = "bool", .default = "false", .short = "loud" });
}

test "buildSpec: well-formed scalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var aw = std.Io.Writer.Allocating.init(arena.allocator());
    const s = try buildSpec(arena.allocator(), &aw.writer, "limit", .{
        .type = "u32",
        .default = "10",
        .short = "l",
        .description = "Max",
    });
    try testing.expectEqualStrings("limit", s.name);
    try testing.expectEqualStrings("u32", s.elem_type);
    try testing.expectEqualStrings("10", s.default_expr.?);
    try testing.expectEqual(@as(u8, 'l'), s.short.?);
}

test "buildSpec: non-nullable multiple defaults to empty slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var aw = std.Io.Writer.Allocating.init(arena.allocator());
    const s = try buildSpec(arena.allocator(), &aw.writer, "tags", .{ .type = "[]const u8", .multiple = true });
    try testing.expectEqualStrings("&.{}", s.default_expr.?);
}
