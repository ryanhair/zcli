//! Filesystem helpers for the whole-file scaffolding commands (`mv`,
//! `rm command`). Pure of any Context — just std IO — so it lives beside `spec`
//! and `splice` in the scaffold toolkit. Operations are relative to a caller-
//! supplied `base` directory (the project root, or a tmp dir in tests).

const std = @import("std");

/// After the command file at `parts` is removed or moved away, delete any group
/// directories it leaves empty — walking up from its immediate parent and
/// stopping at the first non-empty directory. Never touches `src/commands`
/// itself, and never removes a group that still holds an `index.zig` (a
/// described/landing group) or other subcommands.
pub fn removeEmptyParents(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, parts: []const []const u8) !void {
    if (parts.len < 2) return; // a top-level command has no group parent

    var depth = parts.len - 1;
    while (depth >= 1) : (depth -= 1) {
        const dir = try groupPath(arena, parts[0..depth]);
        if (!isEmptyDir(base, io, dir)) break; // stop at the first non-empty parent
        base.deleteDir(io, dir) catch break;
    }
}

/// `src/commands/<seg>/<seg>...` for a group's path segments.
pub fn groupPath(arena: std.mem.Allocator, segments: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(arena, "src/commands");
    for (segments) |s| {
        try buf.append(arena, '/');
        try buf.appendSlice(arena, s);
    }
    return buf.items;
}

/// Rewrite only the scaffold-owned self-references to a command's own path:
/// example strings, the generated TODO print, and co-located test names.
/// Everything else, especially the body of `execute`, is user-owned business
/// logic and is preserved byte-for-byte. The TODO is deliberately recognized
/// only in its generated formatting; customized variants are preserved.
pub fn rewriteCommandPathReferences(arena: std.mem.Allocator, content: []const u8, old_path: []const u8, new_path: []const u8) ![]const u8 {
    if (old_path.len == 0 or std.mem.eql(u8, old_path, new_path)) return content;
    const source = try arena.dupeZ(u8, content);
    var ast = try std.zig.Ast.parse(arena, source, .zig);
    if (ast.errors.len != 0) return error.SourceDoesNotParse;

    const Span = struct { start: usize, end: usize };
    var spans = std.ArrayList(Span).empty;

    // Only string literal nodes in the top-level `meta.examples` field belong
    // to the scaffold. Identically named fields elsewhere are user code.
    if (findDeclInit(&ast, "meta")) |meta_init| {
        var meta_buf: [2]std.zig.Ast.Node.Index = undefined;
        if (ast.fullStructInit(&meta_buf, meta_init)) |meta| {
            for (meta.ast.fields) |field| {
                if (!std.mem.eql(u8, ast.tokenSlice(ast.firstToken(field) - 2), "examples")) continue;
                if (ast.nodeTag(field) != .address_of) continue;
                var examples_buf: [2]std.zig.Ast.Node.Index = undefined;
                const examples = ast.fullArrayInit(&examples_buf, ast.nodeData(field).node) orelse continue;
                for (examples.ast.elements) |example| {
                    if (ast.nodeTag(example) == .string_literal) try addLiteralPrefixSpan(&ast, &spans, arena, example, old_path);
                }
            }
        }
    }

    // Root test declarations own their names. The exact generated TODO literal
    // is also scaffold-owned; arbitrary strings in execute remain untouched.
    for (ast.rootDecls()) |decl| {
        if (ast.nodeTag(decl) == .test_decl) try addTokenPrefixSpan(&ast, &spans, arena, ast.firstToken(decl) + 1, old_path);
    }
    const todo_prefix = try std.fmt.allocPrint(arena, "\"TODO: Implement {s}\\n\"", .{old_path});
    const todo_statement = try std.fmt.allocPrint(arena, "try stdout.print(\"TODO: Implement {s}\\n\", .{{}});", .{old_path});
    for (ast.tokens.items(.tag), 0..) |tag, i| {
        if (tag != .string_literal) continue;
        const token: std.zig.Ast.TokenIndex = @intCast(i);
        if (std.mem.eql(u8, ast.tokenSlice(token), todo_prefix)) {
            const token_start = ast.tokens.items(.start)[token];
            const line_start = if (std.mem.lastIndexOfScalar(u8, content[0..token_start], '\n')) |newline| newline + 1 else 0;
            const line_end = std.mem.indexOfScalarPos(u8, content, token_start, '\n') orelse content.len;
            if (!std.mem.eql(u8, std.mem.trim(u8, content[line_start..line_end], " \t"), todo_statement)) continue;
            const start = token_start + "\"TODO: Implement ".len;
            try spans.append(arena, .{ .start = start, .end = start + old_path.len });
        }
    }

    std.mem.sort(Span, spans.items, {}, struct {
        fn lessThan(_: void, a: Span, b: Span) bool {
            return a.start < b.start;
        }
    }.lessThan);
    var out = std.ArrayList(u8).empty;
    var cursor: usize = 0;
    for (spans.items) |span| {
        if (span.start < cursor) continue;
        try out.appendSlice(arena, content[cursor..span.start]);
        try out.appendSlice(arena, new_path);
        cursor = span.end;
    }
    try out.appendSlice(arena, content[cursor..]);
    return out.items;
}

