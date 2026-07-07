const std = @import("std");
const zcli = @import("zcli");

const themed = zcli.theme.theme;
const Theme = zcli.theme.Theme;

// The framework's own command discovery — the same scan the build runs to
// generate the registry. Reusing it keeps the tree in lockstep with what the
// build actually wires up, with no rules duplicated here.
const command_discovery = zcli.command_discovery;
const CommandType = command_discovery.CommandType;
const CommandInfo = command_discovery.CommandInfo;

pub const meta = .{
    .description = "Show the command tree discovered from src/commands",
    .examples = &.{
        "tree",
        "tree --show-options",
    },
    .options = .{
        .show_options = .{ .description = "Include each command's arguments and options" },
    },
};

pub const Args = struct {};

pub const Options = struct {
    show_options: bool = false,
};

/// Maximum bytes read from any single command source file.
const max_source_bytes = 1024 * 1024;

pub fn execute(args: Args, options: Options, context: anytype) !void {
    _ = args;

    const io = context.io;
    const commands_dir = "src/commands";

    // One handle, used both to scan (discovery) and to read each command's
    // source (metadata). Must be iterable for the discovery walk.
    var dir = std.Io.Dir.cwd().openDir(io, commands_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            return context.fail("No '{s}' directory found. Run this from a zcli project root.", .{commands_dir});
        },
        else => return err,
    };
    defer dir.close(io);

    // Everything the tree allocates lives in this arena and is freed at once.
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Structure comes from the framework's discovery; descriptions/options are
    // layered on by parsing each file's source (see metadata extraction below).
    var discovered = try command_discovery.discoverInDir(arena, io, dir);
    const children = try nodesFromMap(arena, io, dir, &discovered.root);

    const stdout = context.stdout();
    const theme = &context.theme;

    // Root is the app name itself.
    try paint(stdout, theme, context.app_name, .header);
    try stdout.writeByte('\n');

    try renderNodes(arena, stdout, theme, children, "", options.show_options);
}

// ============================================================================
// Tree model
// ============================================================================

/// One arg or option in the enriched read-back (ADR-0007). Every field maps to
/// a glyph in the unified grammar: `<>`/`[]` (required/optional), `:type`,
/// `=default`, `...` (multiple/variadic), `/-short` (options only).
const Field = struct {
    name: []const u8,
    /// The value type shown after `:` — the element type for `multiple`
    /// fields and the inner type for optionals (the `<>`/`[]` bracket already
    /// carries optionality). Unused for bool options, which render bare.
    type_str: []const u8,
    /// `<>` when the argument must be supplied: no default, non-optional,
    /// non-variadic. Otherwise `[]`.
    required: bool,
    /// Default literal rendered as `=x`. Null when absent, `null`-valued, bool,
    /// or variadic (the latter two carry no meaningful default to surface).
    default: ?[]const u8 = null,
    /// Variadic arg / accumulating option → trailing `...`.
    multiple: bool = false,
    /// Options only: a short flag rendered as `/-x`.
    short: ?u8 = null,
    /// Bool options render as a bare flag (no `:type`, no value placeholder).
    is_bool: bool = false,
};

/// A display node: the framework's discovered structure enriched with the
/// metadata we parse from source (description, aliases, hidden, args, options).
const Node = struct {
    name: []const u8,
    command_type: CommandType,
    description: ?[]const u8 = null,
    aliases: []const []const u8 = &.{},
    hidden: bool = false,
    args: []const Field = &.{},
    options: []const Field = &.{},
    children: []const Node = &.{},

    fn isGroup(self: Node) bool {
        return self.command_type != .leaf;
    }
};

// ============================================================================
// Structure -> display nodes (discovery is the framework's; we only enrich)
// ============================================================================

