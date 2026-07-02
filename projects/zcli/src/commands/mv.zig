const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const ztheme = zcli.ztheme;

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

    const io = context.io.io;
    const stderr = context.stderr();
    const cwd = std.Io.Dir.cwd();

    cwd.access(io, "src/commands", .{}) catch {
        try stderr.print("Error: Not in a zcli project directory\n", .{});
        try stderr.print("Run this command from the root of your zcli project (where build.zig is)\n", .{});
        return error.NotInZcliProject;
    };

    const from_parts = spec.parsePath(arena, args.from) catch {
        try stderr.print("Error: Invalid command path: '{s}'\n", .{args.from});
        return error.InvalidCommandPath;
    };
    const to_parts = spec.parsePath(arena, args.to) catch {
        try stderr.print("Error: Invalid command path: '{s}'\n", .{args.to});
        return error.InvalidCommandPath;
    };

    const from_file = try spec.buildFilePath(arena, from_parts);
    if (!exists(io, from_file)) {
        if (exists(io, try fs.groupPath(arena, from_parts))) {
            try stderr.print("Error: '{s}' is a command group; move its subcommands individually\n", .{args.from});
            return error.IsAGroup;
        }
        try stderr.print("Error: Command not found: {s}\n", .{from_file});
        return error.CommandNotFound;
    }

    const to_file = try spec.buildFilePath(arena, to_parts);
    if (exists(io, to_file)) {
        try stderr.print("Error: Destination already exists: {s}\n", .{to_file});
        return error.CommandAlreadyExists;
    }
    if (exists(io, try fs.groupPath(arena, to_parts))) {
        try stderr.print("Error: Destination is a command group: {s}\n", .{args.to});
        return error.CommandAlreadyExists;
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

fn finish(w: *std.Io.Writer, theme: *const ztheme.Theme, from_file: []const u8, to_file: []const u8) !void {
    try w.writeAll("\n  ");
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\u{2714} Moved {s} \u{2192} {s}", .{ from_file, to_file }) catch "\u{2714} Moved command";
    try ztheme.theme(line).success().render(w, theme);
    try w.writeAll("\n\n  Note: update the command's `meta.examples` if they name the old path.\n");
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
