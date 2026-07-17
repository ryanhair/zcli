const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const themed = zcli.theme.styled;
const ThemeContext = zcli.theme.ThemeContext;

const scaffold = @import("scaffold");
const spec = scaffold.spec;
const fs = scaffold.fs;

pub const meta = .{
    .description = "Remove a whole command file from your project",
    .examples = &.{
        "rm command deploy",
        "rm command users/create",
    },
    .args = .{
        .path = "Command path to remove (e.g. 'users/create')",
    },
};

pub const Args = struct {
    path: []const u8,
};

pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const outcome = try performRemove(std.Io.Dir.cwd(), context.io, arena, args.path);
    switch (outcome) {
        .ok => |file_path| try finish(context.stdout(), &context.theme, file_path),
        .not_a_project => return context.fail("Error: Not in a zcli project directory\nRun this command from the root of your zcli project (where build.zig is)", .{}),
        .invalid_path => return context.fail("Error: Invalid command path: '{s}'", .{args.path}),
        .is_group => return context.fail("Error: '{s}' is a command group; remove its subcommands first", .{args.path}),
        .not_found => |file_path| return context.fail("Error: Command not found: {s}", .{file_path}),
    }
}

/// Result of `performRemove`. A tagged union (rather than an error set)
/// because a couple of failure modes need to carry the resolved file path
/// back to the caller for the user-facing message.
const RemoveOutcome = union(enum) {
    ok: []const u8,
    not_a_project,
    invalid_path,
    is_group,
    not_found: []const u8,
};

/// The actual removal: validates the path, refuses to delete a whole command
/// group, deletes the file, and tidies up any group left empty behind it.
/// Takes `dir` explicitly (rather than hardcoding `std.Io.Dir.cwd()`) so it
/// can be exercised against a scratch directory in tests.
fn performRemove(dir: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, path: []const u8) !RemoveOutcome {
    dir.access(io, "src/commands", .{}) catch return .not_a_project;

    const parts = spec.parsePath(arena, path) catch return .invalid_path;

    const file_path = try spec.buildFilePath(arena, parts);
    if (!exists(dir, io, file_path)) {
        // A group directory is not removed here — that would delete its
        // subcommands (and any index.zig) wholesale. Ask for the leaf files.
        if (exists(dir, io, try fs.groupPath(arena, parts))) {
            return .is_group;
        }
        return .{ .not_found = file_path };
    }

    try dir.deleteFile(io, file_path);
    try fs.removeEmptyParents(dir, io, arena, parts);

    return .{ .ok = file_path };
}

fn finish(w: *std.Io.Writer, theme: *const ThemeContext, file_path: []const u8) !void {
    try w.writeAll("\n  ");
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\u{2714} Removed {s}", .{file_path}) catch "\u{2714} Removed command";
    try themed(line).success().render(w, theme);
    try w.writeAll("\n");
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

test "performRemove fails outside a zcli project" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const outcome = try performRemove(tmp.dir, io, arena.allocator(), "deploy");
    try testing.expectEqual(RemoveOutcome.not_a_project, outcome);
}

test "performRemove rejects an invalid path" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const outcome = try performRemove(tmp.dir, io, arena.allocator(), "not valid!");
    try testing.expectEqual(RemoveOutcome.invalid_path, outcome);
}

test "performRemove reports a missing command" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const outcome = try performRemove(tmp.dir, io, arena.allocator(), "deploy");
    try testing.expectEqualStrings("src/commands/deploy.zig", outcome.not_found);
}

test "performRemove refuses to remove a whole command group" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    try tmp.dir.createDir(io, "src/commands/users", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/users/create.zig", .data = "pub const meta = .{};\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const outcome = try performRemove(tmp.dir, io, arena.allocator(), "users");
    try testing.expectEqual(RemoveOutcome.is_group, outcome);
}

test "performRemove deletes the file and cascades removeEmptyParents" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    try tmp.dir.createDir(io, "src/commands/users", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/users/create.zig", .data = "pub const meta = .{};\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const outcome = try performRemove(tmp.dir, io, arena.allocator(), "users/create");

    try testing.expectEqualStrings("src/commands/users/create.zig", outcome.ok);
    try testing.expect(!exists(tmp.dir, io, "src/commands/users/create.zig"));
    try testing.expect(!exists(tmp.dir, io, "src/commands/users"));
    try testing.expect(exists(tmp.dir, io, "src/commands"));
}

test "performRemove leaves a non-empty group behind" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProject(tmp.dir, io);
    try tmp.dir.createDir(io, "src/commands/users", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/users/create.zig", .data = "pub const meta = .{};\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/commands/users/delete.zig", .data = "pub const meta = .{};\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try performRemove(tmp.dir, io, arena.allocator(), "users/create");

    try testing.expect(exists(tmp.dir, io, "src/commands/users"));
    try testing.expect(exists(tmp.dir, io, "src/commands/users/delete.zig"));
}