/// Turn a discovered command map into sorted display nodes, parsing each
/// command's source for its description/args/options along the way.
fn nodesFromMap(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    map: *const std.StringHashMap(CommandInfo),
) ![]const Node {
    var nodes = std.ArrayList(Node).empty;

    var it = map.iterator();
    while (it.next()) |entry| {
        const info = entry.value_ptr.*;
        // For groups, file_path points at index.zig when present (otherwise a
        // directory, which simply yields no metadata).
        const parsed = parseFile(arena, io, dir, info.file_path);

        var node = Node{
            .name = info.name,
            .command_type = info.command_type,
            .description = parsed.description,
            .aliases = parsed.aliases,
            .hidden = parsed.hidden,
            .args = parsed.args,
            .options = parsed.options,
        };
        if (info.subcommands) |*subcommands| {
            node.children = try nodesFromMap(arena, io, dir, subcommands);
        }
        try nodes.append(arena, node);
    }

    std.mem.sort(Node, nodes.items, {}, lessByName);
    return nodes.items;
}

fn lessByName(_: void, a: Node, b: Node) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// ============================================================================
// Metadata extraction (std.zig.Ast — no build required)
// ============================================================================

const Ast = std.zig.Ast;

const ParsedMeta = struct {
    description: ?[]const u8 = null,
    aliases: []const []const u8 = &.{},
    hidden: bool = false,
    args: []const Field = &.{},
    options: []const Field = &.{},
};

/// A short flag declared in `meta.options.<name>.short`, matched back onto the
/// corresponding `Options` field by name.
const Short = struct { option: []const u8, char: u8 };

const MetaInfo = struct {
    description: ?[]const u8 = null,
    aliases: []const []const u8 = &.{},
    hidden: bool = false,
    shorts: []const Short = &.{},
};

/// Read and parse a command file. Files that can't be read or parsed degrade
/// to empty metadata so the command still appears in the tree.
fn parseFile(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) ParsedMeta {
    const raw = dir.readFileAlloc(io, sub_path, arena, .limited(max_source_bytes)) catch return .{};
    const source = arena.dupeZ(u8, raw) catch return .{};
    return parseMeta(arena, source) catch .{};
}

fn parseMeta(arena: std.mem.Allocator, source: [:0]const u8) !ParsedMeta {
    var ast = try Ast.parse(arena, source, .zig);

    var meta_info = MetaInfo{};
    var args: []Field = &.{};
    var options: []Field = &.{};
    const main_tokens = ast.nodes.items(.main_token);

    for (ast.rootDecls()) |decl| {
        const var_decl = ast.fullVarDecl(decl) orelse continue;
        const init = var_decl.ast.init_node.unwrap() orelse continue;
        const name = ast.tokenSlice(main_tokens[@intFromEnum(decl)] + 1);

        if (std.mem.eql(u8, name, "meta")) {
            meta_info = try extractMeta(arena, &ast, init);
        } else if (std.mem.eql(u8, name, "Args")) {
            args = try extractFields(arena, &ast, init);
        } else if (std.mem.eql(u8, name, "Options")) {
            options = try extractFields(arena, &ast, init);
        }
    }

    // Short flags live in `meta`, keyed by the option's field name.
    applyShorts(options, meta_info.shorts);

    return .{
        .description = meta_info.description,
        .aliases = meta_info.aliases,
        .hidden = meta_info.hidden,
        .args = args,
        .options = options,
    };
}

/// Overlay the `meta.options.<name>.short` chars onto the parsed Options fields.
fn applyShorts(options: []Field, shorts: []const Short) void {
    for (options) |*opt| {
        for (shorts) |s| {
            if (std.mem.eql(u8, opt.name, s.option)) {
                opt.short = s.char;
                break;
            }
        }
    }
}