fn findDeclInit(ast: *std.zig.Ast, name: []const u8) ?std.zig.Ast.Node.Index {
    const main_tokens = ast.nodes.items(.main_token);
    for (ast.rootDecls()) |decl| {
        const vd = ast.fullVarDecl(decl) orelse continue;
        const init = vd.ast.init_node.unwrap() orelse continue;
        if (std.mem.eql(u8, ast.tokenSlice(main_tokens[@intFromEnum(decl)] + 1), name)) return init;
    }
    return null;
}

fn addLiteralPrefixSpan(ast: *std.zig.Ast, spans: anytype, arena: std.mem.Allocator, node: std.zig.Ast.Node.Index, old_path: []const u8) !void {
    try addTokenPrefixSpan(ast, spans, arena, ast.nodeMainToken(node), old_path);
}

fn addTokenPrefixSpan(ast: *std.zig.Ast, spans: anytype, arena: std.mem.Allocator, token: std.zig.Ast.TokenIndex, old_path: []const u8) !void {
    const raw = ast.tokenSlice(token);
    if (raw.len < 2 or raw[0] != '"' or !std.mem.startsWith(u8, raw[1..], old_path)) return;
    const after = 1 + old_path.len;
    if (after < raw.len and raw[after] != ' ' and raw[after] != '"' and raw[after] != ':' and raw[after] != '\\') return;
    const start = ast.tokens.items(.start)[token] + 1;
    try spans.append(arena, .{ .start = start, .end = start + old_path.len });
}

