const std = @import("std");
const zcli = @import("zcli");
const Context = @import("command_registry").Context;
const store = @import("store");
const prompts = zcli.prompts;
const themed = zcli.theme.styled;

pub const meta = .{
    .description = "Edit a task's title and description in your editor",
    .examples = &.{"edit 1"},
    .args = .{ .id = "Task ID" },
};

pub const Args = struct { id: u32 };
pub const Options = struct {};

pub fn execute(args: Args, _: Options, context: *Context) !void {
    const allocator = context.allocator;
    var parsed = try store.load(allocator, context.io);
    defer parsed.deinit();
    const data = parsed.value;

    for (data.tasks) |*task| {
        if (task.id != args.id) continue;

        const writer = context.stdout();
        const reader = context.stdin();

        // Git-commit-style buffer: first line is title, blank line, then description.
        // Lines starting with '#' are comments and get stripped.
        const initial = try std.fmt.allocPrint(allocator,
            \\{s}
            \\
            \\{s}
            \\
            \\# Edit task #{d}.
            \\# The first non-comment line is the title.
            \\# Lines after the first blank line are the description.
            \\# Lines starting with '#' are ignored.
            \\
        , .{ task.title, task.description, task.id });
        defer allocator.free(initial);

        const msg = try std.fmt.allocPrint(allocator, "Edit task #{d}:", .{task.id});
        defer allocator.free(msg);

        const content = try prompts.editor(writer, reader, allocator, .{
            .message = msg,
            .io = context.io,
            .default = initial,
            .extension = ".md",
        });
        defer allocator.free(content);

        const parsed_edit = parseEdit(content);
        if (parsed_edit.title.len == 0) {
            try context.stderr().writeAll("Error: Title cannot be empty\n");
            return;
        }

        // parsed_edit slices into `content`, which is freed by defer.
        // save() serializes synchronously before defers run, so this is safe.
        task.title = parsed_edit.title;
        task.description = parsed_edit.description;
        try store.save(allocator, context.io, data);
        try themed("✔").success().render(context.stdout(), &context.theme);
        try context.stdout().print(" Updated task #{d}\n", .{task.id});
        return;
    }

    try context.stderr().print("Error: Task #{d} not found\n", .{args.id});
}

const ParsedEdit = struct {
    title: []const u8,
    description: []const u8,
};

/// Parse git-commit-style content: first non-comment line is title,
/// remaining non-comment lines (after stripping leading blanks) are description.
fn parseEdit(content: []const u8) ParsedEdit {
    var title_start: usize = 0;
    var title_end: usize = 0;
    var desc_start: usize = content.len;

    // Skip comments/blanks; first non-comment line is title.
    var i: usize = 0;
    while (i < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const line = std.mem.trim(u8, content[i..line_end], " \t\r");
        if (line.len > 0 and line[0] != '#') {
            title_start = i;
            title_end = line_end;
            desc_start = if (line_end < content.len) line_end + 1 else content.len;
            break;
        }
        i = if (line_end < content.len) line_end + 1 else content.len;
    }

    const title = std.mem.trim(u8, content[title_start..title_end], " \t\r\n");

    // Description: strip comment lines, trim trailing whitespace
    // For simplicity, just take everything from desc_start to end, strip leading/trailing blank lines.
    var desc = content[desc_start..];

    // Remove trailing whitespace
    desc = std.mem.trimEnd(u8, desc, " \t\r\n");
    // Skip leading blank lines
    desc = std.mem.trimStart(u8, desc, " \t\r\n");

    // If description contains comment lines, we need to strip them.
    // Check if any line starts with '#'.
    var has_comment = false;
    var dit: usize = 0;
    while (dit < desc.len) {
        const le = std.mem.indexOfScalarPos(u8, desc, dit, '\n') orelse desc.len;
        const ln = std.mem.trimStart(u8, desc[dit..le], " \t");
        if (ln.len > 0 and ln[0] == '#') {
            has_comment = true;
            break;
        }
        dit = if (le < desc.len) le + 1 else desc.len;
    }

    if (has_comment) {
        // Return a description with comments stripped.
        // This requires allocation, but parseEdit returns slices.
        // Simpler: trim to the first comment line.
        var cut: usize = desc.len;
        var j: usize = 0;
        while (j < desc.len) {
            const le = std.mem.indexOfScalarPos(u8, desc, j, '\n') orelse desc.len;
            const ln = std.mem.trimStart(u8, desc[j..le], " \t");
            if (ln.len > 0 and ln[0] == '#') {
                cut = j;
                break;
            }
            j = if (le < desc.len) le + 1 else desc.len;
        }
        desc = std.mem.trimEnd(u8, desc[0..cut], " \t\r\n");
    }

    return .{ .title = title, .description = desc };
}

test "parseEdit: title and description" {
    const result = parseEdit(
        \\My title
        \\
        \\This is the description.
        \\With multiple lines.
        \\
    );
    try std.testing.expectEqualStrings("My title", result.title);
    try std.testing.expectEqualStrings("This is the description.\nWith multiple lines.", result.description);
}

test "parseEdit: skips leading comments" {
    const result = parseEdit(
        \\# A comment
        \\Actual title
        \\
        \\Body text
    );
    try std.testing.expectEqualStrings("Actual title", result.title);
    try std.testing.expectEqualStrings("Body text", result.description);
}

test "parseEdit: strips trailing comments from description" {
    const result = parseEdit(
        \\Title here
        \\
        \\Real description
        \\# Edit task #1.
        \\# More instructions
    );
    try std.testing.expectEqualStrings("Title here", result.title);
    try std.testing.expectEqualStrings("Real description", result.description);
}

test "parseEdit: empty description" {
    const result = parseEdit(
        \\Just a title
        \\
        \\# Only comments below
    );
    try std.testing.expectEqualStrings("Just a title", result.title);
    try std.testing.expectEqualStrings("", result.description);
}

test "parseEdit: empty title" {
    const result = parseEdit(
        \\# only comments
    );
    try std.testing.expectEqualStrings("", result.title);
}
