//! In-file, AST-guided textual splice (ADR-0005). To add an arg or option to an
//! existing command we locate — via `std.zig.Ast`, the same read machinery
//! `tree.zig` uses — the source spans of the `Args`/`Options` struct and the
//! `meta.args`/`meta.options` literal, then insert the new field and meta entry
//! while leaving every other byte untouched. We never regenerate the file: that
//! would destroy the author's `execute()` body, comments, and formatting.

const std = @import("std");
const spec = @import("spec.zig");
const Ast = std.zig.Ast;

pub const SpliceError = error{
    ContainerNotFound,
    NotAStruct,
    NoMeta,
    MetaNotStruct,
    SubNotStruct,
    AnchorNotFound,
    DuplicateField,
};

/// Where to place a new field among existing ones.
pub const Anchor = union(enum) {
    append,
    before: []const u8,
    after: []const u8,
};

/// Add an option to a command's source: a field in `Options` (appended) and an
/// entry in `meta.options` (created if absent). Options are unordered, so the
/// field always appends. Returns newly allocated source.
pub fn insertOption(arena: std.mem.Allocator, source: [:0]const u8, o: spec.OptSpec) ![]u8 {
    try ensureNoField(arena, source, "Options", o.name);
    const field = try spec.renderOptField(arena, o);
    const with_field = try insertStructField(arena, source, "Options", field, .append);
    const entry = try spec.renderOptMetaEntry(arena, o);
    return insertMetaEntry(arena, try arena.dupeZ(u8, with_field), "options", entry);
}

/// Add an argument to a command's source: a field in `Args` (at `anchor`) and an
/// entry in `meta.args` (created if absent). Returns newly allocated source.
pub fn insertArg(arena: std.mem.Allocator, source: [:0]const u8, a: spec.ArgSpec, anchor: Anchor) ![]u8 {
    try ensureNoField(arena, source, "Args", a.name);
    const field = try spec.renderArgField(arena, a);
    const with_field = try insertStructField(arena, source, "Args", field, anchor);
    const entry = try spec.renderArgMetaEntry(arena, a);
    return insertMetaEntry(arena, try arena.dupeZ(u8, with_field), "args", entry);
}

/// The existing field names of a command's `Args`/`Options` struct, in source
/// order. Used to validate ordering and anchors before splicing.
pub fn fieldNames(arena: std.mem.Allocator, source: [:0]const u8, container: []const u8) ![]const []const u8 {
    var ast = try Ast.parse(arena, source, .zig);
    const init = findDeclInit(&ast, container) orelse return &.{};
    var buf: [2]Ast.Node.Index = undefined;
    const cd = ast.fullContainerDecl(&buf, init) orelse return error.NotAStruct;

    var names = std.ArrayList([]const u8).empty;
    for (cd.ast.members) |m| {
        const name = memberName(&ast, m);
        if (name.len > 0) try names.append(arena, try arena.dupe(u8, name));
    }
    return names.items;
}

fn ensureNoField(arena: std.mem.Allocator, source: [:0]const u8, container: []const u8, name: []const u8) !void {
    for (try fieldNames(arena, source, container)) |existing| {
        if (std.mem.eql(u8, existing, name)) return SpliceError.DuplicateField;
    }
}

/// The ordering-relevant shape of an existing `Args`/`Options` field.
pub const FieldShape = struct {
    name: []const u8,
    /// Nullable (`?T`) or defaulted — optional to supply.
    optional: bool,
    /// Variadic/accumulating slice (element type is not `u8`).
    multiple: bool,
};

