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
    FieldNotFound,
    ResultDoesNotParse,
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
    const result = try insertMetaEntry(arena, try arena.dupeZ(u8, with_field), "options", entry);
    return ensureParses(arena, result);
}

/// Add an argument to a command's source: a field in `Args` (at `anchor`) and an
/// entry in `meta.args` (created if absent). Returns newly allocated source.
pub fn insertArg(arena: std.mem.Allocator, source: [:0]const u8, a: spec.ArgSpec, anchor: Anchor) ![]u8 {
    try ensureNoField(arena, source, "Args", a.name);
    const field = try spec.renderArgField(arena, a);
    const with_field = try insertStructField(arena, source, "Args", field, anchor);
    const entry = try spec.renderArgMetaEntry(arena, a);
    const result = try insertMetaEntry(arena, try arena.dupeZ(u8, with_field), "args", entry);
    return ensureParses(arena, result);
}

/// Guard against emitting Zig that won't compile: re-parse the spliced result and
/// refuse it (leaving the caller to abort before writing) if the AST has errors.
/// A user-supplied `--type` is spliced verbatim, so a typo like `--type u3 2`
/// would otherwise rewrite the file into a non-compiling state under a success
/// message. `insertStructField`/`insertMetaEntry` are safe to reuse directly in
/// chained splices — they re-parse each intermediate result themselves.
fn ensureParses(arena: std.mem.Allocator, result: []u8) ![]u8 {
    const ast = try Ast.parse(arena, try arena.dupeZ(u8, result), .zig);
    if (ast.errors.len != 0) return SpliceError.ResultDoesNotParse;
    return result;
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

/// The `targets` that are not fields of `container`, in the given order. Empty
/// slice → all present. Lets a bulk `rm` reject the whole batch before editing.
pub fn missingFields(arena: std.mem.Allocator, source: [:0]const u8, container: []const u8, targets: []const []const u8) ![]const []const u8 {
    const existing = try fieldNames(arena, source, container);
    var missing = std.ArrayList([]const u8).empty;
    for (targets) |t| {
        var found = false;
        for (existing) |e| {
            if (std.mem.eql(u8, e, t)) {
                found = true;
                break;
            }
        }
        if (!found) try missing.append(arena, t);
    }
    return missing.items;
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
// Removal (the splice-out inverse of insert*)
// ---------------------------------------------------------------------------

/// Remove an option from a command's source: its field in `Options` and its
/// entry in `meta.options`. Errors if the field does not exist; a missing meta
/// entry is tolerated (the struct field is the source of truth).
pub fn removeOption(arena: std.mem.Allocator, source: [:0]const u8, name: []const u8) ![]u8 {
    const without_field = try removeStructField(arena, source, "Options", name);
    return removeMetaEntry(arena, try arena.dupeZ(u8, without_field), "options", name);
}

/// Remove an argument from a command's source: its field in `Args` and its entry
/// in `meta.args`. Errors if the field does not exist.
pub fn removeArg(arena: std.mem.Allocator, source: [:0]const u8, name: []const u8) ![]u8 {
    const without_field = try removeStructField(arena, source, "Args", name);
    return removeMetaEntry(arena, try arena.dupeZ(u8, without_field), "args", name);
}

/// Remove the `name` field from `pub const <container> = struct {...}`.
fn removeStructField(arena: std.mem.Allocator, source: [:0]const u8, container: []const u8, name: []const u8) ![]u8 {
    var ast = try Ast.parse(arena, source, .zig);
    const init = findDeclInit(&ast, container) orelse return SpliceError.ContainerNotFound;
    var buf: [2]Ast.Node.Index = undefined;
    const cd = ast.fullContainerDecl(&buf, init) orelse return SpliceError.NotAStruct;

    for (cd.ast.members) |m| {
        if (std.mem.eql(u8, memberName(&ast, m), name)) {
            return cutSpan(arena, source, memberSpan(&ast, source, ast.firstToken(m), ast.lastToken(m)));
        }
    }
    return SpliceError.FieldNotFound;
}

/// Remove the `.name` entry from `meta.<sub> = .{...}`. If it was the only entry,
/// the whole `.<sub> = .{...}` meta field is removed. A missing block or entry is
/// tolerated (no-op) — the struct field, not the meta, defines the field.
fn removeMetaEntry(arena: std.mem.Allocator, source: [:0]const u8, sub: []const u8, name: []const u8) ![]u8 {
    var ast = try Ast.parse(arena, source, .zig);
    const init = findDeclInit(&ast, "meta") orelse return SpliceError.NoMeta;
    var buf: [2]Ast.Node.Index = undefined;
    const si = ast.fullStructInit(&buf, init) orelse return SpliceError.MetaNotStruct;

    for (si.ast.fields) |field| {
        if (!std.mem.eql(u8, initFieldName(&ast, field), sub)) continue;

        var b2: [2]Ast.Node.Index = undefined;
        const inner = ast.fullStructInit(&b2, field) orelse return SpliceError.SubNotStruct;

        // Last entry → drop the whole `.sub = .{...}` meta field.
        if (inner.ast.fields.len == 1 and std.mem.eql(u8, initFieldName(&ast, inner.ast.fields[0]), name)) {
            return cutSpan(arena, source, metaFieldSpan(&ast, source, field));
        }
        for (inner.ast.fields) |entry| {
            if (std.mem.eql(u8, initFieldName(&ast, entry), name)) {
                return cutSpan(arena, source, metaFieldSpan(&ast, source, entry));
            }
        }
        break; // block found, entry absent → tolerate
    }
    return arena.dupe(u8, source); // block/entry absent → unchanged
}

/// The byte range to cut for a struct field: from its first token through its
/// trailing comma, extended over the surrounding same-line whitespace and the
/// trailing newline so the whole line is removed cleanly.
fn memberSpan(ast: *Ast, source: [:0]const u8, first: Ast.TokenIndex, last: Ast.TokenIndex) [2]usize {
    var lo = tokStart(ast, first);
    while (lo > 0 and (source[lo - 1] == ' ' or source[lo - 1] == '\t')) lo -= 1;

    var hi = tokEnd(ast, last);
    if (ast.tokens.items(.tag)[last + 1] == .comma) hi = tokEnd(ast, last + 1);
    while (hi < source.len and (source[hi] == ' ' or source[hi] == '\t')) hi += 1;
    if (hi < source.len and source[hi] == '\n') hi += 1;

    return .{ lo, hi };
}

/// Like `memberSpan` but for a `meta` struct-init field, whose logical start is
/// the leading `.` (three tokens before the value: `.` `name` `=`).
fn metaFieldSpan(ast: *Ast, source: [:0]const u8, field: Ast.Node.Index) [2]usize {
    return memberSpan(ast, source, ast.firstToken(field) - 3, ast.lastToken(field));
}

fn cutSpan(arena: std.mem.Allocator, source: [:0]const u8, span: [2]usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(arena, source[0..span[0]]);
    try out.appendSlice(arena, source[span[1]..]);
    return out.items;
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

test "removeOption strips the field and its meta entry, preserving execute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build a command with two options, then remove one.
    const one = try insertOption(a, shell, .{
        .name = "limit",
        .elem_type = "u32",
        .multiple = false,
        .nullable = false,
        .default_expr = "10",
        .description = "Max",
    });
    const two = try insertOption(a, try a.dupeZ(u8, one), .{
        .name = "verbose",
        .elem_type = "bool",
        .multiple = false,
        .nullable = false,
        .default_expr = "false",
        .description = "Loud",
    });

    const out = try removeOption(a, try a.dupeZ(u8, two), "limit");
    try expectParses(a, out);
    try testing.expect(std.mem.indexOf(u8, out, "limit") == null); // field + meta entry gone
    try testing.expect(std.mem.indexOf(u8, out, "verbose: bool = false,") != null); // sibling kept
    try testing.expect(std.mem.indexOf(u8, out, "author's business logic") != null);
}

test "removing the only option drops the emptied meta.options block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try insertOption(a, shell, .{
        .name = "limit",
        .elem_type = "u32",
        .multiple = false,
        .nullable = false,
        .default_expr = "10",
        .description = "Max",
    });
    const out = try removeOption(a, try a.dupeZ(u8, one), "limit");
    try expectParses(a, out);
    try testing.expect(std.mem.indexOf(u8, out, ".options") == null); // whole meta block removed
    try testing.expect(std.mem.indexOf(u8, out, "limit") == null); // field gone; Options now empty
}

