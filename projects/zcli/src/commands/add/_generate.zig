//! Turn a gathered command spec into a Zig source file and place it in the
//! src/commands tree. Pure of any Context — callers hand in an arena, an io,
//! and the parsed path parts — so it serves both the interactive wizard and
//! the piped skeleton path (and is unit-testable without a TTY).

const std = @import("std");
const scaffold = @import("scaffold");
const ArgSpec = scaffold.spec.ArgSpec;
const OptSpec = scaffold.spec.OptSpec;
const writeEscaped = scaffold.spec.writeEscaped;
const quoteString = scaffold.spec.quoteString;
const writeArgField = scaffold.spec.writeArgFieldType;
const writeOptField = scaffold.spec.writeOptFieldType;
const writeDashed = scaffold.spec.writeDashed;
const parsePath = scaffold.spec.parsePath;

pub fn generateSource(
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

    // execute. Unused parameters are `_` in the signature (the project style —
    // Zig rejects unused named parameters); the hint comment tells the user to
    // rename them as the body starts using the fields.
    try w.writeAll("pub fn execute(_: Args, _: Options, context: *Context) !void {\n");
    if (args_list.len != 0 or opts_list.len != 0) {
        try w.writeAll("    // TODO: implement. Rename `_: Args`/`_: Options` to `args`/`options` to use:");
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
        \\    //   var r = try zcli_testing.runCommand(@This(), .{});
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

pub fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// A command group directory this invocation created from scratch. Because a
/// fresh directory has no `index.zig`, it has no description — the caller hints
/// how to give it one (ADR-0007: a group's description comes from index meta).
pub const NewGroup = struct {
    /// The group's path, slash-joined (e.g. "users" or "gh/pr") — the form
    /// `zcli add group` accepts as a single argument.
    name: []const u8,
};

/// Write the command file, creating any missing parent group directories.
/// Returns the groups that were newly created (and are therefore undescribed).
pub fn writeCommandFile(
    arena: std.mem.Allocator,
    io: std.Io,
    parts: []const []const u8,
    file_path: []const u8,
    content: []const u8,
) ![]const NewGroup {
    // Guard before touching the filesystem: a user-supplied custom type or
    // default is spliced verbatim into the source, so a typo (e.g. `u3 2`) or an
    // otherwise malformed snippet would produce a command file that won't parse.
    // Refuse it here — writing nothing — rather than report success and leave a
    // broken scaffold to surface as a confusing compile error later (#506).
    if (!try scaffold.splice.parses(arena, content)) return error.GeneratedSourceInvalid;

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
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "generateSource: empty command is the minimal skeleton" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parts = try parsePath(a, "ping");
    const src = try generateSource(a, parts, "TODO: Add description", &.{}, &.{});

    try expectContains(src, "pub const Args = struct {};");
    try expectContains(src, "pub const Options = struct {};");
    // Unused params live in the signature per the project style (#399).
    try expectContains(src, "pub fn execute(_: Args, _: Options, context: *Context) !void {");
    try expectContains(src, "\"ping\"");
    try expectContains(src, "TODO: Implement ping");
    try testing.expect(std.mem.indexOf(u8, src, ".args = .{") == null);
    // A co-located placeholder test is scaffolded alongside the command; it
    // always compiles and passes, and `zig build test` discovers it.
    try expectContains(src, "test \"ping\" {");
    try expectContains(src, "_ = @This();");
    try expectContains(src, "runCommand(@This(), .{});"); // the 2-arg example pattern in the comment
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
test "writeCommandFile refuses source that would not parse, writing nothing (#506)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A malformed custom option type is spliced verbatim, yielding the Options
    // field `bad: ?u3 2 = null,` — which does not parse. The write path must
    // reject it up front (before any filesystem work) rather than scaffold a
    // command file that won't compile.
    const parts = try parsePath(a, "broken");
    const opts_list = [_]OptSpec{
        .{ .name = "bad", .elem_type = "u3 2", .multiple = false, .nullable = true, .default_expr = null, .description = "" },
    };
    const src = try generateSource(a, parts, "Broken", &.{}, &opts_list);
    // parts.len == 1, so this returns on the parse guard before touching the fs.
    try testing.expectError(error.GeneratedSourceInvalid, writeCommandFile(a, testing.io, parts, "src/commands/broken.zig", src));
}

test "a well-formed generated command passes the parse guard" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parts = try parsePath(a, "users/create");
    const args_list = [_]ArgSpec{
        .{ .name = "email", .elem_type = "[]const u8", .multiple = false, .nullable = false, .description = "Email" },
    };
    const opts_list = [_]OptSpec{
        .{ .name = "format", .elem_type = "enum { json, yaml }", .multiple = false, .nullable = false, .default_expr = ".yaml", .description = "Format" },
    };
    const src = try generateSource(a, parts, "Create a user", &args_list, &opts_list);
    try testing.expect(try scaffold.splice.parses(a, src));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\nexpected to find:\n  {s}\nin:\n{s}\n", .{ needle, haystack });
        return error.SubstringNotFound;
    }
}
