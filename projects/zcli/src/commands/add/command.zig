const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const zinput = zcli.zinput;

const wizard = @import("_wizard.zig");
const generate = @import("_generate.zig");
const scaffold = @import("scaffold");
const parsePath = scaffold.spec.parsePath;
const buildFilePath = scaffold.spec.buildFilePath;

pub const meta = .{
    .description = "Add a new command to your zcli project",
    .examples = &.{
        "add command",
        "add command deploy",
        "add command users/create --description \"Create a user\"",
    },
    .args = .{
        .path = "Command path (e.g., 'deploy' or 'users/create'). Omit to be prompted.",
    },
    .options = .{
        .description = .{ .description = "Description of the command", .short = 'd' },
    },
};

pub const Args = struct {
    path: ?[]const u8 = null,
};

pub const Options = struct {
    description: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn execute(args: Args, options: Options, context: *Context) !void {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = context.io;

    // Preflight: must be inside a zcli project.
    std.Io.Dir.cwd().access(io, "src/commands", .{}) catch {
        return context.fail("Error: Not in a zcli project directory\nRun this command from the root of your zcli project (where build.zig is)", .{});
    };

    // Interactive on a TTY, classic skeleton when piped. Args and options are
    // added afterward with `add arg`/`add option` (ADR-0005) or, interactively,
    // through the wizard's own prompts.
    if (!zinput.terminal.isStdinTty()) {
        return skeleton(arena, context, args, options);
    }

    return wizard.run(arena, context, &context.theme, args.path, options.description);
}

// ---------------------------------------------------------------------------
// Non-interactive skeleton (piped stdin; preserves the scriptable behavior)
// ---------------------------------------------------------------------------

fn skeleton(arena: std.mem.Allocator, context: *Context, args: Args, options: Options) !void {
    const io = context.io;

    const raw_path = args.path orelse {
        return context.fail("Error: A command path is required when input is not interactive\nUsage: zcli add command <path> [--description \"...\"]", .{});
    };

    const parts = parsePath(arena, raw_path) catch {
        return context.fail("Error: Invalid command path: '{s}'", .{raw_path});
    };

    const file_path = try buildFilePath(arena, parts);
    if (generate.fileExists(io, file_path)) {
        return context.fail("Error: Command already exists: {s}", .{file_path});
    }

    const description = options.description orelse "TODO: Add description";
    const content = try generate.generateSource(arena, parts, description, &.{}, &.{});
    const new_groups = try generate.writeCommandFile(arena, io, parts, file_path, content);
    try wizard.finish(context.stdout(), &context.theme, parts, file_path, new_groups);
}

// The wizard and its prompt/render helpers live in wizard.zig; source
// rendering and file placement in generate.zig.
test {
    _ = wizard;
    _ = generate;
}
