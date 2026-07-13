//! Tests for the zcli_completions plugin.
//!
//! Three layers:
//!   1. unit tests on the shared command-tree builder (nesting, aliases, enums),
//!   2. escaper tests with adversarial input for each shell,
//!   3. generated-script structural assertions (that would catch the depth
//!      off-by-one and unescaped-quote bugs) plus real-shell validation:
//!      `bash -n`/`zsh -n`/`fish --no-execute` syntax checks and a FUNCTIONAL
//!      bash completion test that sources the script and asserts COMPREPLY at
//!      the root AND at depth 2.

const std = @import("std");
const zcli = @import("zcli");

const bash = @import("plugins/zcli_completions/bash.zig");
const zsh = @import("plugins/zcli_completions/zsh.zig");
const fish = @import("plugins/zcli_completions/fish.zig");
const tree = @import("plugins/zcli_completions/tree.zig");
const escape = @import("plugins/zcli_completions/escape.zig");

const app_name = "tasks";

const priorities = [_][]const u8{ "low", "medium", "high" };

const global_options = [_]zcli.OptionInfo{
    .{ .name = "verbose", .short = 'v', .description = "Verbose output" },
    .{ .name = "help", .short = 'h', .description = "Show help" },
};

const add_options = [_]zcli.OptionInfo{
    .{ .name = "priority", .short = 'p', .description = "Task priority", .takes_value = true, .enum_values = &priorities },
    .{ .name = "force", .short = 'f', .description = "Skip confirmation" },
};

/// A representative tree: root leaves (add/list/edit) with an alias and enum
/// option, plus a nested group (sprint create / sprint list). `edit`'s
/// description contains an apostrophe — the adversarial case for fish.
const commands = [_]zcli.CommandInfo{
    .{ .path = &.{"add"}, .description = "Add a task", .options = &add_options, .aliases = &.{"a"} },
    .{ .path = &.{"list"}, .description = "List tasks" },
    .{ .path = &.{"edit"}, .description = "Edit a task's title" },
    .{ .path = &.{ "sprint", "create" }, .description = "Create a sprint" },
    .{ .path = &.{ "sprint", "list" }, .description = "List sprints" },
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ============================================================================
// Layer 1: command-tree builder
// ============================================================================

test "tree.build - nests commands and keeps a synthetic root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tree.build(arena.allocator(), &commands);

    // Root is synthetic (empty name/path) with the top-level commands as children.
    try std.testing.expectEqualStrings("", root.name);
    try std.testing.expectEqual(@as(usize, 0), root.path.len);
    // add, edit, list, sprint (sorted).
    try std.testing.expectEqual(@as(usize, 4), root.children.len);

    // Children are sorted by name.
    try std.testing.expectEqualStrings("add", root.children[0].name);
    try std.testing.expectEqualStrings("edit", root.children[1].name);
    try std.testing.expectEqualStrings("list", root.children[2].name);
    try std.testing.expectEqualStrings("sprint", root.children[3].name);
}

test "tree.build - intermediate group node materialises with two children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tree.build(arena.allocator(), &commands);

    const sprint = root.children[3];
    try std.testing.expectEqualStrings("sprint", sprint.name);
    try std.testing.expect(!sprint.isLeaf());
    try std.testing.expectEqual(@as(usize, 2), sprint.children.len);
    // create, list (sorted).
    try std.testing.expectEqualStrings("create", sprint.children[0].name);
    try std.testing.expectEqualStrings("list", sprint.children[1].name);
    // The nested node carries its full path.
    try std.testing.expectEqual(@as(usize, 2), sprint.children[1].path.len);
    try std.testing.expectEqualStrings("sprint", sprint.children[1].path[0]);
    try std.testing.expectEqualStrings("list", sprint.children[1].path[1]);
}

