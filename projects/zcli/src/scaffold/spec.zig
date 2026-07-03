//! The shared arg/option spec model plus the rendering, type, name, and path
//! helpers used by every scaffolding command (`add command`, `add option`,
//! `add arg`). This is the single source of truth: `add/command.zig` aliases
//! these so its call sites are unchanged, and the splice engine renders through
//! them so created and spliced-in fields read identically.

const std = @import("std");

// ---------------------------------------------------------------------------
// Spec model — the single description both the wizard and flag front-ends build.
// `elem_type` is the element/scalar Zig type; `multiple` lifts it to a slice
// (varargs `[][]const u8` for positionals, `[]elem` for options).
// ---------------------------------------------------------------------------

pub const ArgSpec = struct {
    name: []const u8,
    elem_type: []const u8,
    multiple: bool,
    nullable: bool,
    description: []const u8,
};

pub const OptSpec = struct {
    name: []const u8,
    elem_type: []const u8,
    multiple: bool,
    nullable: bool,
    /// Rendered Zig expression for the default; present iff scalar and not nullable.
    default_expr: ?[]const u8 = null,
    short: ?u8 = null,
    description: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Field rendering (the `Args`/`Options` struct member text)
// ---------------------------------------------------------------------------

pub fn writeArgFieldType(w: *std.Io.Writer, a: ArgSpec) !void {
    if (a.multiple) {
        try w.writeAll("[][]const u8");
    } else if (a.nullable) {
        try w.print("?{s} = null", .{a.elem_type});
    } else {
        try w.writeAll(a.elem_type);
    }
}

pub fn writeOptFieldType(w: *std.Io.Writer, o: OptSpec) !void {
    if (o.multiple) {
        if (o.nullable) {
            try w.print("?[]{s} = null", .{o.elem_type});
        } else {
            try w.print("[]{s} = &.{{}}", .{o.elem_type});
        }
    } else if (o.nullable) {
        try w.print("?{s} = null", .{o.elem_type});
    } else {
        // A non-nullable scalar option always carries a default (the wizard
        // sets one; `add option` requires --default). Fail loudly rather than
        // writing `= undefined` if that invariant ever breaks.
        try w.print("{s} = {s}", .{ o.elem_type, o.default_expr orelse unreachable });
    }
}

/// Full `name: <type>` struct-member text for an argument.
pub fn renderArgField(arena: std.mem.Allocator, a: ArgSpec) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.print("{s}: ", .{a.name});
    try writeArgFieldType(&aw.writer, a);
    return aw.written();
}

/// Full `name: <type> [= default]` struct-member text for an option.
pub fn renderOptField(arena: std.mem.Allocator, o: OptSpec) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    try aw.writer.print("{s}: ", .{o.name});
    try writeOptFieldType(&aw.writer, o);
    return aw.written();
}

// ---------------------------------------------------------------------------
// Meta-entry rendering (the `.name = ...` inside `meta.args` / `meta.options`)
// ---------------------------------------------------------------------------

/// `.name = "description"` — an argument's meta entry.
pub fn renderArgMetaEntry(arena: std.mem.Allocator, a: ArgSpec) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.print(".{s} = \"", .{a.name});
    try writeEscaped(w, a.description);
    try w.writeByte('"');
    return aw.written();
}

/// `.name = .{ .description = "...", .short = 'x' }` — an option's meta entry.
pub fn renderOptMetaEntry(arena: std.mem.Allocator, o: OptSpec) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.print(".{s} = .{{ .description = \"", .{o.name});
    try writeEscaped(w, o.description);
    try w.writeByte('"');
    if (o.short) |c| try w.print(", .short = '{c}'", .{c});
    try w.writeAll(" }");
    return aw.written();
}

// ---------------------------------------------------------------------------
// String escaping
// ---------------------------------------------------------------------------

pub fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => {},
        else => try w.writeByte(ch),
    };
}

pub fn quoteString(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;
    try w.writeByte('"');
    try writeEscaped(w, s);
    try w.writeByte('"');
    return aw.written();
}

// ---------------------------------------------------------------------------
// Element type support
// ---------------------------------------------------------------------------

/// Option array element types zcli's parser can accumulate (see
/// packages/core/src/options/array_utils.zig).
pub const supported_array_elems = [_][]const u8{
    "[]const u8", "i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "f32", "f64",
};

pub fn isSupportedArrayElem(elem: []const u8) bool {
    for (supported_array_elems) |e| {
        if (std.mem.eql(u8, elem, e)) return true;
    }
    return false;
}