/// Atomically replace the existing file at `path` with `data`: write to a sibling
/// temporary file owned by this operation, then rename it over the target.
/// The target must already exist so its permissions can be carried forward.
pub fn writeFileAtomic(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    _ = arena;
    const permissions = (try base.statFile(io, path, .{})).permissions;
    var atomic = try base.createFileAtomic(io, path, .{ .permissions = permissions, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.setPermissions(io, permissions);
    try atomic.file.writeStreamingAll(io, data);
    try atomic.replace(io);
}

/// Atomically create `path`, refusing to replace a destination created by a
/// concurrent process after the caller's conflict check. An explicit mode is
/// carried forward exactly; null uses normal creation permissions and umask.
pub fn writeFileAtomicNew(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, path: []const u8, data: []const u8, permissions: ?std.Io.File.Permissions) !void {
    _ = arena;
    var atomic = try base.createFileAtomic(io, path, .{ .permissions = permissions orelse .default_file });
    defer atomic.deinit(io);
    if (permissions) |mode| try atomic.file.setPermissions(io, mode);
    try atomic.file.writeStreamingAll(io, data);
    try atomic.link(io);
}

fn isEmptyDir(base: std.Io.Dir, io: std.Io, path: []const u8) bool {
    var dir = base.openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    const first = it.next(io) catch return false;
    return first == null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "groupPath joins segments under src/commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("src/commands/gh/pr", try groupPath(arena.allocator(), &.{ "gh", "pr" }));
    try testing.expectEqualStrings("src/commands", try groupPath(arena.allocator(), &.{}));
}

test "removeEmptyParents cascades up but stops at a non-empty group" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Layout: src/commands/a/b/c.zig (just removed) with a sibling described
    // group src/commands/a/kept/ holding an index.zig.
    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.createDir(io, "src/commands", .default_dir);
    try tmp.dir.createDir(io, "src/commands/a", .default_dir);
    try tmp.dir.createDir(io, "src/commands/a/b", .default_dir); // now empty (c.zig gone)
    try tmp.dir.createDir(io, "src/commands/a/kept", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/a/kept/index.zig", .data = "pub const meta = .{};" });

    try removeEmptyParents(tmp.dir, io, a, &.{ "a", "b", "c" });

    // a/b was empty → removed. a still holds kept/ → preserved (cascade stops).
    try testing.expect(!dirExists(tmp.dir, io, "src/commands/a/b"));
    try testing.expect(dirExists(tmp.dir, io, "src/commands/a"));
    try testing.expect(dirExists(tmp.dir, io, "src/commands/a/kept"));
}

test "rewriteCommandPathReferences rewrites the scaffolded self-references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content =
        \\pub const meta = .{
        \\    .description = "Create a user",
        \\    .examples = &.{
        \\        "users create <email>",
        \\    },
        \\};
        \\
        \\pub fn execute(_: Args, _: Options, context: *Context) !void {
        \\    const stdout = context.stdout();
        \\    try stdout.print("TODO: Implement users create\n", .{});
        \\}
        \\
        \\test "users create" {
        \\    _ = @This();
        \\}
        \\
    ;

    const got = try rewriteCommandPathReferences(a, content, "users create", "admin register");

    try testing.expect(std.mem.indexOf(u8, got, "\"admin register <email>\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "TODO: Implement admin register\\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "test \"admin register\" {") != null);
    try testing.expect(std.mem.indexOf(u8, got, "users create") == null);
}

test "rewriteCommandPathReferences does not touch a longer identifier containing the old path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Comments are business logic/prose, even when they contain the old path.
    const content = "// recreate the users create index\n";
    const got = try rewriteCommandPathReferences(a, content, "create", "register");
    try testing.expectEqualStrings(content, got);
}

test "rewriteCommandPathReferences preserves business logic identifiers and strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const content =
        \\pub const meta = .{
        \\    .description = "deploy the service",
        \\    .examples = &.{"deploy --env prod"},
        \\};
        \\pub fn execute(_: Args, _: Options, context: *Context) !void {
        \\    const deploy = "deploy";
        \\    try context.stdout().print("deploy {s}\\n", .{deploy});
        \\}
        \\// deploy stays in hand-written prose
        \\test "deploy validates output" {}
        \\
    ;

    const got = try rewriteCommandPathReferences(arena.allocator(), content, "deploy", "release");
    try testing.expect(std.mem.indexOf(u8, got, ".description = \"deploy the service\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, ".examples = &.{\"release --env prod\"}") != null);
    try testing.expect(std.mem.indexOf(u8, got, "const deploy = \"deploy\";") != null);
    try testing.expect(std.mem.indexOf(u8, got, "print(\"deploy {s}\\\\n\", .{deploy})") != null);
    try testing.expect(std.mem.indexOf(u8, got, "// deploy stays") != null);
    try testing.expect(std.mem.indexOf(u8, got, "test \"release validates output\"") != null);
}

test "rewriteCommandPathReferences only edits AST-selected metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const content =
        \\// .examples = &.{"deploy from a comment"},
        \\pub const meta = .{
        \\    .examples = &.{
        \\        "deploy --label \"quoted\"",
        \\    },
        \\};
        \\pub fn execute(_: Args, _: Options, _: *Context) !void {
        \\    const custom = .{ .examples = &.{"deploy stays"} };
        \\    _ = custom;
        \\}
        \\
    ;
    const got = try rewriteCommandPathReferences(arena.allocator(), content, "deploy", "release");
    try testing.expect(std.mem.indexOf(u8, got, "// .examples = &.{\"deploy from a comment\"}") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"release --label \\\"quoted\\\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, ".examples = &.{\"deploy stays\"}") != null);
}

