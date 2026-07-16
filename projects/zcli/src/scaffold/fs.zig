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

/// Atomically replace the file at `path` with `data`: write to a sibling
/// `<path>.tmp`, then `rename` it over the target. A write failure or crash
/// mid-stream leaves the original file untouched (only the throwaway temp is
/// affected) instead of a truncated/corrupt command source.
pub fn writeFileAtomic(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    {
        var file = try base.createFile(io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, data);
    }
    try base.rename(tmp_path, base, path, io);
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
    // The temp is renamed away, not left as debris next to the target.
    try testing.expect(!fileExists(tmp.dir, io, "cmd.zig.tmp"));
}

fn fileExists(base: std.Io.Dir, io: std.Io, path: []const u8) bool {
    base.access(io, path, .{}) catch return false;
    return true;
}

fn dirExists(base: std.Io.Dir, io: std.Io, path: []const u8) bool {
    var d = base.openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}