test "tree.build - carries aliases and enum option values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tree.build(arena.allocator(), &commands);

    const add = root.children[0];
    try std.testing.expectEqual(@as(usize, 1), add.aliases.len);
    try std.testing.expectEqualStrings("a", add.aliases[0]);

    // priority option carries its enum values.
    var found = false;
    for (add.options) |opt| {
        if (std.mem.eql(u8, opt.name, "priority")) {
            try std.testing.expect(opt.enum_values != null);
            try std.testing.expectEqual(@as(usize, 3), opt.enum_values.?.len);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "tree.build - collapses registry alias entries into one node" {
    // The registry emits `list` (aliases ["ls"]) AND a separate `ls` entry that
    // also carries aliases ["ls"]. The tree must yield ONE `list` node offering
    // `ls` as an alias — not duplicate `ls` command nodes.
    const cmds = [_]zcli.CommandInfo{
        .{ .path = &.{"list"}, .description = "List tasks", .aliases = &.{"ls"} },
        .{ .path = &.{"ls"}, .description = "List tasks", .aliases = &.{"ls"} },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tree.build(arena.allocator(), &cmds);
    try std.testing.expectEqual(@as(usize, 1), root.children.len);
    try std.testing.expectEqualStrings("list", root.children[0].name);
    try std.testing.expectEqual(@as(usize, 1), root.children[0].aliases.len);
    try std.testing.expectEqualStrings("ls", root.children[0].aliases[0]);
}

test "tree.build - drops hidden commands entirely" {
    const cmds = [_]zcli.CommandInfo{
        .{ .path = &.{"visible"}, .description = "Shown" },
        .{ .path = &.{"secret"}, .description = "Hidden", .hidden = true },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tree.build(arena.allocator(), &cmds);
    try std.testing.expectEqual(@as(usize, 1), root.children.len);
    try std.testing.expectEqualStrings("visible", root.children[0].name);
}

// ============================================================================
// Layer 2: escapers (adversarial input)
// ============================================================================

const adversarial = "a'b\"c$d`e(f)g[h]i\\j k";

test "escape.bash - single quotes get the '\\'' dance, nothing else" {
    const out = try escape.bash(std.testing.allocator, adversarial);
    defer std.testing.allocator.free(out);
    // The apostrophe is broken out of the quote.
    try std.testing.expect(contains(out, "a'\\''b"));
    // Everything else passes through literally (safe inside single quotes).
    try std.testing.expect(contains(out, "\"c$d`e(f)g[h]i\\j k"));
}

test "escape.fish - backslash-escapes quotes and backslashes" {
    const out = try escape.fish(std.testing.allocator, adversarial);
    defer std.testing.allocator.free(out);
    try std.testing.expect(contains(out, "a\\'b")); // apostrophe -> \'
    try std.testing.expect(contains(out, "i\\\\j")); // backslash -> \\
    // No raw apostrophe remains that could terminate the surrounding '…'.
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] == '\'') try std.testing.expect(i > 0 and out[i - 1] == '\\');
    }
}

test "escape.zsh - escapes quotes, brackets, parens, colon, backslash" {
    const out = try escape.zsh(std.testing.allocator, adversarial);
    defer std.testing.allocator.free(out);
    try std.testing.expect(contains(out, "'\\''")); // apostrophe dance
    try std.testing.expect(contains(out, "\\(f\\)")); // parens
    try std.testing.expect(contains(out, "\\[h\\]")); // brackets
    // A colon (spec separator) is escaped.
    const colon_in = "a:b";
    const cout = try escape.zsh(std.testing.allocator, colon_in);
    defer std.testing.allocator.free(cout);
    try std.testing.expectEqualStrings("a\\:b", cout);
}

// ============================================================================
// Layer 3a: structural assertions
// ============================================================================

test "bash.generate - emits a root case and single-word case subjects" {
    const script = try bash.generate(std.testing.allocator, app_name, &commands, &global_options);
    defer std.testing.allocator.free(script);

    // Registered function.
    try std.testing.expect(contains(script, "_tasks_completions()"));
    try std.testing.expect(contains(script, "complete -F _tasks_completions tasks"));

    // The command dispatch keys on a single joined word, NOT a path_len number
    // and NOT a multi-element array expansion (both were the P0 bugs).
    try std.testing.expect(contains(script, "local key=\"${cmd_path[*]}\""));
    try std.testing.expect(contains(script, "case \"$key\" in"));
    try std.testing.expect(!contains(script, "case \"$path_len\""));
    try std.testing.expect(!contains(script, "${cmd_path[@]}"));

    // Root case: empty key offers the top-level commands.
    try std.testing.expect(contains(script, "\"\")\n"));
    // Nested case: single-word subject "sprint".
    try std.testing.expect(contains(script, "\"sprint\")"));

    // Aliases surface alongside command names.
    try std.testing.expect(contains(script, "add a "));

    // Enum values are completable via compgen -W.
    try std.testing.expect(contains(script, "low medium high"));

    // bash-completion fallback present.
    try std.testing.expect(contains(script, "declare -F _init_completion"));
}

test "zsh.generate - compdef header, describe, and enum action" {
    const script = try zsh.generate(std.testing.allocator, app_name, &commands, &global_options);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.startsWith(u8, script, "#compdef tasks"));
    try std.testing.expect(contains(script, "_tasks()"));
    try std.testing.expect(contains(script, "_describe 'command' commands"));
    // Nested dispatch on the second path element.
    try std.testing.expect(contains(script, "case $line[2] in"));
    // Enum option renders a value action group.
    try std.testing.expect(contains(script, ":priority:(low medium high)"));
    // Alias appears as an alternation in the case pattern.
    try std.testing.expect(contains(script, "add|a)"));
}

