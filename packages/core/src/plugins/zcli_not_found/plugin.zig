const std = @import("std");
const zcli = @import("zcli");
const levenshtein = zcli.levenshtein;

/// zcli-not-found Plugin
///
/// Answers `error.CommandNotFound` — the single origin for three distinct
/// situations the registry funnels through it (see registry/compiled.zig):
///
///   1. A genuinely unknown command (`command_path` is the mistyped argv).
///      Renders "Unknown command '<x>'" with Levenshtein "did you mean"
///      suggestions and the available-command list, then returns `false` so
///      the error propagates and the process exits non-zero. The registry
///      prints no bare fallback on this path — this block is the sole output.
///
///   2. A known command *group* accessed bare (`command_path` is a real
///      prefix of one or more commands, but names no executable leaf).
///      Renders the group's subcommands. This is NOT a typo, so no
///      suggestions — and it returns `true` (handled) so the registry does
///      not also print its own "'<x>' is a command group" line on top.
///
///   3. No command at all (`command_path` is empty). Renders the top-level
///      command list, returns `true` so the registry's bare "No command
///      specified" line is suppressed.
///
/// The plugin is self-contained: it handles all three sensibly on its own,
/// with or without zcli_help registered. When help IS registered it runs at
/// higher priority and answers cases 2 and 3 with richer, themed help,
/// suppressing the error before this plugin is consulted; this plugin then
/// only reaches case 1. When help is absent, this plugin covers all three.
pub fn onError(
    context: anytype,
    err: anyerror,
) !bool {
    if (err != error.CommandNotFound) return false;

    // Collect visible (non-hidden) command paths once — every branch needs them.
    const all_command_info = context.getAvailableCommandInfo();
    var visible_commands = std.ArrayList([]const []const u8).empty;
    defer visible_commands.deinit(context.allocator);
    for (all_command_info) |cmd_info| {
        if (!cmd_info.hidden) {
            try visible_commands.append(context.allocator, cmd_info.path);
        }
    }

    // Case 3: no command named at all.
    if (context.command_path.len == 0) {
        try generateNoCommandHelp(context, visible_commands.items);
        return true; // Handled — suppress the registry's bare fallback line.
    }

    // Case 2: the named path is a known command group (a strict prefix of at
    // least one command), not a typo. Show its subcommands.
    if (isCommandGroup(context.command_path, visible_commands.items)) {
        const group_name = try std.mem.join(context.allocator, " ", context.command_path);
        try generateCommandGroupHelp(context, group_name, visible_commands.items);
        return true; // Handled — suppress the registry's group line.
    }

    // Case 1: a genuinely unknown command.
    const attempted_command = try std.mem.join(context.allocator, " ", context.command_path);
    try generateCommandNotFoundHelp(context, attempted_command, visible_commands.items);

    // We've rendered the styled block (the single source of truth for
    // command-not-found). Let the error keep propagating so the entry point
    // exits non-zero — the registry prints no bare fallback on this path.
    return false;
}

/// True when `path` names a known command *group* — i.e. it is a strict prefix
/// of at least one available command, but not an executable command itself.
fn isCommandGroup(path: []const []const u8, available_commands: []const []const []const u8) bool {
    for (available_commands) |cmd_parts| {
        if (cmd_parts.len <= path.len) continue;
        var is_prefix = true;
        for (path, 0..) |part, i| {
            if (!std.mem.eql(u8, part, cmd_parts[i])) {
                is_prefix = false;
                break;
            }
        }
        if (is_prefix) return true;
    }
    return false;
}

/// Render help for a bare group access (case 2): its direct subcommands.
fn generateCommandGroupHelp(
    context: anytype,
    group_name: []const u8,
    available_commands: []const []const []const u8,
) !void {
    var writer = context.stderr();
    try writer.print("'{s}' is a command group.\n\n", .{group_name});
    try writer.print("Subcommands:\n", .{});

    const depth = std.mem.count(u8, group_name, " ") + 1;
    for (available_commands) |cmd_parts| {
        if (cmd_parts.len != depth + 1) continue;
        var matches = true;
        var i: usize = 0;
        var iter = std.mem.splitScalar(u8, group_name, ' ');
        while (iter.next()) |part| : (i += 1) {
            if (!std.mem.eql(u8, part, cmd_parts[i])) {
                matches = false;
                break;
            }
        }
        if (matches) try writer.print("    {s}\n", .{cmd_parts[depth]});
    }

    try writer.print("\nRun '{s} {s} <subcommand> --help' for more information.\n", .{ context.app_name, group_name });
}

