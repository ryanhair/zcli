const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const themed = zcli.theme.styled;
const ThemeContext = zcli.theme.ThemeContext;

const scaffold = @import("scaffold");
const spec = scaffold.spec;
const splice = scaffold.splice;

pub const meta = .{
    .description = "Remove one or more positional arguments from an existing command",
    .examples = &.{
        "rm arg users/create age",
        "rm arg deploy target env",
    },
    .args = .{
        .command = "Target command path (e.g. 'users/create')",
        .names = "One or more argument names to remove",
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

    std.Io.Dir.cwd().access(io, "src/commands", .{}) catch {
        return context.fail("Error: Not in a zcli project directory\nRun this command from the root of your zcli project (where build.zig is)", .{});
    };

    if (args.names.len == 0) {
        return context.fail("Error: name at least one argument to remove", .{});
    }

    const parts = spec.parsePath(arena, args.command) catch {
        return context.fail("Error: Invalid command path: '{s}'", .{args.command});
    };
    const file_path = try spec.buildFilePath(arena, parts);

    // Normalize names the same way the fields were stored (kebab → snake).
    const names = try arena.alloc([]const u8, args.names.len);
    for (args.names, 0..) |raw, i| {
        names[i] = spec.normalizeName(arena, raw) catch |err| {
            return context.fail("Error: Invalid argument name '{s}': {s}", .{ raw, @errorName(err) });
        };
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(io, file_path, arena, .limited(max_source_bytes)) catch {
        return context.fail("Error: Command not found: {s}", .{file_path});
    };
    var source = try arena.dupeZ(u8, raw);

    // Reject the whole batch if any name is absent — never partially edit.
    // (Removal only relaxes ordering constraints, so no re-validation is needed.)
    const missing = try splice.missingFields(arena, source, "Args", names);
    if (missing.len > 0) {
        var msg = std.Io.Writer.Allocating.init(arena);
        try msg.writer.print("Error: {s} has no argument named ", .{file_path});
        for (missing, 0..) |m, i| {
            if (i > 0) try msg.writer.print(", ", .{});
            try msg.writer.print("'{s}'", .{m});
        }
        return context.fail("{s}", .{msg.written()});
    }

    for (names) |name| {
        const updated = try splice.removeArg(arena, source, name);
        source = try arena.dupeZ(u8, updated);
    }

    try scaffold.fs.writeFileAtomic(std.Io.Dir.cwd(), io, arena, file_path, source);

    try finish(context.stdout(), &context.theme, file_path, names.len);
}

fn finish(w: *std.Io.Writer, theme: *const ThemeContext, file_path: []const u8, count: usize) !void {
    try w.writeAll("\n  ");
    var buf: [512]u8 = undefined;
    const plural: []const u8 = if (count == 1) "" else "s";
    const line = std.fmt.bufPrint(&buf, "\u{2714} Removed {d} argument{s} from {s}", .{ count, plural, file_path }) catch "\u{2714} Removed";
    try themed(line).success().render(w, theme);
    try w.writeAll("\n");
}
