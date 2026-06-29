const std = @import("std");
const zcli = @import("zcli");

const ztheme = zcli.ztheme;
const Theme = ztheme.Theme;

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
/// Maximum directory nesting, matching the framework's build-time discovery.
const max_depth = 6;

pub fn execute(args: Args, options: Options, context: anytype) !void {
    _ = args;

    const commands_dir = "src/commands";

    var dir = std.fs.cwd().openDir(commands_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try context.stderr().print("No '{s}' directory found. Run this from a zcli project root.\n", .{commands_dir});
            context.exit(1);
            return;
        },
        else => return err,
    };
    defer dir.close();

    // Everything the tree allocates lives in this arena and is freed at once.
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const children = try buildChildren(arena, dir, 0);

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

const Kind = enum { leaf, pure_group, optional_group };

const Field = struct {
    name: []const u8,
    type_str: []const u8,
    /// True when the field has a default value or an optional type.
    optional: bool,
};

const Node = struct {
    name: []const u8,
    kind: Kind,
    description: ?[]const u8 = null,
    args: []const Field = &.{},
    options: []const Field = &.{},
    children: []const Node = &.{},

    fn isGroup(self: Node) bool {
        return self.kind != .leaf;
    }
};

// ============================================================================
// Discovery — mirrors packages/core/src/build_utils/command_discovery.zig
// ============================================================================

/// Scan a commands directory and return its child nodes, sorted by name.
fn buildChildren(arena: std.mem.Allocator, dir: std.fs.Dir, depth: u32) ![]const Node {
    if (depth >= max_depth) return &.{};

    var nodes = std.ArrayList(Node){};

    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const name = entry.name[0 .. entry.name.len - 4];
                if (std.mem.eql(u8, name, "index")) continue; // group landing, not a command
                if (!isValidCommandName(name)) continue;

                const parsed = parseFile(arena, dir, entry.name);
                try nodes.append(arena, .{
                    .name = try arena.dupe(u8, name),
                    .kind = .leaf,
                    .description = parsed.description,
                    .args = parsed.args,
                    .options = parsed.options,
                });
            },
            .directory => {
                if (entry.name[0] == '.') continue;
                if (!isValidCommandName(entry.name)) continue;

                var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer subdir.close();

                const children = try buildChildren(arena, subdir, depth + 1);
                const has_index = hasIndexFile(subdir);

                // A directory is only a command group if it has subcommands or an index.
                if (children.len == 0 and !has_index) continue;

                // The group's own description comes from its index.zig, if present.
                const description = if (has_index)
                    parseFile(arena, subdir, "index.zig").description
                else
                    null;

                try nodes.append(arena, .{
                    .name = try arena.dupe(u8, entry.name),
                    .kind = if (has_index) .optional_group else .pure_group,
                    .description = description,
                    .children = children,
                });
            },
            else => continue,
        }
    }

    std.mem.sort(Node, nodes.items, {}, lessByName);
    return nodes.items;
}

fn lessByName(_: void, a: Node, b: Node) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn hasIndexFile(dir: std.fs.Dir) bool {
    _ = dir.statFile("index.zig") catch return false;
    return true;
}

/// Naming rules from the framework's discovery (security + identifier shape).
fn isValidCommandName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOfAny(u8, name, "/\\\x00") != null) return false;

    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
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
fn parseFile(arena: std.mem.Allocator, dir: std.fs.Dir, sub_path: []const u8) ParsedMeta {
    var file = dir.openFile(sub_path, .{}) catch return .{};
    defer file.close();
    const raw = file.readToEndAlloc(arena, max_source_bytes) catch return .{};
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

    var fields = std.ArrayList(Field){};
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

        if (show_options and node.kind == .leaf) {
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
    const theme = Theme.initWithCapability(.no_color);
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
            .kind = .pure_group,
            .children = &.{
                .{ .name = "get", .kind = .leaf },
                .{ .name = "set", .kind = .leaf },
            },
        },
        .{ .name = "deploy", .kind = .leaf, .description = "Deploy the app" },
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
            .kind = .leaf,
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

test "buildChildren discovers leaves and groups like the framework" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A leaf with a description.
    try tmp.dir.writeFile(.{
        .sub_path = "deploy.zig",
        .data = "pub const meta = .{ .description = \"Ship it\" };",
    });
    // index.zig at this level is a group landing, not a command -> skipped.
    try tmp.dir.writeFile(.{ .sub_path = "index.zig", .data = "pub const meta = .{};" });
    // A pure group (no index) with two subcommands.
    try tmp.dir.makeDir("users");
    try tmp.dir.writeFile(.{ .sub_path = "users/create.zig", .data = "pub const meta = .{};" });
    try tmp.dir.writeFile(.{ .sub_path = "users/list.zig", .data = "pub const meta = .{};" });
    // An optional group: only an index.zig, no subcommands.
    try tmp.dir.makeDir("config");
    try tmp.dir.writeFile(.{
        .sub_path = "config/index.zig",
        .data = "pub const meta = .{ .description = \"Settings\" };",
    });
    // An empty directory is not a command at all -> skipped.
    try tmp.dir.makeDir("scratch");

    var dir = try tmp.dir.openDir(".", .{ .iterate = true });
    defer dir.close();
    const nodes = try buildChildren(arena, dir, 0);

    // Sorted: config, deploy, users (scratch and index.zig excluded).
    try testing.expectEqual(@as(usize, 3), nodes.len);

    try testing.expectEqualStrings("config", nodes[0].name);
    try testing.expectEqual(Kind.optional_group, nodes[0].kind);
    try testing.expectEqualStrings("Settings", nodes[0].description.?);
    try testing.expectEqual(@as(usize, 0), nodes[0].children.len);

    try testing.expectEqualStrings("deploy", nodes[1].name);
    try testing.expectEqual(Kind.leaf, nodes[1].kind);
    try testing.expectEqualStrings("Ship it", nodes[1].description.?);

    try testing.expectEqualStrings("users", nodes[2].name);
    try testing.expectEqual(Kind.pure_group, nodes[2].kind);
    try testing.expectEqual(@as(usize, 2), nodes[2].children.len);
    try testing.expectEqualStrings("create", nodes[2].children[0].name);
    try testing.expectEqualStrings("list", nodes[2].children[1].name);
}

test "isValidCommandName matches the framework rules" {
    try testing.expect(isValidCommandName("deploy"));
    try testing.expect(isValidCommandName("user_list"));
    try testing.expect(isValidCommandName("get-data"));
    try testing.expect(!isValidCommandName(""));
    try testing.expect(!isValidCommandName("123cmd"));
    try testing.expect(!isValidCommandName("../etc"));
    try testing.expect(!isValidCommandName("a/b"));
}