/// Render help when no command was named at all (case 3): the command list.
fn generateNoCommandHelp(
    context: anytype,
    available_commands: []const []const []const u8,
) !void {
    var writer = context.stderr();
    try writer.print("No command specified.\n\n", .{});
    try printAvailableCommands(context, writer, available_commands);
}

/// Generate help text for a genuinely unknown command (case 1).
fn generateCommandNotFoundHelp(
    context: anytype,
    attempted_command: []const u8,
    available_commands: []const []const []const u8,
) !void {
    var writer = context.stderr();

    // Error header. `attempted_command` is the raw, mistyped argv joined back
    // together — sanitize it so a crafted argument carrying an ANSI/OSC
    // escape sequence (e.g. a title-bar set or clipboard write) can't reach
    // the terminal raw.
    try writer.print("Error: Unknown command '", .{});
    try zcli.writeSanitized(writer, attempted_command);
    try writer.print("'\n\n", .{});

    // Safety check for available_commands
    if (available_commands.len == 0) {
        try writer.print("No commands available for suggestions.\n", .{});
        try writer.print("\nRun '{s} --help' to see all available commands.\n", .{context.app_name});
        return;
    }

    // Convert hierarchical commands to flat strings for suggestion processing.
    // Both the suggestion list and the returned strings live in the arena-per-
    // command allocator, so nothing here needs an explicit free.
    var flat_commands = std.ArrayList([]const u8).empty;
    defer flat_commands.deinit(context.allocator);
    for (available_commands) |cmd_parts| {
        const joined_cmd = try std.mem.join(context.allocator, " ", cmd_parts);
        try flat_commands.append(context.allocator, joined_cmd);
    }

    // Find similar commands.
    const suggestions = try findBestSuggestions(
        attempted_command,
        flat_commands.items,
        context.allocator,
        3, // max suggestions
        3, // max edit distance
    );

    if (suggestions.len > 0) {
        if (suggestions.len == 1) {
            try writer.print("Did you mean '{s}'?\n\n", .{suggestions[0]});
        } else {
            try writer.print("Did you mean one of these?\n", .{});
            for (suggestions) |suggestion| {
                try writer.print("    {s}\n", .{suggestion});
            }
            try writer.print("\n", .{});
        }
    }

    try printAvailableCommands(context, writer, available_commands);
}

/// Print the "Available commands" section shared by cases 1 and 3.
fn printAvailableCommands(
    context: anytype,
    writer: *std.Io.Writer,
    available_commands: []const []const []const u8,
) !void {
    try writer.print("Available commands:\n", .{});
    for (available_commands) |cmd_parts| {
        const joined = try std.mem.join(context.allocator, " ", cmd_parts);
        try writer.print("    {s}\n", .{joined});
    }
    try writer.print("\nRun '{s} --help' to see all available commands.\n", .{context.app_name});
}

/// Find best command suggestions using Levenshtein distance. Returned strings
/// are duped into `allocator` (the arena-per-command allocator), so the caller
/// never holds a borrow into a shorter-lived buffer.
///
/// A candidate is suggested only when its edit distance is within
/// `max_distance` AND strictly less than the input length. That second guard
/// stops short inputs from matching everything at a fixed distance — e.g. `i`
/// against `init` and `run` is distance 3 to both, but suggesting either is
/// noise, so neither is offered.
fn findBestSuggestions(
    input: []const u8,
    commands: []const []const u8,
    allocator: std.mem.Allocator,
    max_suggestions: usize,
    max_distance: usize,
) ![][]const u8 {
    if (commands.len == 0 or input.len == 0) {
        return allocator.alloc([]const u8, 0);
    }

    const ScoredCommand = struct {
        command: []const u8,
        distance: usize,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.distance < b.distance;
        }
    };

    var scored = try allocator.alloc(ScoredCommand, commands.len);
    defer allocator.free(scored);

    var valid_count: usize = 0;
    for (commands) |cmd| {
        if (cmd.len == 0) continue;

        const distance = levenshtein.editDistance(input, cmd);
        if (distance <= max_distance and distance < input.len) {
            scored[valid_count] = .{ .command = cmd, .distance = distance };
            valid_count += 1;
        }
    }

    if (valid_count == 0) {
        return allocator.alloc([]const u8, 0);
    }

    std.sort.pdq(ScoredCommand, scored[0..valid_count], {}, ScoredCommand.lessThan);

    const result_count = @min(valid_count, max_suggestions);
    var result = try allocator.alloc([]const u8, result_count);
    for (0..result_count) |i| {
        // Dupe: the source strings live in a caller buffer (`flat_commands`)
        // that may outlive this call only by statement ordering. Copying into
        // the arena makes the returned slice self-owning.
        result[i] = try allocator.dupe(u8, scored[i].command);
    }

    return result;
}

