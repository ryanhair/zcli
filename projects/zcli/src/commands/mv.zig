const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const themed = zcli.theme.styled;
const ThemeContext = zcli.theme.ThemeContext;

const scaffold = @import("scaffold");
const spec = scaffold.spec;
const fs = scaffold.fs;

pub const meta = .{
    .description = "Move or rename a command file, tidying up empty groups",
    .examples = &.{
        "mv deploy release",
        "mv users/create users/register",
        "mv users/create admin/create",
    },
    .args = .{
        .from = "Existing command path",
        .to = "New command path",
    },
};

pub const Args = struct {
    from: []const u8,
    to: []const u8,
};

pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const outcome = try performMove(std.Io.Dir.cwd(), context.io, arena, args.from, args.to);
    switch (outcome) {
        .ok => |r| try finish(context.stdout(), &context.theme, r.from_file, r.to_file),
        .not_a_project => return context.fail("Error: Not in a zcli project directory\nRun this command from the root of your zcli project (where build.zig is)", .{}),
        .invalid_from_path => return context.fail("Error: Invalid command path: '{s}'", .{args.from}),
        .invalid_to_path => return context.fail("Error: Invalid command path: '{s}'", .{args.to}),
        .from_is_group => return context.fail("Error: '{s}' is a command group; move its subcommands individually", .{args.from}),
        .from_not_found => |file_path| return context.fail("Error: Command not found: {s}", .{file_path}),
        .to_exists => |file_path| return context.fail("Error: Destination already exists: {s}", .{file_path}),
        .to_is_group => return context.fail("Error: Destination is a command group: {s}", .{args.to}),
        .source_invalid => return context.fail("Error: Command source is not valid Zig; fix parse errors before moving it", .{}),
    }
}

/// Result of `performMove`. A tagged union (rather than an error set) because
/// several failure modes need to carry the resolved file path back to the
/// caller for the user-facing message.
const MoveOutcome = union(enum) {
    ok: struct { from_file: []const u8, to_file: []const u8 },
    not_a_project,
    invalid_from_path,
    invalid_to_path,
    from_is_group,
    from_not_found: []const u8,
    to_exists: []const u8,
    to_is_group,
    source_invalid,
};