test "fish.generate - escapes apostrophes and uses positional conditions" {
    const script = try fish.generate(std.testing.allocator, app_name, &commands, &global_options);
    defer std.testing.allocator.free(script);

    // The positional matcher helper is emitted and used (NOT __fish_seen_subcommand_from).
    try std.testing.expect(contains(script, "function __fish_tasks_using_command"));
    try std.testing.expect(contains(script, "__fish_tasks_using_command sprint"));
    try std.testing.expect(!contains(script, "__fish_seen_subcommand_from"));

    // The apostrophe in "Edit a task's title" is escaped, not left raw.
    try std.testing.expect(contains(script, "Edit a task\\'s title"));
    try std.testing.expect(!contains(script, "Edit a task's title"));

    // Enum option: -x (exclusive) with the choices listed.
    try std.testing.expect(contains(script, "-x -a 'low medium high'"));
    // Alias offered alongside the command name in a single -a argument.
    try std.testing.expect(contains(script, "-a 'add a'"));
}

test "generators - empty command set still yields a valid skeleton" {
    const empty = [_]zcli.CommandInfo{};
    const script = try bash.generate(std.testing.allocator, app_name, &empty, &global_options);
    defer std.testing.allocator.free(script);
    try std.testing.expect(contains(script, "_tasks_completions()"));
    try std.testing.expect(contains(script, "--verbose"));
}

// ============================================================================
// Layer 3b: real-shell validation
// ============================================================================

const io = std.testing.io;

/// Find a shell by trying common absolute locations, returning the first that
/// exists or null. Avoids depending on env access from the test root module.
fn findShell(name: []const u8) ?[]const u8 {
    const candidates: []const []const u8 = switch (name[0]) {
        'b' => &.{ "/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash", "/opt/homebrew/bin/bash" },
        'z' => &.{ "/bin/zsh", "/usr/bin/zsh", "/usr/local/bin/zsh", "/opt/homebrew/bin/zsh" },
        else => &.{ "/usr/bin/fish", "/usr/local/bin/fish", "/opt/homebrew/bin/fish" },
    };
    for (candidates) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        return path;
    }
    return null;
}