/// Pull `description`, `aliases`, `hidden`, and per-option `short` flags out of
/// the `meta` struct literal. Only direct fields are inspected; unknown fields
/// (e.g. `examples`) are ignored.
fn extractMeta(arena: std.mem.Allocator, ast: *Ast, init: Ast.Node.Index) !MetaInfo {
    var buf: [2]Ast.Node.Index = undefined;
    const struct_init = ast.fullStructInit(&buf, init) orelse return .{};

    var result = MetaInfo{};
    for (struct_init.ast.fields) |field| {
        const key = fieldName(ast, field);
        if (std.mem.eql(u8, key, "description")) {
            if (ast.nodeTag(field) == .string_literal) {
                result.description = stringValue(arena, ast, field);
            }
        } else if (std.mem.eql(u8, key, "aliases")) {
            result.aliases = try extractAliases(arena, ast, field);
        } else if (std.mem.eql(u8, key, "hidden")) {
            result.hidden = std.mem.eql(u8, nodeSource(ast, field), "true");
        } else if (std.mem.eql(u8, key, "options")) {
            result.shorts = try extractShorts(arena, ast, field);
        }
    }
    return result;
}

/// `aliases = &.{ "a", "b" }` → the string values. Malformed shapes degrade to
/// an empty list rather than erroring.
fn extractAliases(arena: std.mem.Allocator, ast: *Ast, node: Ast.Node.Index) ![]const []const u8 {
    if (ast.nodeTag(node) != .address_of) return &.{};
    const array = ast.nodeData(node).node; // unwrap `&`

    var buf: [2]Ast.Node.Index = undefined;
    const array_init = ast.fullArrayInit(&buf, array) orelse return &.{};

    var list = std.ArrayList([]const u8).empty;
    for (array_init.ast.elements) |el| {
        if (ast.nodeTag(el) != .string_literal) continue;
        if (stringValue(arena, ast, el)) |s| try list.append(arena, s);
    }
    return list.items;
}

/// `options = .{ .name = .{ .short = 'x', ... }, ... }` → the `short` chars,
/// keyed by option name.
fn extractShorts(arena: std.mem.Allocator, ast: *Ast, node: Ast.Node.Index) ![]const Short {
    var buf: [2]Ast.Node.Index = undefined;
    const opts = ast.fullStructInit(&buf, node) orelse return &.{};

    var list = std.ArrayList(Short).empty;
    for (opts.ast.fields) |opt_field| {
        const opt_name = fieldName(ast, opt_field);
        var inner_buf: [2]Ast.Node.Index = undefined;
        const spec = ast.fullStructInit(&inner_buf, opt_field) orelse continue;
        for (spec.ast.fields) |spec_field| {
            if (!std.mem.eql(u8, fieldName(ast, spec_field), "short")) continue;
            if (ast.nodeTag(spec_field) != .char_literal) continue;
            const parsed = std.zig.parseCharLiteral(ast.tokenSlice(ast.nodeMainToken(spec_field)));
            if (parsed == .success and parsed.success < 128) {
                try list.append(arena, .{
                    .option = try arena.dupe(u8, opt_name),
                    .char = @intCast(parsed.success),
                });
            }
        }
    }
    return list.items;
}

/// Collect the fields of an `Args` or `Options` struct declaration.
fn extractFields(arena: std.mem.Allocator, ast: *Ast, init: Ast.Node.Index) ![]Field {
    var buf: [2]Ast.Node.Index = undefined;
    const container = ast.fullContainerDecl(&buf, init) orelse return &.{};

    var fields = std.ArrayList(Field).empty;
    for (container.ast.members) |member| {
        const field = ast.fullContainerField(member) orelse continue;
        const type_node = field.ast.type_expr.unwrap() orelse continue;
        const has_default = field.ast.value_expr != .none;

        const is_bool = std.mem.eql(u8, nodeSource(ast, type_node), "bool");
        const shape = analyzeType(ast, type_node);
        const required = !(has_default or shape.optional or shape.multiple);

        // Surface only meaningful defaults: bool `= false` and optional `= null`
        // are absence markers already implied by the grammar, and a variadic
        // field's default carries no useful shape.
        var default: ?[]const u8 = null;
        if (has_default and !is_bool and !shape.multiple) {
            const value = nodeSource(ast, field.ast.value_expr.unwrap().?);
            if (!std.mem.eql(u8, value, "null")) default = try arena.dupe(u8, value);
        }

        try fields.append(arena, .{
            .name = try arena.dupe(u8, unwrapIdent(ast.tokenSlice(field.ast.main_token))),
            .type_str = try arena.dupe(u8, shape.element),
            .required = required,
            .default = default,
            .multiple = shape.multiple,
            .is_bool = is_bool,
        });
    }
    return fields.items;
}