// Tests
test "not-found plugin structure" {
    try std.testing.expect(@hasDecl(@This(), "onError"));
}

test "find best suggestions" {
    const allocator = std.testing.allocator;

    const commands = [_][]const u8{ "list", "search", "create", "delete", "status" };

    // Test with typo "serach" -> should suggest "search"
    const suggestions = try findBestSuggestions("serach", &commands, allocator, 3, 3);
    defer freeSuggestions(allocator, suggestions);

    try std.testing.expect(suggestions.len > 0);
    try std.testing.expectEqualStrings("search", suggestions[0]);
}

test "find best suggestions with empty input" {
    const allocator = std.testing.allocator;

    const commands = [_][]const u8{ "list", "search", "create" };

    const suggestions = try findBestSuggestions("", &commands, allocator, 3, 3);
    defer freeSuggestions(allocator, suggestions);

    try std.testing.expect(suggestions.len == 0);
}

test "find best suggestions with no commands" {
    const allocator = std.testing.allocator;

    const commands = [_][]const u8{};

    const suggestions = try findBestSuggestions("test", &commands, allocator, 3, 3);
    defer freeSuggestions(allocator, suggestions);

    try std.testing.expect(suggestions.len == 0);
}

test "find best suggestions guards short inputs against noise" {
    const allocator = std.testing.allocator;

    // `i` is edit-distance 3 from both "init" and "run", but the
    // `distance < input.len` guard rejects both — a single letter should not
    // suggest anything. Without the guard this returned two false positives.
    const commands = [_][]const u8{ "init", "run" };
    const suggestions = try findBestSuggestions("i", &commands, allocator, 3, 3);
    defer freeSuggestions(allocator, suggestions);

    try std.testing.expect(suggestions.len == 0);
}

test "isCommandGroup detects prefixes but not leaves or unknowns" {
    const commands = [_][]const []const u8{
        &.{ "remote", "add" },
        &.{ "remote", "remove" },
        &.{"status"},
    };

    // "remote" is a strict prefix of two commands -> a group.
    try std.testing.expect(isCommandGroup(&.{"remote"}, &commands));
    // "status" is an executable leaf, not a prefix of anything longer.
    try std.testing.expect(!isCommandGroup(&.{"status"}, &commands));
    // "bogus" matches nothing.
    try std.testing.expect(!isCommandGroup(&.{"bogus"}, &commands));
    // "remote add" is itself a leaf, not a group.
    try std.testing.expect(!isCommandGroup(&.{ "remote", "add" }, &commands));
}

/// Free a suggestion slice from `findBestSuggestions` when the caller owns the
/// allocator (tests use `std.testing.allocator`; the plugin uses the arena and
/// never frees). Each element is a dupe, so both levels are freed.
fn freeSuggestions(allocator: std.mem.Allocator, suggestions: [][]const u8) void {
    for (suggestions) |s| allocator.free(s);
    allocator.free(suggestions);
}

// ===========================================================================
// onError: the plugin's 3-case contract (see the module doc comment above)
// ===========================================================================

test "onError case 1: a close typo gets a 'did you mean' suggestion" {
    // `onError` allocates (joins, suggestion dupes) and, like the production
    // registry, relies on an arena being torn down wholesale rather than
    // freeing each piece — so context.allocator is arena-backed here too,
    // not the leak-checking testing.allocator directly.
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    stdio.stderr_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    ctx.command_path = &.{"serach"}; // typo of "search"
    ctx.plugin_command_info = &.{
        .{ .path = &.{"search"}, .description = "Search things" },
        .{ .path = &.{"status"}, .description = "Show status" },
    };

    const handled = try onError(&ctx, error.CommandNotFound);
    try ctx.stderr().flush();

    // Case 1 is never "handled" — the error must keep propagating so the
    // process exits non-zero (see the module doc comment).
    try std.testing.expect(!handled);

    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "Unknown command 'serach'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Did you mean 'search'?") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Available commands:") != null);
}