/// The actual move: validates both paths, checks for destination conflicts,
/// reads and rewrites the source, then creates any destination parent groups
/// and writes the result atomically before deleting the source. Invalid source
/// therefore leaves no destination directories behind. Takes `dir` explicitly
/// (rather than hardcoding `std.Io.Dir.cwd()`) for scratch-directory tests.
fn performMove(dir: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, from: []const u8, to: []const u8) !MoveOutcome {
    dir.access(io, "src/commands", .{}) catch return .not_a_project;

    const from_parts = spec.parsePath(arena, from) catch return .invalid_from_path;
    const to_parts = spec.parsePath(arena, to) catch return .invalid_to_path;

    const from_file = try spec.buildFilePath(arena, from_parts);
    if (!exists(dir, io, from_file)) {
        if (exists(dir, io, try fs.groupPath(arena, from_parts))) {
            return .from_is_group;
        }
        return .{ .from_not_found = from_file };
    }

    const to_file = try spec.buildFilePath(arena, to_parts);
    if (exists(dir, io, to_file)) {
        return .{ .to_exists = to_file };
    }
    if (exists(dir, io, try fs.groupPath(arena, to_parts))) {
        return .to_is_group;
    }

    // Order the move so a mid-flight failure can never leave a partially
    // applied result (#672): read the source, rewrite its self-references in
    // memory, write the finished file atomically at the destination, and only
    // then delete the source. If the read or rewrite fails, the source is still
    // in place and the destination was never created; if the atomic write
    // fails, likewise. The old path stops existing only once the new one holds
    // correct content.
    //
    // The scaffolder embeds the old path in three self-referential spots (the
    // leading `meta.examples` entry, the `execute` TODO print, and the
    // co-located test name) — rewrite those so the moved file doesn't keep
    // pointing at its old address (#591).
    const old_path = try std.mem.join(arena, " ", from_parts);
    const new_path = try std.mem.join(arena, " ", to_parts);
    const source_permissions = (try dir.statFile(io, from_file, .{})).permissions;
    const content = try dir.readFileAlloc(io, from_file, arena, .limited(1024 * 1024));
    const rewritten = fs.rewriteCommandPathReferences(arena, content, old_path, new_path) catch |err| switch (err) {
        error.SourceDoesNotParse => return .source_invalid,
        else => return err,
    };

    // Validate and rewrite before creating destination groups, so malformed
    // source leaves no filesystem changes behind.
    if (to_parts.len > 1) {
        var dirbuf = std.ArrayList(u8).empty;
        try dirbuf.appendSlice(arena, "src/commands");
        for (to_parts[0 .. to_parts.len - 1]) |segment| {
            try dirbuf.append(arena, '/');
            try dirbuf.appendSlice(arena, segment);
            dir.createDir(io, dirbuf.items, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }
    fs.writeFileAtomicNew(dir, io, arena, to_file, rewritten, source_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => return .{ .to_exists = to_file },
        else => return err,
    };
    try dir.deleteFile(io, from_file);

    // Tidy up any group the source left empty (its co-located `execute` and
    // any in-file tests travelled with the file).
    try fs.removeEmptyParents(dir, io, arena, from_parts);

    return .{ .ok = .{ .from_file = from_file, .to_file = to_file } };
}

fn finish(w: *std.Io.Writer, theme: *const ThemeContext, from_file: []const u8, to_file: []const u8) !void {
    try w.writeAll("\n  ");
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\u{2714} Moved {s} \u{2192} {s}", .{ from_file, to_file }) catch "\u{2714} Moved command";
    try themed(line).success().render(w, theme);
    try w.writeAll("\n\n  Note: any other mentions of the old path in comments or hand-written description text were left as-is.\n");
}

fn exists(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeProject(dir: std.Io.Dir, io: std.Io) !void {
    try dir.createDir(io, "src", .default_dir);
    try dir.createDir(io, "src/commands", .default_dir);
}

test "performMove fails outside a zcli project" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const outcome = try performMove(tmp.dir, io, arena.allocator(), "deploy", "release");
    try testing.expectEqual(MoveOutcome.not_a_project, outcome);
}

test "performMove rejects invalid from/to paths" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(MoveOutcome.invalid_from_path, try performMove(tmp.dir, io, a, "not valid!", "release"));
    try testing.expectEqual(MoveOutcome.invalid_to_path, try performMove(tmp.dir, io, a, "deploy", "not valid!"));
}

test "performMove reports a missing source command" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const outcome = try performMove(tmp.dir, io, arena.allocator(), "deploy", "release");
    try testing.expectEqualStrings("src/commands/deploy.zig", outcome.from_not_found);
}

test "performMove refuses to move a command group" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    try tmp.dir.createDir(io, "src/commands/users", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/users/create.zig", .data = "pub const meta = .{};\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const outcome = try performMove(tmp.dir, io, arena.allocator(), "users", "admin");
    try testing.expectEqual(MoveOutcome.from_is_group, outcome);
}

test "performMove refuses an existing destination file or group" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/deploy.zig", .data = "pub const meta = .{};\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/release.zig", .data = "pub const meta = .{};\n" });
    try tmp.dir.createDir(io, "src/commands/admin", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/admin/create.zig", .data = "pub const meta = .{};\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const to_file = try performMove(tmp.dir, io, a, "deploy", "release");
    try testing.expectEqualStrings("src/commands/release.zig", to_file.to_exists);

    const to_group = try performMove(tmp.dir, io, a, "deploy", "admin");
    try testing.expectEqual(MoveOutcome.to_is_group, to_group);
}