const TypeShape = struct {
    /// The value type after stripping optionality and the outer slice of a
    /// variadic/accumulating field.
    element: []const u8,
    optional: bool,
    multiple: bool,
};

/// Decompose a field's type into the shape the read-back grammar needs:
/// `?T` → optional; a `[]…` slice whose element isn't `u8` → multiple (with the
/// element type surfaced). `[]const u8` stays a whole string, not a multiple.
fn analyzeType(ast: *Ast, type_node: Ast.Node.Index) TypeShape {
    var node = type_node;
    var optional = false;
    if (ast.nodeTag(node) == .optional_type) {
        optional = true;
        node = ast.nodeData(node).node;
    }

    if (ast.fullPtrType(node)) |ptr| {
        if (ptr.size == .slice) {
            const child = nodeSource(ast, ptr.ast.child_type);
            if (!std.mem.eql(u8, child, "u8")) {
                return .{ .element = child, .optional = optional, .multiple = true };
            }
        }
    }
    return .{ .element = nodeSource(ast, node), .optional = optional, .multiple = false };
}

/// The declared name of a `.name = value` struct-init field (`.` <name> `=`).
fn fieldName(ast: *Ast, field: Ast.Node.Index) []const u8 {
    return ast.tokenSlice(ast.firstToken(field) - 2);
}

/// Parse a `.string_literal` node's value; null on a malformed literal.
fn stringValue(arena: std.mem.Allocator, ast: *Ast, node: Ast.Node.Index) ?[]const u8 {
    const raw = ast.tokenSlice(ast.nodeMainToken(node));
    return std.zig.string_literal.parseAlloc(arena, raw) catch null;
}

/// Unwrap a `@"quoted"` identifier to its bare name (e.g. `@"dry-run"` -> `dry-run`).
fn unwrapIdent(token: []const u8) []const u8 {
    if (std.mem.startsWith(u8, token, "@\"") and std.mem.endsWith(u8, token, "\"")) {
        return token[2 .. token.len - 1];
    }
    return token;
}

/// Source text spanned by a node (used to recover a type expression verbatim).
fn nodeSource(ast: *Ast, node: Ast.Node.Index) []const u8 {
    const starts = ast.tokens.items(.start);
    const first = ast.firstToken(node);
    const last = ast.lastToken(node);
    const start = starts[first];
    const end = starts[last] + ast.tokenSlice(last).len;
    return ast.source[start..end];
}

// ============================================================================
// Rendering
// ============================================================================

const Role = enum { plain, header, dim, group, leaf, marker, desc, flag };

fn paint(writer: anytype, theme: *const Theme, text: []const u8, role: Role) !void {
    const t = themed(text);
    switch (role) {
        .plain => try t.render(writer, theme),
        .header => try t.header().bold().render(writer, theme),
        .dim => try t.dim().render(writer, theme),
        .group => try t.info().bold().render(writer, theme),
        .leaf => try t.command().render(writer, theme),
        .marker => try t.muted().render(writer, theme),
        .desc => try t.muted().render(writer, theme),
        .flag => try t.flag().render(writer, theme),
    }
}

