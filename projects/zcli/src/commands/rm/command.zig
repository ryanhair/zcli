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

    const io = context.io;
    const cwd = std.Io.Dir.cwd();

    cwd.access(io, "src/commands", .{}) catch {
        return context.fail("Error: Not in a zcli project directory\nRun this command from the root of your zcli project (where build.zig is)", .{});
    };

    const parts = spec.parsePath(arena, args.path) catch {
        return context.fail("Error: Invalid command path: '{s}'", .{args.path});
    };

    const file_path = try spec.buildFilePath(arena, parts);
    if (!exists(io, file_path)) {
        // A group directory is not removed here — that would delete its
        // subcommands (and any index.zig) wholesale. Ask for the leaf files.
        if (exists(io, try fs.groupPath(arena, parts))) {
            return context.fail("Error: '{s}' is a command group; remove its subcommands first", .{args.path});
        }
        return context.fail("Error: Command not found: {s}", .{file_path});
    }

    try cwd.deleteFile(io, file_path);
    try fs.removeEmptyParents(cwd, io, arena, parts);

    try finish(context.stdout(), &context.theme, file_path);
}

fn finish(w: *std.Io.Writer, theme: *const ThemeContext, file_path: []const u8) !void {
    try w.writeAll("\n  ");
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\u{2714} Removed {s}", .{file_path}) catch "\u{2714} Removed command";
    try themed(line).success().render(w, theme);
    try w.writeAll("\n");
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
