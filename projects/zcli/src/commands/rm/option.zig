const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const ztheme = zcli.ztheme;

const scaffold = @import("scaffold");
const spec = scaffold.spec;
const splice = scaffold.splice;

pub const meta = .{
    .description = "Remove one or more options from an existing command",
    .examples = &.{
        "rm option users/create verbose",
        "rm option deploy region retries",
    },
    .args = .{
        .command = "Target command path (e.g. 'users/create')",
        .names = "One or more option names to remove",
    },
};

pub const Args = struct {
    command: []const u8,
    names: [][]const u8,
};

pub const Options = struct {};

/// Maximum bytes read from a command source file before splicing.
const max_source_bytes = 1024 * 1024;

pub fn execute(args: Args, _: Options, context: *Context) !void {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = context.io;
    const stderr = context.stderr();

    std.Io.Dir.cwd().access(io, "src/commands", .{}) catch {
        try stderr.print("Error: Not in a zcli project directory\n", .{});
        try stderr.print("Run this command from the root of your zcli project (where build.zig is)\n", .{});
        return error.NotInZcliProject;
    };

    if (args.names.len == 0) {
        try stderr.print("Error: name at least one option to remove\n", .{});
        return error.MissingName;
    }

    const parts = spec.parsePath(arena, args.command) catch {
        try stderr.print("Error: Invalid command path: '{s}'\n", .{args.command});
        return error.InvalidCommandPath;
    };
    const file_path = try spec.buildFilePath(arena, parts);

    // Normalize names the same way the fields were stored (kebab → snake).
    const names = try arena.alloc([]const u8, args.names.len);
    for (args.names, 0..) |raw, i| {
        names[i] = spec.normalizeName(arena, raw) catch |err| {
            try stderr.print("Error: Invalid option name '{s}': {s}\n", .{ raw, @errorName(err) });
            return err;
        };
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(io, file_path, arena, .limited(max_source_bytes)) catch {
        try stderr.print("Error: Command not found: {s}\n", .{file_path});
        return error.CommandNotFound;
    };
    var source = try arena.dupeZ(u8, raw);

    // Reject the whole batch if any name is absent — never partially edit.
    const missing = try splice.missingFields(arena, source, "Options", names);
    if (missing.len > 0) {
        try stderr.print("Error: {s} has no option named ", .{file_path});
        for (missing, 0..) |m, i| {
            if (i > 0) try stderr.print(", ", .{});
            try stderr.print("'{s}'", .{m});
        }
        try stderr.print("\n", .{});
        return error.FieldNotFound;
    }

    for (names) |name| {
        const updated = try splice.removeOption(arena, source, name);
        source = try arena.dupeZ(u8, updated);
    }

    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, source);

    try finish(context.stdout(), &context.theme, file_path, names.len);
}

fn finish(w: *std.Io.Writer, theme: *const ztheme.Theme, file_path: []const u8, count: usize) !void {
    try w.writeAll("\n  ");
    var buf: [512]u8 = undefined;
    const plural: []const u8 = if (count == 1) "" else "s";
    const line = std.fmt.bufPrint(&buf, "\u{2714} Removed {d} option{s} from {s}", .{ count, plural, file_path }) catch "\u{2714} Removed";
    try ztheme.theme(line).success().render(w, theme);
    try w.writeAll("\n");
}