fn renderNodes(
    arena: std.mem.Allocator,
    writer: anytype,
    theme: *const Theme,
    nodes: []const Node,
    prefix: []const u8,
    show_options: bool,
) !void {
    for (nodes, 0..) |node, i| {
        const last = i == nodes.len - 1;

        try paint(writer, theme, prefix, .dim);
        try paint(writer, theme, if (last) "└── " else "├── ", .dim);
        try paint(writer, theme, node.name, if (node.isGroup()) .group else .leaf);
        if (node.isGroup()) {
            try paint(writer, theme, " (group)", .marker);
        }
        // The read-back surfaces the full authored truth (ADR-0007); the
        // default tree stays compact.
        if (show_options) {
            if (node.aliases.len > 0) {
                const list = try std.mem.join(arena, ",", node.aliases);
                try paint(writer, theme, try std.fmt.allocPrint(arena, " aliases={s}", .{list}), .marker);
            }
            if (node.hidden) {
                try paint(writer, theme, " (hidden)", .marker);
            }
        }
        if (node.description) |d| {
            try paint(writer, theme, " [", .desc);
            try paint(writer, theme, d, .desc);
            try paint(writer, theme, "]", .desc);
        }
        try writer.writeByte('\n');

        const child_prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, if (last) "    " else "│   " });

        if (show_options and node.command_type == .leaf) {
            try renderSignature(arena, writer, theme, node, child_prefix);
        }
        try renderNodes(arena, writer, theme, node.children, child_prefix, show_options);
    }
}

/// Render the args/options detail lines shown under `--show-options`.
fn renderSignature(
    arena: std.mem.Allocator,
    writer: anytype,
    theme: *const Theme,
    node: Node,
    prefix: []const u8,
) !void {
    if (node.args.len > 0) {
        try paint(writer, theme, prefix, .dim);
        try paint(writer, theme, "args:    ", .marker);
        for (node.args, 0..) |arg, i| {
            if (i > 0) try writer.writeByte(' ');
            try paint(writer, theme, try renderField(arena, arg, false), .flag);
        }
        try writer.writeByte('\n');
    }

    if (node.options.len > 0) {
        try paint(writer, theme, prefix, .dim);
        try paint(writer, theme, "options: ", .marker);
        for (node.options, 0..) |opt, i| {
            if (i > 0) try writer.writeByte(' ');
            try paint(writer, theme, try renderField(arena, opt, true), .flag);
        }
        try writer.writeByte('\n');
    }
}

/// Render one field in the unified grammar (ADR-0007):
/// `<name:type=default...>` with `<>`/`[]` for required/optional, and options
/// carrying a `--` prefix plus an optional `/-short`. Bool options render bare.
fn renderField(arena: std.mem.Allocator, field: Field, is_option: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeByte(if (field.required) '<' else '[');
    if (is_option) {
        try w.print("--{s}", .{try toFlagName(arena, field.name)});
        if (field.short) |s| try w.print("/-{c}", .{s});
    } else {
        try w.writeAll(field.name);
    }
    if (!field.is_bool) try w.print(":{s}", .{field.type_str});
    if (field.default) |d| try w.print("={s}", .{d});
    if (field.multiple) try w.writeAll("...");
    try w.writeByte(if (field.required) '>' else ']');

    return aw.written();
}

