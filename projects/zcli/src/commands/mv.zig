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

    const io = context.io;
    const cwd = std.Io.Dir.cwd();

    cwd.access(io, "src/commands", .{}) catch {
        return context.fail("Error: Not in a zcli project directory\nRun this command from the root of your zcli project (where build.zig is)", .{});
    };

    const from_parts = spec.parsePath(arena, args.from) catch {
        return context.fail("Error: Invalid command path: '{s}'", .{args.from});
    };
    const to_parts = spec.parsePath(arena, args.to) catch {
        return context.fail("Error: Invalid command path: '{s}'", .{args.to});
    };

    const from_file = try spec.buildFilePath(arena, from_parts);
    if (!exists(io, from_file)) {
        if (exists(io, try fs.groupPath(arena, from_parts))) {
            return context.fail("Error: '{s}' is a command group; move its subcommands individually", .{args.from});
        }
        return context.fail("Error: Command not found: {s}", .{from_file});
    }

    const to_file = try spec.buildFilePath(arena, to_parts);
    if (exists(io, to_file)) {
        return context.fail("Error: Destination already exists: {s}", .{to_file});
    }
    if (exists(io, try fs.groupPath(arena, to_parts))) {
        return context.fail("Error: Destination is a command group: {s}", .{args.to});
    }

    // Create any parent group directories the destination needs.
    if (to_parts.len > 1) {
        var dir = std.ArrayList(u8).empty;
        try dir.appendSlice(arena, "src/commands");
        for (to_parts[0 .. to_parts.len - 1]) |segment| {
            try dir.append(arena, '/');
            try dir.appendSlice(arena, segment);
            cwd.createDir(io, dir.items, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    try cwd.rename(from_file, cwd, to_file, io);
    // Tidy up any group the source left empty (its co-located `execute` and
    // any in-file tests travel with the file).
    try fs.removeEmptyParents(cwd, io, arena, from_parts);

    try finish(context.stdout(), &context.theme, from_file, to_file);
}

fn finish(w: *std.Io.Writer, theme: *const ThemeContext, from_file: []const u8, to_file: []const u8) !void {
    try w.writeAll("\n  ");
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\u{2714} Moved {s} \u{2192} {s}", .{ from_file, to_file }) catch "\u{2714} Moved command";
    try themed(line).success().render(w, theme);
    try w.writeAll("\n\n  Note: update the command's `meta.examples` if they name the old path.\n");
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