test "removeArg strips the field and keeps ordering of the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = try insertArg(a, shell, .{ .name = "name", .elem_type = "[]const u8", .multiple = false, .nullable = false, .description = "Who" }, .append);
    const two = try insertArg(a, try a.dupeZ(u8, one), .{ .name = "count", .elem_type = "u32", .multiple = false, .nullable = true, .description = "" }, .append);

    const out = try removeArg(a, try a.dupeZ(u8, two), "name");
    try expectParses(a, out);
    try testing.expect(std.mem.indexOf(u8, out, "name:") == null);
    try testing.expect(std.mem.indexOf(u8, out, "count: ?u32 = null,") != null);
}

test "removing an absent field errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(SpliceError.FieldNotFound, removeOption(a, shell, "ghost"));
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

test "insertOption rejects a --type that would not compile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A malformed element type is spliced verbatim into `Options`, yielding
    // `bad field: u3 2 = null` — which does not parse. The splice must refuse it
    // rather than hand back non-compiling source the caller would write.
    try testing.expectError(SpliceError.ResultDoesNotParse, insertOption(a, shell, .{
        .name = "bad",
        .elem_type = "u3 2",
        .multiple = false,
        .nullable = true,
        .default_expr = null,
        .description = "",
    }));
}

test "insertArg rejects a --type that would not compile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(SpliceError.ResultDoesNotParse, insertArg(a, shell, .{
        .name = "bad",
        .elem_type = "u3 2",
        .multiple = false,
        .nullable = true,
        .description = "",
    }, .append));
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