/// Option field names are snake_case; CLI flags are kebab-case.
fn toFlagName(arena: std.mem.Allocator, field: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, field);
    for (out) |*c| {
        if (c.* == '_') c.* = '-';
    }
    return out;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn renderToString(arena: std.mem.Allocator, nodes: []const Node, show_options: bool) ![]const u8 {
    const theme = Theme.initWithCapability(.no_color, std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try renderNodes(arena, &aw.writer, &theme, nodes, "", show_options);
    return aw.written();
}

test "parseMeta extracts top-level description, ignoring nested ones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\pub const meta = .{
        \\    .description = "Say hello",
        \\    .options = .{ .loud = .{ .short = 'l', .description = "shout it" } },
        \\};
        \\pub const Args = struct { name: []const u8, count: u32 = 1 };
        \\pub const Options = struct { loud: bool = false, repeat: ?u32 = null };
    ;
    const parsed = try parseMeta(arena, source);

    try testing.expectEqualStrings("Say hello", parsed.description.?);

    try testing.expectEqual(@as(usize, 2), parsed.args.len);
    try testing.expectEqualStrings("name", parsed.args[0].name);
    try testing.expectEqualStrings("[]const u8", parsed.args[0].type_str);
    try testing.expect(parsed.args[0].required);
    try testing.expectEqualStrings("count", parsed.args[1].name);
    try testing.expect(!parsed.args[1].required); // has default
    try testing.expectEqualStrings("1", parsed.args[1].default.?);

    try testing.expectEqual(@as(usize, 2), parsed.options.len);
    try testing.expectEqualStrings("loud", parsed.options[0].name);
    try testing.expect(parsed.options[0].is_bool);
    try testing.expectEqual(@as(u8, 'l'), parsed.options[0].short.?);
    try testing.expectEqualStrings("repeat", parsed.options[1].name);
    try testing.expectEqualStrings("u32", parsed.options[1].type_str); // optional stripped
    try testing.expect(!parsed.options[1].required);
    try testing.expect(parsed.options[1].default == null); // `= null` suppressed
}

test "parseMeta captures aliases, hidden, defaults, and variadic shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\pub const meta = .{
        \\    .description = "Create a user",
        \\    .aliases = &.{ "add", "new" },
        \\    .hidden = true,
        \\    .options = .{ .repeat = .{ .short = 'r' } },
        \\};
        \\pub const Args = struct { name: []const u8, files: [][]const u8 };
        \\pub const Options = struct {
        \\    token: []const u8,
        \\    repeat: ?u32 = null,
        \\    limit: u32 = 10,
        \\    tags: []const []const u8 = &.{},
        \\};
    ;
    const parsed = try parseMeta(arena, source);

    try testing.expectEqual(@as(usize, 2), parsed.aliases.len);
    try testing.expectEqualStrings("add", parsed.aliases[0]);
    try testing.expectEqualStrings("new", parsed.aliases[1]);
    try testing.expect(parsed.hidden);

    // files: variadic arg → element type surfaced, multiple set, not required.
    try testing.expectEqualStrings("files", parsed.args[1].name);
    try testing.expectEqualStrings("[]const u8", parsed.args[1].type_str);
    try testing.expect(parsed.args[1].multiple);
    try testing.expect(!parsed.args[1].required);

    // token: required (no default, non-optional, non-variadic).
    try testing.expect(parsed.options[0].required);
    // repeat: short applied from meta.
    try testing.expectEqual(@as(u8, 'r'), parsed.options[1].short.?);
    // limit: meaningful default surfaced.
    try testing.expectEqualStrings("10", parsed.options[2].default.?);
    // tags: accumulating option → multiple, default suppressed.
    try testing.expect(parsed.options[3].multiple);
    try testing.expect(parsed.options[3].default == null);
    try testing.expectEqualStrings("[]const u8", parsed.options[3].type_str);
}

test "parseMeta unwraps @\"quoted\" option field names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\pub const Options = struct { @"dry-run": bool = false };
    ;
    const parsed = try parseMeta(arena, source);
    try testing.expectEqual(@as(usize, 1), parsed.options.len);
    try testing.expectEqualStrings("dry-run", parsed.options[0].name);
}

test "parseMeta tolerates a missing meta block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseMeta(arena, "pub const Args = struct {};");
    try testing.expect(parsed.description == null);
    try testing.expectEqual(@as(usize, 0), parsed.args.len);
}