test "performMove renames the file, creates parent groups, and rewrites self-references" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/deploy.zig", .data =
        \\pub const meta = .{
        \\    .examples = &.{"deploy --env prod"},
        \\};
        \\
        \\test "deploy: works" {}
        \\
    });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const outcome = try performMove(tmp.dir, io, arena.allocator(), "deploy", "release/deploy");

    try testing.expectEqualStrings("src/commands/deploy.zig", outcome.ok.from_file);
    try testing.expectEqualStrings("src/commands/release/deploy.zig", outcome.ok.to_file);
    try testing.expect(!exists(tmp.dir, io, "src/commands/deploy.zig"));
    try testing.expect(exists(tmp.dir, io, "src/commands/release/deploy.zig"));

    const moved = try tmp.dir.readFileAlloc(io, "src/commands/release/deploy.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(moved);
    try testing.expect(std.mem.indexOf(u8, moved, "release deploy --env prod") != null);
    try testing.expect(std.mem.indexOf(u8, moved, "\"release deploy: works\"") != null);
}

test "performMove preserves command business logic while updating scaffold references" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    const source =
        \\pub const meta = .{
        \\    .description = "deploy a release",
        \\    .examples = &.{"deploy --env prod"},
        \\};
        \\pub fn execute(_: Args, _: Options, context: *Context) !void {
        \\    const deploy = "deploy";
        \\    try context.stdout().print("deploy {s}\\n", .{deploy});
        \\}
        \\test "deploy works" {}
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/deploy.zig", .data = source });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try performMove(tmp.dir, io, arena.allocator(), "deploy", "release");
    const moved = try tmp.dir.readFileAlloc(io, "src/commands/release.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(moved);
    try testing.expect(std.mem.indexOf(u8, moved, ".description = \"deploy a release\"") != null);
    try testing.expect(std.mem.indexOf(u8, moved, ".examples = &.{\"release --env prod\"}") != null);
    try testing.expect(std.mem.indexOf(u8, moved, "const deploy = \"deploy\";") != null);
    try testing.expect(std.mem.indexOf(u8, moved, "test \"release works\"") != null);
}

test "performMove rejects invalid Zig without touching the source" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    const source = "pub const meta = .{ this is not Zig\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/deploy.zig", .data = source });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(MoveOutcome.source_invalid, try performMove(tmp.dir, io, arena.allocator(), "deploy", "newgroup/release"));
    const still = try tmp.dir.readFileAlloc(io, "src/commands/deploy.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(still);
    try testing.expectEqualStrings(source, still);
    try testing.expect(!exists(tmp.dir, io, "src/commands/newgroup"));
}

test "performMove leaves source exact when destination write fails" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    const source =
        \\pub const meta = .{ .examples = &.{"deploy"} };
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/deploy.zig", .data = source });
    // Parent creation treats an existing path as potentially a directory; the
    // atomic destination write then deterministically reports NotDir.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/blocked", .data = "regular file" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.NotDir, performMove(tmp.dir, io, arena.allocator(), "deploy", "blocked/release"));
    const still = try tmp.dir.readFileAlloc(io, "src/commands/deploy.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(still);
    try testing.expectEqualStrings(source, still);
    try testing.expect(!exists(tmp.dir, io, "src/commands/blocked/release.zig"));
}

test "performMove ignores a pre-existing predictable temp path" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    const source =
        \\pub const meta = .{
        \\    .examples = &.{"deploy --env prod"},
        \\};
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/deploy.zig", .data = source });

    // The former fixed temporary basename is unrelated user-owned state.
    // Atomic creation uses an owned random sibling and leaves this untouched.
    try tmp.dir.createDir(io, "src/commands/release.zig.tmp", .default_dir);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try performMove(tmp.dir, io, arena.allocator(), "deploy", "release");
    try testing.expect(!exists(tmp.dir, io, "src/commands/deploy.zig"));
    try testing.expect(exists(tmp.dir, io, "src/commands/release.zig"));
    try testing.expect(exists(tmp.dir, io, "src/commands/release.zig.tmp"));
}

test "performMove cascades removeEmptyParents when the source group is left empty" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    try tmp.dir.createDir(io, "src/commands/users", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/users/create.zig", .data = "pub const meta = .{};\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try performMove(tmp.dir, io, arena.allocator(), "users/create", "register");

    try testing.expect(!exists(tmp.dir, io, "src/commands/users"));
    try testing.expect(exists(tmp.dir, io, "src/commands/register.zig"));
}