test "rewriteCommandPathReferences preserves custom TODO literals and longer command prefixes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const content =
        \\pub const meta = .{
        \\    .examples = &.{"deploy-other --force", "deploy --force"},
        \\};
        \\pub fn execute(_: Args, _: Options, _: *Context) !void {
        \\    const saved = "TODO: Implement deploy\n";
        \\    _ = saved;
        \\}
        \\
    ;
    const got = try rewriteCommandPathReferences(arena.allocator(), content, "deploy", "release");
    try testing.expect(std.mem.indexOf(u8, got, "\"deploy-other --force\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"release --force\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "const saved = \"TODO: Implement deploy\\n\";") != null);
}

test "rewriteCommandPathReferences is a no-op when the path is unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content = "test \"users create\" {}\n";
    const got = try rewriteCommandPathReferences(a, content, "users create", "users create");
    try testing.expectEqualStrings(content, got);
}

test "writeFileAtomic replaces contents and leaves no temp behind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "cmd.zig", .data = "original" });
    try writeFileAtomic(tmp.dir, io, a, "cmd.zig", "replaced contents");

    const got = try tmp.dir.readFileAlloc(io, "cmd.zig", a, .limited(1024));
    try testing.expectEqualStrings("replaced contents", got);
    try expectOnlyEntry(tmp.dir, io, "cmd.zig");
}

test "writeFileAtomic preserves a pre-existing conventional temp file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "cmd.zig", .data = "original" });
    try tmp.dir.writeFile(io, .{ .sub_path = "cmd.zig.tmp", .data = "user data" });
    try writeFileAtomic(tmp.dir, io, arena.allocator(), "cmd.zig", "replacement");

    const conventional = try tmp.dir.readFileAlloc(io, "cmd.zig.tmp", arena.allocator(), .limited(1024));
    try testing.expectEqualStrings("user data", conventional);
}

test "writeFileAtomic does not follow or remove a conventional temp symlink" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "cmd.zig", .data = "original" });
    try tmp.dir.writeFile(io, .{ .sub_path = "victim", .data = "user data" });
    try tmp.dir.symLink(io, "victim", "cmd.zig.tmp", .{});
    try writeFileAtomic(tmp.dir, io, arena.allocator(), "cmd.zig", "replacement");

    const victim = try tmp.dir.readFileAlloc(io, "victim", arena.allocator(), .limited(1024));
    try testing.expectEqualStrings("user data", victim);
    const link = try tmp.dir.statFile(io, "cmd.zig.tmp", .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.sym_link, link.kind);
}

test "writeFileAtomic preserves existing permissions" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "cmd.zig", .data = "original" });
    const restricted: std.Io.File.Permissions = @enumFromInt(0o600);
    try tmp.dir.setFilePermissions(io, "cmd.zig", restricted, .{});
    try writeFileAtomic(tmp.dir, io, arena.allocator(), "cmd.zig", "replacement");

    const stat = try tmp.dir.statFile(io, "cmd.zig", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "writeFileAtomicNew refuses an existing destination" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "cmd.zig", .data = "someone else's data" });
    try testing.expectError(error.PathAlreadyExists, writeFileAtomicNew(tmp.dir, io, arena.allocator(), "cmd.zig", "replacement", .default_file));
    const got = try tmp.dir.readFileAlloc(io, "cmd.zig", arena.allocator(), .limited(1024));
    try testing.expectEqualStrings("someone else's data", got);
}

test "writeFileAtomic cleans up the temp file when the rename fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Make the target an existing directory so the final `rename` of the temp
    // file over it fails — exercising the errdefer cleanup path.
    try tmp.dir.createDir(io, "target", .default_dir);

    if (writeFileAtomic(tmp.dir, io, a, "target", "data")) |_| {
        return error.TestExpectedRenameFailure;
    } else |_| {}

    try expectOnlyEntry(tmp.dir, io, "target");
}

fn expectOnlyEntry(base: std.Io.Dir, io: std.Io, expected: []const u8) !void {
    var iterable = try base.openDir(io, ".", .{ .iterate = true });
    defer iterable.close(io);
    var it = iterable.iterate();
    const entry = (try it.next(io)) orelse return error.TestExpectedEntry;
    try testing.expectEqualStrings(expected, entry.name);
    try testing.expect((try it.next(io)) == null);
}

fn dirExists(base: std.Io.Dir, io: std.Io, path: []const u8) bool {
    var d = base.openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}