test "renderNodes draws a sorted, annotated tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nodes = [_]Node{
        .{
            .name = "config",
            .command_type = .pure_group,
            .children = &.{
                .{ .name = "get", .command_type = .leaf },
                .{ .name = "set", .command_type = .leaf },
            },
        },
        .{ .name = "deploy", .command_type = .leaf, .description = "Deploy the app" },
    };

    const out = try renderToString(arena, &nodes, false);
    const expected =
        "├── config (group)\n" ++
        "│   ├── get\n" ++
        "│   └── set\n" ++
        "└── deploy [Deploy the app]\n";
    try testing.expectEqualStrings(expected, out);
}

test "renderNodes with show_options lists args and options" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nodes = [_]Node{
        .{
            .name = "create",
            .command_type = .leaf,
            .aliases = &.{"add"},
            .args = &.{
                .{ .name = "name", .type_str = "[]const u8", .required = true },
                .{ .name = "count", .type_str = "u32", .required = false, .default = "1" },
                .{ .name = "files", .type_str = "[]const u8", .required = false, .multiple = true },
            },
            .options = &.{
                .{ .name = "loud", .type_str = "", .required = false, .short = 'l', .is_bool = true },
                .{ .name = "token", .type_str = "[]const u8", .required = true },
                .{ .name = "repeat", .type_str = "u32", .required = false, .short = 'r' },
                .{ .name = "limit", .type_str = "u32", .required = false, .default = "10" },
                .{ .name = "max_tags", .type_str = "[]const u8", .required = false, .multiple = true },
            },
        },
    };

    const out = try renderToString(arena, &nodes, true);
    const expected =
        "└── create aliases=add\n" ++
        "    args:    <name:[]const u8> [count:u32=1] [files:[]const u8...]\n" ++
        "    options: [--loud/-l] <--token:[]const u8> [--repeat/-r:u32] [--limit:u32=10] [--max-tags:[]const u8...]\n";
    try testing.expectEqualStrings(expected, out);
}

test "renderNodes hides aliases and hidden marker without show_options" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nodes = [_]Node{
        .{ .name = "create", .command_type = .leaf, .aliases = &.{"add"}, .hidden = true },
    };

    const out = try renderToString(arena, &nodes, false);
    try testing.expectEqualStrings("└── create\n", out);
}

test "nodesFromMap sorts, maps kinds, and enriches with metadata" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    // Source files the enrichment step reads for descriptions/options.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "deploy.zig",
        .data = "pub const meta = .{ .description = \"Ship it\" };",
    });
    try tmp.dir.createDir(io, "users", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "users/list.zig", .data = "pub const meta = .{};" });

    // A discovery result as produced by the framework's discoverInDir.
    var users_sub = std.StringHashMap(CommandInfo).init(arena);
    try users_sub.put("list", .{
        .name = "list",
        .path = &.{ "users", "list" },
        .file_path = "users/list.zig",
        .command_type = .leaf,
        .subcommands = null,
    });
    var root = std.StringHashMap(CommandInfo).init(arena);
    try root.put("users", .{
        .name = "users",
        .path = &.{"users"},
        .file_path = "users", // pure group: a directory, yields no metadata
        .command_type = .pure_group,
        .subcommands = users_sub,
    });
    try root.put("deploy", .{
        .name = "deploy",
        .path = &.{"deploy"},
        .file_path = "deploy.zig",
        .command_type = .leaf,
        .subcommands = null,
    });

    const nodes = try nodesFromMap(arena, io, tmp.dir, &root);

    // Sorted by name: deploy, users.
    try testing.expectEqual(@as(usize, 2), nodes.len);

    try testing.expectEqualStrings("deploy", nodes[0].name);
    try testing.expectEqual(CommandType.leaf, nodes[0].command_type);
    try testing.expectEqualStrings("Ship it", nodes[0].description.?);

    try testing.expectEqualStrings("users", nodes[1].name);
    try testing.expectEqual(CommandType.pure_group, nodes[1].command_type);
    try testing.expect(nodes[1].description == null);
    try testing.expectEqual(@as(usize, 1), nodes[1].children.len);
    try testing.expectEqualStrings("list", nodes[1].children[0].name);
}