/// Each field of `container`'s struct as its ordering shape, in source order.
/// Mirrors the type analysis tree.zig uses for read-back; used to validate arg
/// ordering (required-before-optional, `multiple` last) against the real file.
pub fn fieldShapes(arena: std.mem.Allocator, source: [:0]const u8, container: []const u8) ![]const FieldShape {
    var ast = try Ast.parse(arena, source, .zig);
    const init = findDeclInit(&ast, container) orelse return &.{};
    var buf: [2]Ast.Node.Index = undefined;
    const cd = ast.fullContainerDecl(&buf, init) orelse return SpliceError.NotAStruct;

    var out = std.ArrayList(FieldShape).empty;
    for (cd.ast.members) |m| {
        const cf = ast.fullContainerField(m) orelse continue;
        const type_node = cf.ast.type_expr.unwrap() orelse continue;

        var node = type_node;
        var optional = cf.ast.value_expr != .none; // has a default
        if (ast.nodeTag(node) == .optional_type) {
            optional = true;
            node = ast.nodeData(node).node;
        }
        var multiple = false;
        if (ast.fullPtrType(node)) |ptr| {
            if (ptr.size == .slice and !std.mem.eql(u8, nodeSource(&ast, ptr.ast.child_type), "u8")) {
                multiple = true;
            }
        }
        try out.append(arena, .{
            .name = try arena.dupe(u8, ast.tokenSlice(cf.ast.main_token)),
            .optional = optional,
            .multiple = multiple,
        });
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Struct-field splice
// ---------------------------------------------------------------------------

/// Insert `field_text` (e.g. `limit: u32 = 10`) into `pub const <container> =
/// struct {...}` at `anchor`.
pub fn insertStructField(
    arena: std.mem.Allocator,
    source: [:0]const u8,
    container: []const u8,
    field_text: []const u8,
    anchor: Anchor,
) ![]u8 {
    var ast = try Ast.parse(arena, source, .zig);
    const init = findDeclInit(&ast, container) orelse return SpliceError.ContainerNotFound;
    var buf: [2]Ast.Node.Index = undefined;
    const cd = ast.fullContainerDecl(&buf, init) orelse return SpliceError.NotAStruct;
    return spliceMembers(arena, &ast, source, cd.ast.members, ast.lastToken(init), field_text, "    ", anchor, memberName);
}

// ---------------------------------------------------------------------------
// Meta-entry splice
// ---------------------------------------------------------------------------

/// Insert `entry_text` into `meta.<sub> = .{...}`, creating the block if absent.
pub fn insertMetaEntry(arena: std.mem.Allocator, source: [:0]const u8, sub: []const u8, entry_text: []const u8) ![]u8 {
    var ast = try Ast.parse(arena, source, .zig);
    const init = findDeclInit(&ast, "meta") orelse return SpliceError.NoMeta;
    var buf: [2]Ast.Node.Index = undefined;
    const si = ast.fullStructInit(&buf, init) orelse return SpliceError.MetaNotStruct;

    // Existing `.sub = .{...}` → append into it.
    for (si.ast.fields) |field| {
        if (std.mem.eql(u8, initFieldName(&ast, field), sub)) {
            var b2: [2]Ast.Node.Index = undefined;
            const inner = ast.fullStructInit(&b2, field) orelse return SpliceError.SubNotStruct;
            return spliceMembers(arena, &ast, source, inner.ast.fields, ast.lastToken(field), entry_text, "        ", .append, initFieldName);
        }
    }
    // Absent → append `.sub = .{ entry }` as a new meta field.
    const block = try std.fmt.allocPrint(arena, ".{s} = .{{\n        {s},\n    }}", .{ sub, entry_text });
    return spliceMembers(arena, &ast, source, si.ast.fields, ast.lastToken(init), block, "    ", .append, initFieldName);
}

// ---------------------------------------------------------------------------
// Shared span-splice
// ---------------------------------------------------------------------------

const NameFn = *const fn (*Ast, Ast.Node.Index) []const u8;

/// Insert `text` among the `members` of a braced group (a struct decl or struct
/// literal whose closing `}` is `close_brace`), positioned by `anchor`, indented
/// by `indent`. `nameFn` recovers a member's name for anchor matching.
fn spliceMembers(
    arena: std.mem.Allocator,
    ast: *Ast,
    source: [:0]const u8,
    members: []const Ast.Node.Index,
    close_brace: Ast.TokenIndex,
    text: []const u8,
    indent: []const u8,
    anchor: Anchor,
    nameFn: NameFn,
) ![]u8 {
    var out = std.ArrayList(u8).empty;

    if (members.len == 0) {
        // Empty braces `{}` → `{\n<indent><text>,\n}`.
        const off = tokStart(ast, close_brace);
        try out.appendSlice(arena, source[0..off]);
        try out.print(arena, "\n{s}{s},\n", .{ indent, text });
        try out.appendSlice(arena, source[off..]);
        return out.items;
    }

    switch (anchor) {
        .append => {
            try appendAfter(arena, ast, source, members[members.len - 1], text, indent, &out);
            return out.items;
        },
        .before, .after => |target| {
            for (members) |m| {
                if (!std.mem.eql(u8, nameFn(ast, m), target)) continue;
                if (anchor == .before) {
                    const off = tokStart(ast, ast.firstToken(m));
                    try out.appendSlice(arena, source[0..off]);
                    try out.print(arena, "{s},\n{s}", .{ text, indent });
                    try out.appendSlice(arena, source[off..]);
                } else {
                    try appendAfter(arena, ast, source, m, text, indent, &out);
                }
                return out.items;
            }
            return SpliceError.AnchorNotFound;
        },
    }
}

/// Emit `source` with `text` spliced in right after `member` (and its trailing
/// comma, adding one if the member lacked it).
fn appendAfter(
    arena: std.mem.Allocator,
    ast: *Ast,
    source: [:0]const u8,
    member: Ast.Node.Index,
    text: []const u8,
    indent: []const u8,
    out: *std.ArrayList(u8),
) !void {
    const lt = ast.lastToken(member);
    var off = tokEnd(ast, lt);
    var need_comma = true;
    if (ast.tokens.items(.tag)[lt + 1] == .comma) {
        off = tokEnd(ast, lt + 1);
        need_comma = false;
    }
    try out.appendSlice(arena, source[0..off]);
    if (need_comma) try out.append(arena, ',');
    try out.print(arena, "\n{s}{s},", .{ indent, text });
    try out.appendSlice(arena, source[off..]);
}

// ---------------------------------------------------------------------------
// AST helpers (mirrors tree.zig's read patterns)
// ---------------------------------------------------------------------------

fn tokStart(ast: *const Ast, tok: Ast.TokenIndex) usize {
    return ast.tokens.items(.start)[tok];
}
fn tokEnd(ast: *const Ast, tok: Ast.TokenIndex) usize {
    return ast.tokens.items(.start)[tok] + ast.tokenSlice(tok).len;
}

fn findDeclInit(ast: *Ast, name: []const u8) ?Ast.Node.Index {
    const main_tokens = ast.nodes.items(.main_token);
    for (ast.rootDecls()) |decl| {
        const vd = ast.fullVarDecl(decl) orelse continue;
        const init = vd.ast.init_node.unwrap() orelse continue;
        if (std.mem.eql(u8, ast.tokenSlice(main_tokens[@intFromEnum(decl)] + 1), name)) return init;
    }
    return null;
}

fn nodeSource(ast: *Ast, node: Ast.Node.Index) []const u8 {
    return ast.source[tokStart(ast, ast.firstToken(node))..tokEnd(ast, ast.lastToken(node))];
}

fn memberName(ast: *Ast, member: Ast.Node.Index) []const u8 {
    const cf = ast.fullContainerField(member) orelse return "";
    return ast.tokenSlice(cf.ast.main_token);
}

fn initFieldName(ast: *Ast, field: Ast.Node.Index) []const u8 {
    return ast.tokenSlice(ast.firstToken(field) - 2);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Assert the spliced result parses without error (never emit broken Zig).
fn expectParses(arena: std.mem.Allocator, source: []const u8) !void {
    const ast = try Ast.parse(arena, try arena.dupeZ(u8, source), .zig);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
}

const shell =
    \\const std = @import("std");
    \\pub const meta = .{
    \\    .description = "Create a user",
    \\    .examples = &.{
    \\        "users create",
    \\    },
    \\    // .aliases = &.{"alias"},
    \\    // .hidden = true,
    \\};
    \\pub const Args = struct {};
    \\pub const Options = struct {};
    \\pub fn execute(_: Args, _: Options, _: anytype) !void {
    \\    // author's business logic — must survive splicing
    \\}
    \\
;

test "insertOption creates block, appends field, preserves execute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try insertOption(a, shell, .{
        .name = "limit",
        .elem_type = "u32",
        .multiple = false,
        .nullable = false,
        .default_expr = "10",
        .short = 'l',
        .description = "Max results",
    });
    try expectParses(a, out);
    try testing.expect(std.mem.indexOf(u8, out, "limit: u32 = 10,") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".limit = .{ .description = \"Max results\", .short = 'l' },") != null);
    try testing.expect(std.mem.indexOf(u8, out, "author's business logic") != null);

    // Chain a second option into the now-existing block.
    const out2 = try insertOption(a, try a.dupeZ(u8, out), .{
        .name = "verbose",
        .elem_type = "bool",
        .multiple = false,
        .nullable = false,
        .default_expr = "false",
        .description = "Loud",
    });
    try expectParses(a, out2);
    try testing.expect(std.mem.indexOf(u8, out2, "verbose: bool = false,") != null);
}