test "onError case 1: a distant input gets no suggestion, just the command list" {
    // `onError` allocates (joins, suggestion dupes) and, like the production
    // registry, relies on an arena being torn down wholesale rather than
    // freeing each piece — so context.allocator is arena-backed here too,
    // not the leak-checking testing.allocator directly.
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    stdio.stderr_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    ctx.command_path = &.{"xyzzyplugh"}; // unrelated to any known command
    ctx.plugin_command_info = &.{
        .{ .path = &.{"search"}, .description = "Search things" },
        .{ .path = &.{"status"}, .description = "Show status" },
    };

    const handled = try onError(&ctx, error.CommandNotFound);
    try ctx.stderr().flush();

    try std.testing.expect(!handled);

    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "Unknown command 'xyzzyplugh'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Did you mean") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Available commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "search") != null);
}

test "onError case 2: a bare known group renders its subcommands and is handled" {
    // `onError` allocates (joins, suggestion dupes) and, like the production
    // registry, relies on an arena being torn down wholesale rather than
    // freeing each piece — so context.allocator is arena-backed here too,
    // not the leak-checking testing.allocator directly.
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    stdio.stderr_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    // "remote" is a strict prefix of two commands — a group, not a typo.
    ctx.command_path = &.{"remote"};
    ctx.plugin_command_info = &.{
        .{ .path = &.{ "remote", "add" }, .description = "Add a remote" },
        .{ .path = &.{ "remote", "remove" }, .description = "Remove a remote" },
        .{ .path = &.{"status"}, .description = "Show status" },
    };

    const handled = try onError(&ctx, error.CommandNotFound);
    try ctx.stderr().flush();

    // Case 2 is handled — the registry must not also print its own group line.
    try std.testing.expect(handled);

    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "'remote' is a command group.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Subcommands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "add") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "remove") != null);
    // Not a typo, so no "did you mean" noise.
    try std.testing.expect(std.mem.indexOf(u8, out, "Did you mean") == null);
}

test "onError case 3: no command at all renders the top-level list and is handled" {
    // `onError` allocates (joins, suggestion dupes) and, like the production
    // registry, relies on an arena being torn down wholesale rather than
    // freeing each piece — so context.allocator is arena-backed here too,
    // not the leak-checking testing.allocator directly.
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    stdio.stderr_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    ctx.command_path = &.{}; // nothing named at all
    ctx.plugin_command_info = &.{
        .{ .path = &.{"search"}, .description = "Search things" },
        .{ .path = &.{"status"}, .description = "Show status" },
    };

    const handled = try onError(&ctx, error.CommandNotFound);
    try ctx.stderr().flush();

    // Case 3 is handled — the registry's bare "No command specified" line is
    // suppressed since this plugin already rendered the richer version.
    try std.testing.expect(handled);

    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "No command specified.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Available commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "search") != null);
}

test "onError ignores errors other than CommandNotFound" {
    // `onError` allocates (joins, suggestion dupes) and, like the production
    // registry, relies on an arena being torn down wholesale rather than
    // freeing each piece — so context.allocator is arena-backed here too,
    // not the leak-checking testing.allocator directly.
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    stdio.stderr_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    const handled = try onError(&ctx, error.OptionUnknown);
    try ctx.stderr().flush();

    try std.testing.expect(!handled);
    try std.testing.expectEqualStrings("", aw.written());
}

test "onError sanitizes a terminal-escape-laced attempted command" {
    // `onError` allocates (joins, suggestion dupes) and, like the production
    // registry, relies on an arena being torn down wholesale rather than
    // freeing each piece — so context.allocator is arena-backed here too,
    // not the leak-checking testing.allocator directly.
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Ctx = zcli.TestContext(&.{});
    var stdio: zcli.Stdio = undefined;
    stdio.init(std.testing.io);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    stdio.stderr_override = &aw.writer;

    const environ = std.process.Environ.Map.init(allocator);
    var ctx = Ctx.init(allocator, std.testing.io, &stdio, &environ);
    defer ctx.deinit();

    // A crafted argv carrying an OSC title-set sequence (ESC ] 0 ; ... BEL).
    ctx.command_path = &.{"\x1b]0;pwned\x07"};
    ctx.plugin_command_info = &.{
        .{ .path = &.{"search"}, .description = "Search things" },
    };

    _ = try onError(&ctx, error.CommandNotFound);
    try ctx.stderr().flush();

    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "]0;pwned") != null); // text survives, minus the escape
}