pub fn buildEnumType(arena: std.mem.Allocator, choices: []const []const u8) ![]const u8 {
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

pub fn enumHasMember(enum_type: []const u8, name: []const u8) bool {
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

// ---------------------------------------------------------------------------
// Field-name validation (snake_case Zig identifiers; dashes accepted and folded)
// ---------------------------------------------------------------------------

pub fn isValidIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;
    for (name[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

/// Normalize a name to a Zig field name (dashes → underscores) and validate it.
pub fn normalizeName(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const field = try toFieldName(arena, trimmed);
    if (!isValidIdentifier(field)) return error.InvalidName;
    if (isReservedWord(field)) return error.ReservedName;
    return field;
}

pub fn toFieldName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, name);
    for (out) |*ch| {
        if (ch.* == '-') ch.* = '_';
    }
    return out;
}

pub fn writeDashed(w: *std.Io.Writer, field: []const u8) !void {
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

pub fn isReservedWord(name: []const u8) bool {
    for (reserved_words) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Command path ↔ file path
// ---------------------------------------------------------------------------

/// Split a `users/create` command path into validated identifier components.
pub fn parsePath(arena: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n/");
    if (trimmed.len == 0) return error.InvalidCommandPath;

    var parts = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (!isValidIdentifier(segment)) return error.InvalidCommandPath;
        // Underscore-prefixed names are helper files/dirs to command
        // discovery, never commands — refuse to scaffold one.
        if (segment[0] == '_') return error.InvalidCommandPath;
        try parts.append(arena, segment);
    }
    if (parts.items.len == 0) return error.InvalidCommandPath;
    return parts.items;
}

/// Map path components to their command file, e.g. `["users","create"]` →
/// `src/commands/users/create.zig`.
pub fn buildFilePath(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(arena, "src/commands");
    for (parts) |p| {
        try buf.append(arena, '/');
        try buf.appendSlice(arena, p);
    }
    try buf.appendSlice(arena, ".zig");
    return buf.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderOptField covers scalar, nullable, multiple" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("limit: u32 = 10", try renderOptField(a, .{
        .name = "limit",
        .elem_type = "u32",
        .multiple = false,
        .nullable = false,
        .default_expr = "10",
    }));
    try testing.expectEqualStrings("repeat: ?u32 = null", try renderOptField(a, .{
        .name = "repeat",
        .elem_type = "u32",
        .multiple = false,
        .nullable = true,
    }));
    try testing.expectEqualStrings("tags: [][]const u8 = &.{}", try renderOptField(a, .{
        .name = "tags",
        .elem_type = "[]const u8",
        .multiple = true,
        .nullable = false,
    }));
}

test "renderArgField covers required, optional, variadic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("name: []const u8", try renderArgField(a, .{
        .name = "name",
        .elem_type = "[]const u8",
        .multiple = false,
        .nullable = false,
        .description = "",
    }));
    try testing.expectEqualStrings("count: ?u32 = null", try renderArgField(a, .{
        .name = "count",
        .elem_type = "u32",
        .multiple = false,
        .nullable = true,
        .description = "",
    }));
    try testing.expectEqualStrings("files: [][]const u8", try renderArgField(a, .{
        .name = "files",
        .elem_type = "[]const u8",
        .multiple = true,
        .nullable = false,
        .description = "",
    }));
}

test "renderOptMetaEntry includes short only when present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(".loud = .{ .description = \"Shout it\", .short = 'l' }", try renderOptMetaEntry(a, .{
        .name = "loud",
        .elem_type = "bool",
        .multiple = false,
        .nullable = false,
        .default_expr = "false",
        .short = 'l',
        .description = "Shout it",
    }));
    try testing.expectEqualStrings(".limit = .{ .description = \"Max\" }", try renderOptMetaEntry(a, .{
        .name = "limit",
        .elem_type = "u32",
        .multiple = false,
        .nullable = false,
        .default_expr = "1",
        .description = "Max",
    }));
}

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

test "parsePath rejects underscore-prefixed segments (discovery treats them as helpers)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.InvalidCommandPath, parsePath(a, "_wizard"));
    try testing.expectError(error.InvalidCommandPath, parsePath(a, "users/_create"));
}

test "parsePath accepts slash and space separators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const p = try parsePath(a, "users/create");
    try testing.expectEqual(@as(usize, 2), p.len);
    try testing.expectEqualStrings("users", p[0]);
    try testing.expectEqualStrings("create", p[1]);
    try testing.expectError(error.InvalidCommandPath, parsePath(a, "  "));
    try testing.expectEqualStrings("src/commands/users/create.zig", try buildFilePath(a, p));
}

test "enumHasMember handles explicit values and spacing" {
    try testing.expect(enumHasMember("enum { json, yaml }", "json"));
    try testing.expect(enumHasMember("enum { a = 1, b = 2 }", "b"));
    try testing.expect(!enumHasMember("enum { json, yaml }", "xml"));
    try testing.expect(!enumHasMember("enum {}", "x"));
}

test "isSupportedArrayElem accepts numeric and string element types" {
    try testing.expect(isSupportedArrayElem("[]const u8"));
    try testing.expect(isSupportedArrayElem("u32"));
    try testing.expect(!isSupportedArrayElem("bool"));
}