test "insertArg appends and positions with before/after" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try insertArg(a, shell, .{
        .name = "name",
        .elem_type = "[]const u8",
        .multiple = false,
        .nullable = false,
        .description = "Who",
    }, .append);
    try expectParses(a, one);
    try testing.expect(std.mem.indexOf(u8, one, "name: []const u8,") != null);
    try testing.expect(std.mem.indexOf(u8, one, ".name = \"Who\",") != null);

    const before = try insertArg(a, try a.dupeZ(u8, one), .{
        .name = "count",
        .elem_type = "u32",
        .multiple = false,
        .nullable = true,
        .description = "",
    }, .{ .before = "name" });
    try expectParses(a, before);
    const ci = std.mem.indexOf(u8, before, "count: ?u32 = null").?;
    const ni = std.mem.indexOf(u8, before, "name: []const u8").?;
    try testing.expect(ci < ni); // count spliced before name
}

test "duplicate field is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try insertOption(a, shell, .{
        .name = "limit",
        .elem_type = "u32",
        .multiple = false,
        .nullable = false,
        .default_expr = "10",
        .description = "",
    });
    try testing.expectError(SpliceError.DuplicateField, insertOption(a, try a.dupeZ(u8, one), .{
        .name = "limit",
        .elem_type = "u32",
        .multiple = false,
        .nullable = false,
        .default_expr = "1",
        .description = "",
    }));
}

test "fieldNames reads Args in source order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\pub const Args = struct { first: []const u8, second: u32 = 1 };
        \\
    ;
    const names = try fieldNames(a, src, "Args");
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("first", names[0]);
    try testing.expectEqualStrings("second", names[1]);
}

test "fieldShapes classifies required, optional, and variadic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\pub const Args = struct {
        \\    name: []const u8,
        \\    count: u32 = 1,
        \\    tag: ?[]const u8 = null,
        \\    rest: [][]const u8,
        \\};
        \\
    ;
    const shapes = try fieldShapes(a, src, "Args");
    try testing.expectEqual(@as(usize, 4), shapes.len);
    // name: required string (not optional, not multiple).
    try testing.expect(!shapes[0].optional and !shapes[0].multiple);
    // count: defaulted → optional.
    try testing.expect(shapes[1].optional and !shapes[1].multiple);
    // tag: nullable → optional.
    try testing.expect(shapes[2].optional);
    // rest: [][]const u8 → variadic.
    try testing.expect(shapes[3].multiple);
}
