const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const themed = zcli.theme.styled;
const ThemeContext = zcli.theme.ThemeContext;

const scaffold = @import("scaffold");
const spec = scaffold.spec;

pub const meta = .{
    .description = "Add a command group (a directory of subcommands) to your project",
    .examples = &.{
        "add group users --description \"Manage users\"",
        "add group gh/pr -d \"Work with pull requests\"",
        "add group server --with-landing -d \"Run and manage the server\"",
    },
    .args = .{
        .path = "Group path (e.g. 'users' or 'gh/pr')",
    },
    .options = .{
        .description = .{ .description = "Description of the group (shown in help and tree)", .short = 'd' },
        .with_landing = .{ .description = "Also scaffold a runnable landing command (execute) for the group itself" },
    },
};

pub const Args = struct {
    path: []const u8,
};

pub const Options = struct {
    description: ?[]const u8 = null,
    with_landing: bool = false,
};

pub fn execute(args: Args, options: Options, context: *Context) !void {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = context.io;

    std.Io.Dir.cwd().access(io, "src/commands", .{}) catch {
        return context.fail("Error: Not in a zcli project directory\nRun this command from the root of your zcli project (where build.zig is)", .{});
    };

    const parts = spec.parsePath(arena, args.path) catch {
        return context.fail("Error: Invalid group path: '{s}'", .{args.path});
    };

    // A group is a directory of subcommands, described by its index.zig.
    const dir = try std.fmt.allocPrint(arena, "src/commands/{s}", .{try join(arena, parts, "/")});
    const index_path = try std.fmt.allocPrint(arena, "{s}/index.zig", .{dir});

    const cwd = std.Io.Dir.cwd();
    if (fileExists(io, index_path)) {
        return context.fail("Error: group already described: {s}", .{index_path});
    }

    // Create the group directory (and any missing parents).
    var acc = std.ArrayList(u8).empty;
    try acc.appendSlice(arena, "src/commands");
    for (parts) |segment| {
        try acc.append(arena, '/');
        try acc.appendSlice(arena, segment);
        cwd.createDir(io, acc.items, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const description = options.description orelse "TODO: Add description";
    const content = try generateIndex(arena, parts, description, options.with_landing);

    var file = try cwd.createFile(io, index_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);

    try finish(context.stdout(), &context.theme, parts, index_path, options.with_landing);
}

/// The `index.zig` source for a group. Meta-only by default (a pure group, no
/// execute); with `--with-landing` it also gets an empty `Options` and an
/// `execute` so the group runs on its own. A landing group must have no `Args`
/// fields (positionals would clash with subcommand names), so `Args` is empty.
fn generateIndex(arena: std.mem.Allocator, parts: []const []const u8, description: []const u8, with_landing: bool) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(arena);
    const w = &aw.writer;

    if (with_landing) {
        try w.writeAll(
            \\const std = @import("std");
            \\const zcli = @import("zcli");
            \\const Context = @import("command_registry").Context;
            \\
            \\
        );
    }

    try w.writeAll("pub const meta = .{\n    .description = \"");
    try spec.writeEscaped(w, description);
    try w.writeAll("\",\n};\n");

    if (with_landing) {
        try w.writeAll(
            \\
            \\// A command group with subcommands must have an empty Args struct;
            \\// positional arguments would be ambiguous with subcommand names.
            \\pub const Args = struct {};
            \\
            \\pub const Options = struct {};
            \\
            \\pub fn execute(_: Args, _: Options, context: *Context) !void {
            \\    const stdout = context.stdout();
            \\    try stdout.print("TODO: Implement
        );
        try w.writeByte(' ');
        try writePath(w, parts);
        try w.writeAll(" (run with a subcommand for more)\\n\", .{});\n}\n");
    }

    return aw.written();
}

fn finish(w: *std.Io.Writer, theme: *const ThemeContext, parts: []const []const u8, index_path: []const u8, with_landing: bool) !void {
    try w.writeAll("\n  ");
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\u{2714} Created group {s}", .{index_path}) catch "\u{2714} Created group";
    try themed(line).success().render(w, theme);

    try w.writeAll("\n\n  Next steps\n");
    try w.writeAll("    1. Add a subcommand: zcli add command ");
    try writePath(w, parts);
    try w.writeAll("/<name>\n");
    if (with_landing) {
        try w.writeAll("    2. Implement the landing execute() in ");
        try w.writeAll(index_path);
        try w.writeAll("\n");
    }
}

fn writePath(w: *std.Io.Writer, parts: []const []const u8) !void {
    for (parts, 0..) |p, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(p);
    }
}

fn join(arena: std.mem.Allocator, parts: []const []const u8, sep: []const u8) ![]const u8 {
    return std.mem.join(arena, sep, parts);
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "generateIndex: meta-only by default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try generateIndex(a, &.{"users"}, "Manage users", false);
    try testing.expect(std.mem.indexOf(u8, src, ".description = \"Manage users\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub fn execute") == null); // pure group
    try expectParses(a, src);
}

test "generateIndex: with-landing adds an empty-Args execute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try generateIndex(a, &.{ "gh", "pr" }, "Pull requests", true);
    try testing.expect(std.mem.indexOf(u8, src, "pub const Args = struct {};") != null); // no positionals
    try testing.expect(std.mem.indexOf(u8, src, "pub fn execute(_: Args, _: Options") != null);
    try testing.expect(std.mem.indexOf(u8, src, "TODO: Implement gh pr") != null);
    try expectParses(a, src);
}

test "generateIndex: description is escaped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try generateIndex(a, &.{"x"}, "has \"quotes\"", false);
    try testing.expect(std.mem.indexOf(u8, src, "\\\"quotes\\\"") != null);
    try expectParses(a, src);
}

fn expectParses(arena: std.mem.Allocator, source: []const u8) !void {
    const ast = try std.zig.Ast.parse(arena, try arena.dupeZ(u8, source), .zig);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
}