/// Write `content` under the temp dir and return its absolute path (arena-owned).
fn writeTemp(arena: std.mem.Allocator, name: []const u8, content: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "/tmp/{s}", .{name});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
    return path;
}

/// Run argv, returning the exit code (or 255 if the process could not be run
/// or was terminated abnormally). stdout/stderr are discarded.
fn runExit(a: std.mem.Allocator, argv: []const []const u8) u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return 255;
    _ = a;
    const term = child.wait(io) catch return 255;
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}

test "shell syntax - bash -n / zsh -n / fish --no-execute accept generated scripts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bash_script = try bash.generate(a, app_name, &commands, &global_options);
    const zsh_script = try zsh.generate(a, app_name, &commands, &global_options);
    const fish_script = try fish.generate(a, app_name, &commands, &global_options);

    const bash_path = try writeTemp(a, "zcli_test_completion.bash", bash_script);
    const zsh_path = try writeTemp(a, "zcli_test_completion.zsh", zsh_script);
    const fish_path = try writeTemp(a, "zcli_test_completion.fish", fish_script);

    if (findShell("bash")) |sh| {
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "-n", bash_path }));
    } else std.log.warn("bash not found; skipping bash -n syntax check", .{});

    if (findShell("zsh")) |sh| {
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "-n", zsh_path }));
    } else std.log.warn("zsh not found; skipping zsh -n syntax check", .{});

    if (findShell("fish")) |sh| {
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "--no-execute", fish_path }));
    } else std.log.warn("fish not found; skipping fish --no-execute syntax check", .{});
}

test "functional bash - COMPREPLY at root and at depth 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = findShell("bash") orelse {
        std.log.warn("bash not found; skipping functional completion test", .{});
        return;
    };

    const script = try bash.generate(a, app_name, &commands, &global_options);
    const script_path = try writeTemp(a, "zcli_func_completion.bash", script);

    // A harness that sources the script WITHOUT the bash-completion package (so
    // the generated _init_completion fallback path is exercised), drives the
    // completion function at two cursor positions, and prints COMPREPLY.
    // ROOT:  `tasks <TAB>`         -> expect add/list/edit/sprint
    // DEPTH2:`tasks sprint <TAB>`  -> expect create/list (NOT the root commands)
    const harness = try std.fmt.allocPrint(a,
        \\source "{s}"
        \\
        \\run() {{
        \\    COMP_WORDS=("$@")
        \\    COMP_CWORD=$(( ${{#COMP_WORDS[@]}} - 1 ))
        \\    COMPREPLY=()
        \\    _tasks_completions
        \\    echo "${{COMPREPLY[@]}}"
        \\}}
        \\
        \\echo "ROOT:$(run tasks '')"
        \\echo "DEPTH2:$(run tasks sprint '')"
        \\
    , .{script_path});
    const harness_path = try writeTemp(a, "zcli_func_harness.bash", harness);

    const result = try std.process.run(a, io, .{
        .argv = &.{ sh, harness_path },
    });
    const out = result.stdout;

    var root_line: ?[]const u8 = null;
    var depth2_line: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ROOT:")) root_line = line["ROOT:".len..];
        if (std.mem.startsWith(u8, line, "DEPTH2:")) depth2_line = line["DEPTH2:".len..];
    }

    try std.testing.expect(root_line != null);
    try std.testing.expect(depth2_line != null);

    // Root completions include every top-level command.
    try std.testing.expect(contains(root_line.?, "add"));
    try std.testing.expect(contains(root_line.?, "list"));
    try std.testing.expect(contains(root_line.?, "edit"));
    try std.testing.expect(contains(root_line.?, "sprint"));

    // Depth-2 completions are the sprint subcommands — NOT the root commands.
    // This is the assertion that proves the P0 depth off-by-one is dead.
    try std.testing.expect(contains(depth2_line.?, "create"));
    try std.testing.expect(contains(depth2_line.?, "list"));
    try std.testing.expect(!contains(depth2_line.?, "add"));
}
