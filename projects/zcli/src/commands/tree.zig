const std = @import("std");
const zcli = @import("zcli");

const ztheme = zcli.ztheme;
const Theme = ztheme.Theme;

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

    const io = context.io.io;
    const commands_dir = "src/commands";

    // One handle, used both to scan (discovery) and to read each command's
    // source (metadata). Must be iterable for the discovery walk.
    var dir = std.Io.Dir.cwd().openDir(io, commands_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            const stderr = context.stderr();
            try stderr.print("No '{s}' directory found. Run this from a zcli project root.\n", .{commands_dir});
            try stderr.flush(); // process.exit won't flush the buffered writer
            context.exit(1);
            return;
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

const Field = struct {
    name: []const u8,
    type_str: []const u8,
    /// True when the field has a default value or an optional type.
    optional: bool,
};

/// A display node: the framework's discovered structure enriched with the
/// metadata we parse from source (description, args, options).
const Node = struct {
    name: []const u8,
    command_type: CommandType,
    description: ?[]const u8 = null,
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

const ParsedMeta = struct {
    description: ?[]const u8 = null,
    args: []const Field = &.{},
    options: []const Field = &.{},
};

/// Read and parse a command file. Files that can't be read or parsed degrade
/// to empty metadata so the command still appears in the tree.
fn parseFile(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) ParsedMeta {
    const raw = dir.readFileAlloc(io, sub_path, arena, .limited(max_source_bytes)) catch return .{};
    const source = arena.dupeZ(u8, raw) catch return .{};
    return parseMeta(arena, source) catch .{};
}

fn parseMeta(arena: std.mem.Allocator, source: [:0]const u8) !ParsedMeta {
    const Ast = std.zig.Ast;
    var ast = try Ast.parse(arena, source, .zig);

    var result = ParsedMeta{};
    const main_tokens = ast.nodes.items(.main_token);

    for (ast.rootDecls()) |decl| {
        const var_decl = ast.fullVarDecl(decl) orelse continue;
        const init = var_decl.ast.init_node.unwrap() orelse continue;
        const name = ast.tokenSlice(main_tokens[@intFromEnum(decl)] + 1);

        if (std.mem.eql(u8, name, "meta")) {
            result.description = try extractDescription(arena, &ast, init);
        } else if (std.mem.eql(u8, name, "Args")) {
            result.args = try extractFields(arena, &ast, init);
        } else if (std.mem.eql(u8, name, "Options")) {
            result.options = try extractFields(arena, &ast, init);
        }
    }
    return result;
}

/// Pull `.description` out of the `meta` struct literal. Only direct fields are
/// inspected, so nested `.options.<x>.description` entries are ignored.
fn extractDescription(arena: std.mem.Allocator, ast: *std.zig.Ast, init: std.zig.Ast.Node.Index) !?[]const u8 {
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const struct_init = ast.fullStructInit(&buf, init) orelse return null;
    const tags = ast.nodes.items(.tag);

    for (struct_init.ast.fields) |field| {
        const name_tok = ast.firstToken(field) - 2; // `.` <name> `=` value
        if (!std.mem.eql(u8, ast.tokenSlice(name_tok), "description")) continue;
        if (tags[@intFromEnum(field)] != .string_literal) return null;
        const raw = ast.tokenSlice(ast.nodes.items(.main_token)[@intFromEnum(field)]);
        return std.zig.string_literal.parseAlloc(arena, raw) catch null;
    }
    return null;
}

/// Collect the fields of an `Args` or `Options` struct declaration.
fn extractFields(arena: std.mem.Allocator, ast: *std.zig.Ast, init: std.zig.Ast.Node.Index) ![]const Field {
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const container = ast.fullContainerDecl(&buf, init) orelse return &.{};
    const tags = ast.nodes.items(.tag);

    var fields = std.ArrayList(Field).empty;
    for (container.ast.members) |member| {
        const field = ast.fullContainerField(member) orelse continue;
        const type_node = field.ast.type_expr.unwrap() orelse continue;
        const has_default = field.ast.value_expr != .none;
        const is_optional_type = tags[@intFromEnum(type_node)] == .optional_type;

        try fields.append(arena, .{
            .name = try arena.dupe(u8, unwrapIdent(ast.tokenSlice(field.ast.main_token))),
            .type_str = try arena.dupe(u8, nodeSource(ast, type_node)),
            .optional = has_default or is_optional_type,
        });
    }
    return fields.items;
}

/// Unwrap a `@"quoted"` identifier to its bare name (e.g. `@"dry-run"` -> `dry-run`).
fn unwrapIdent(token: []const u8) []const u8 {
    if (std.mem.startsWith(u8, token, "@\"") and std.mem.endsWith(u8, token, "\"")) {
        return token[2 .. token.len - 1];
    }
    return token;
}

/// Source text spanned by a node (used to recover a type expression verbatim).
fn nodeSource(ast: *std.zig.Ast, node: std.zig.Ast.Node.Index) []const u8 {
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
    const t = ztheme.theme(text);
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
            const text = try std.fmt.allocPrint(arena, "{s}{s}:{s}{s}", .{
                if (arg.optional) "[" else "<",
                arg.name,
                arg.type_str,
                if (arg.optional) "]" else ">",
            });
            try paint(writer, theme, text, .flag);
        }
        try writer.writeByte('\n');
    }

    if (node.options.len > 0) {
        try paint(writer, theme, prefix, .dim);
        try paint(writer, theme, "options: ", .marker);
        for (node.options, 0..) |opt, i| {
            if (i > 0) try writer.writeByte(' ');
            const flag = try toFlagName(arena, opt.name);
            // bool flags need no value placeholder.
            const text = if (std.mem.eql(u8, opt.type_str, "bool"))
                try std.fmt.allocPrint(arena, "--{s}", .{flag})
            else
                try std.fmt.allocPrint(arena, "--{s} <{s}>", .{ flag, opt.type_str });
            try paint(writer, theme, text, .flag);
        }
        try writer.writeByte('\n');
    }
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
        \\    .options = .{ .loud = .{ .description = "shout it" } },
        \\};
        \\pub const Args = struct { name: []const u8, count: u32 = 1 };
        \\pub const Options = struct { loud: bool = false, repeat: ?u32 = null };
    ;
    const parsed = try parseMeta(arena, source);

    try testing.expectEqualStrings("Say hello", parsed.description.?);

    try testing.expectEqual(@as(usize, 2), parsed.args.len);
    try testing.expectEqualStrings("name", parsed.args[0].name);
    try testing.expectEqualStrings("[]const u8", parsed.args[0].type_str);
    try testing.expect(!parsed.args[0].optional);
    try testing.expectEqualStrings("count", parsed.args[1].name);
    try testing.expect(parsed.args[1].optional); // has default

    try testing.expectEqual(@as(usize, 2), parsed.options.len);
    try testing.expectEqualStrings("loud", parsed.options[0].name);
    try testing.expectEqualStrings("bool", parsed.options[0].type_str);
    try testing.expectEqualStrings("repeat", parsed.options[1].name);
    try testing.expectEqualStrings("?u32", parsed.options[1].type_str);
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
            .name = "add",
            .command_type = .leaf,
            .args = &.{.{ .name = "title", .type_str = "[]const u8", .optional = false }},
            .options = &.{
                .{ .name = "loud", .type_str = "bool", .optional = true },
                .{ .name = "max_count", .type_str = "?u32", .optional = true },
            },
        },
    };

    const out = try renderToString(arena, &nodes, true);
    const expected =
        "└── add\n" ++
        "    args:    <title:[]const u8>\n" ++
        "    options: --loud --max-count <?u32>\n";
    try testing.expectEqualStrings(expected, out);
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
