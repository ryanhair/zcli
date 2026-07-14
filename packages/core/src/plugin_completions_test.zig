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
const builtin = @import("builtin");
const zcli = @import("zcli");

const bash = @import("plugins/zcli_completions/bash.zig");
const zsh = @import("plugins/zcli_completions/zsh.zig");
const fish = @import("plugins/zcli_completions/fish.zig");
const powershell = @import("plugins/zcli_completions/powershell.zig");
const tree = @import("plugins/zcli_completions/tree.zig");
const escape = @import("plugins/zcli_completions/escape.zig");
const resolve = @import("plugins/zcli_completions/resolve.zig");
const wire = @import("plugins/zcli_completions/wire.zig");

// Pull the wire module's own tests (NUL framing / scrubbing) into this binary.
test {
    _ = wire;
}

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

const statuses = [_][]const u8{ "open", "done" };

// `edit` takes a plain (non-enum) id → completions show a hint, not files.
const edit_args = [_]zcli.ArgInfo{
    .{ .name = "id", .description = "Task ID" },
};
// `list` takes an enum status → completions offer the choices as values.
const list_args = [_]zcli.ArgInfo{
    .{ .name = "status", .description = "Filter by status", .enum_values = &statuses },
};

/// A representative tree: root leaves (add/list/edit) with an alias and enum
/// option, plus a nested group (sprint create / sprint list). `edit`'s
/// description contains an apostrophe — the adversarial case for fish. `edit`
/// and `list` declare positional args (a plain id and an enum status) to
/// exercise positional-argument completion.
const commands = [_]zcli.CommandInfo{
    .{ .path = &.{"add"}, .description = "Add a task", .options = &add_options, .aliases = &.{"a"} },
    .{ .path = &.{"list"}, .description = "List tasks", .args = &list_args },
    .{ .path = &.{"edit"}, .description = "Edit a task's title", .args = &edit_args },
    .{ .path = &.{ "sprint", "create" }, .description = "Create a sprint" },
    .{ .path = &.{ "sprint", "list" }, .description = "List sprints" },
};

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ============================================================================
// Layer 0: cursor resolution (dynamic completion, ADR-0026)
// ============================================================================

fn dummyHook(_: *zcli.completion.Request) anyerror!zcli.completion.Result {
    return .{};
}

const hook_spec: zcli.completion.Spec = .{ .hook = dummyHook };

// A command set exercising the resolver: `edit <id>` (one dynamic arg),
// `move <id> <sprint>` (two), `deploy --host <v> <target>` (a value-taking
// option before a dynamic positional), `calc <a> <b>`, `sprint create <name>`
// (nested), and `list <status>` with NO completion (a plain arg).
const rc_edit_args = [_]zcli.ArgInfo{.{ .name = "id", .complete = hook_spec }};
const rc_move_args = [_]zcli.ArgInfo{
    .{ .name = "id", .complete = hook_spec },
    .{ .name = "sprint", .complete = hook_spec },
};
const rc_deploy_opts = [_]zcli.OptionInfo{.{ .name = "host", .short = 'H', .takes_value = true, .complete = hook_spec }};
const rc_deploy_args = [_]zcli.ArgInfo{.{ .name = "target", .complete = hook_spec }};
const rc_calc_args = [_]zcli.ArgInfo{
    .{ .name = "a", .complete = hook_spec },
    .{ .name = "b", .complete = hook_spec },
};
const rc_sprint_create_args = [_]zcli.ArgInfo{.{ .name = "name", .complete = hook_spec }};
const rc_list_args = [_]zcli.ArgInfo{.{ .name = "status" }}; // no .complete

const resolve_commands = [_]zcli.CommandInfo{
    .{ .path = &.{"edit"}, .args = &rc_edit_args },
    .{ .path = &.{"move"}, .args = &rc_move_args },
    .{ .path = &.{"deploy"}, .options = &rc_deploy_opts, .args = &rc_deploy_args },
    .{ .path = &.{"calc"}, .args = &rc_calc_args },
    .{ .path = &.{ "sprint", "create" }, .args = &rc_sprint_create_args },
    .{ .path = &.{"list"}, .args = &rc_list_args },
};

const rc_globals = [_]zcli.OptionInfo{
    .{ .name = "verbose", .short = 'v' }, // boolean
    .{ .name = "config", .short = 'c', .takes_value = true }, // value, no completion
    .{ .name = "profile", .takes_value = true, .complete = hook_spec }, // value + hook
};

fn expectResolve(words: []const []const u8, cword: usize) !resolve.Match {
    const m = try resolve.resolve(std.testing.allocator, &resolve_commands, &rc_globals, words, cword);
    return m orelse error.NoMatch;
}

fn expectNoResolve(words: []const []const u8, cword: usize) !void {
    const m = try resolve.resolve(std.testing.allocator, &resolve_commands, &rc_globals, words, cword);
    if (m) |mm| {
        std.testing.allocator.free(mm.positionals);
        return error.UnexpectedMatch;
    }
}

test "resolve - first positional of a leaf command" {
    const m = try expectResolve(&.{ "tasks", "edit", "" }, 2);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expect(m.spec == .hook);
    try std.testing.expectEqual(@as(usize, 0), m.positionals.len);
    try std.testing.expectEqualStrings("", m.partial);
}

test "resolve - carries the partial prefix" {
    const m = try expectResolve(&.{ "tasks", "edit", "ta" }, 2);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expectEqualStrings("ta", m.partial);
}

test "resolve - second positional resolves the second arg" {
    const m = try expectResolve(&.{ "tasks", "move", "3", "" }, 3);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expectEqual(@as(usize, 1), m.positionals.len);
    try std.testing.expectEqualStrings("3", m.positionals[0]);
}

test "resolve - past the last non-variadic arg yields nothing" {
    // edit has one arg; the second positional slot has no field.
    try expectNoResolve(&.{ "tasks", "edit", "5", "" }, 3);
}

test "resolve - a boolean option before the cursor does not shift the slot" {
    const m = try expectResolve(&.{ "tasks", "edit", "--verbose", "" }, 3);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expectEqual(@as(usize, 0), m.positionals.len);
}

test "resolve - a value-taking option consumes its value (arity-aware)" {
    // `--host x` must not count `x` as a positional; target stays slot 0.
    const m = try expectResolve(&.{ "tasks", "deploy", "--host", "x", "" }, 4);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expectEqual(@as(usize, 0), m.positionals.len);
    try std.testing.expect(m.spec == .hook);
}

test "resolve - short value-taking option consumes its value" {
    const m = try expectResolve(&.{ "tasks", "deploy", "-H", "x", "" }, 4);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expectEqual(@as(usize, 0), m.positionals.len);
}

test "resolve - --flag=value is self-contained" {
    const m = try expectResolve(&.{ "tasks", "deploy", "--host=x", "" }, 3);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expectEqual(@as(usize, 0), m.positionals.len);
}

test "resolve - a global value-taking option before the command is skipped" {
    const m = try expectResolve(&.{ "tasks", "--config", "f.toml", "edit", "" }, 4);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expectEqual(@as(usize, 0), m.positionals.len);
    try std.testing.expect(m.spec == .hook);
}

test "resolve - a negative number is a positional, not an option" {
    const m = try expectResolve(&.{ "tasks", "calc", "-5", "" }, 3);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expectEqual(@as(usize, 1), m.positionals.len);
    try std.testing.expectEqualStrings("-5", m.positionals[0]);
}

test "resolve - -- ends option parsing" {
    const m = try expectResolve(&.{ "tasks", "edit", "--", "" }, 3);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expectEqual(@as(usize, 0), m.positionals.len);
}

test "resolve - nested group command" {
    const m = try expectResolve(&.{ "tasks", "sprint", "create", "" }, 3);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expect(m.spec == .hook);
    try std.testing.expectEqual(@as(usize, 0), m.positionals.len);
}

test "resolve - a positional field with no .complete yields nothing" {
    try expectNoResolve(&.{ "tasks", "list", "" }, 2);
}

test "resolve - cursor on the command name is not dynamic" {
    try expectNoResolve(&.{ "tasks", "ed" }, 1);
}

test "resolve - option value, separated long form (--host <TAB>)" {
    const m = try expectResolve(&.{ "tasks", "deploy", "--host", "" }, 3);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expect(m.spec == .hook);
    try std.testing.expectEqualStrings("", m.partial);
}

test "resolve - option value, short form (-H <TAB>)" {
    const m = try expectResolve(&.{ "tasks", "deploy", "-H", "" }, 3);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expect(m.spec == .hook);
}

test "resolve - option value, joined form (--host=ab)" {
    const m = try expectResolve(&.{ "tasks", "deploy", "--host=ab" }, 2);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expect(m.spec == .hook);
    try std.testing.expectEqualStrings("ab", m.partial); // partial is the value part
}

test "resolve - global option value with a hook" {
    const m = try expectResolve(&.{ "tasks", "--profile", "" }, 2);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expect(m.spec == .hook);
}

test "resolve - value-taking option without a hook yields nothing" {
    try expectNoResolve(&.{ "tasks", "--config", "" }, 2);
}

test "resolve - a completed option value does not shift the positional slot" {
    // `--host x` (x not the cursor) is consumed; target stays the positional hook.
    const m = try expectResolve(&.{ "tasks", "deploy", "--host", "x", "" }, 4);
    defer std.testing.allocator.free(m.positionals);
    try std.testing.expectEqual(@as(usize, 0), m.positionals.len);
}

// ============================================================================
// Layer 0b: option-value + `.file`/`.dir` generation (ADR-0026 increment 2)
// ============================================================================

// `deploy` with a dynamic-hook option (`--host`), a `.file` option (`--out`), and
// a `.file` positional (`cfg`).
const i2_deploy_opts = [_]zcli.OptionInfo{
    .{ .name = "host", .takes_value = true, .complete = hook_spec },
    .{ .name = "out", .takes_value = true, .complete = .file },
};
const i2_deploy_args = [_]zcli.ArgInfo{.{ .name = "cfg", .complete = .file }};
const i2_commands = [_]zcli.CommandInfo{
    .{ .path = &.{"deploy"}, .options = &i2_deploy_opts, .args = &i2_deploy_args },
};

test "zsh gen - option hook action, .file option + positional actions" {
    const script = try zsh.generate(std.testing.allocator, "advapp", &i2_commands, &global_options);
    defer std.testing.allocator.free(script);
    try std.testing.expect(contains(script, "_advapp_zcli_complete()")); // helper present
    try std.testing.expect(contains(script, ":host:_advapp_zcli_complete")); // dynamic option value
    try std.testing.expect(contains(script, ":out:_files")); // .file option value
    try std.testing.expect(contains(script, ":_files")); // .file positional action
}

test "bash gen - dynamic branch, .file positional + option compgen" {
    const script = try bash.generate(std.testing.allocator, "advapp", &i2_commands, &global_options);
    defer std.testing.allocator.free(script);
    try std.testing.expect(contains(script, "__complete")); // dynamic branch for the hook option
    try std.testing.expect(contains(script, "'deploy')")); // .file positional static case
    try std.testing.expect(contains(script, "compgen -f")); // .file → files
    try std.testing.expect(contains(script, "'--out')")); // .file option $prev case
}

test "fish gen - option hook + .file option + .file positional" {
    const script = try fish.generate(std.testing.allocator, "advapp", &i2_commands, &global_options);
    defer std.testing.allocator.free(script);
    try std.testing.expect(contains(script, "function __advapp_zcli_complete"));
    try std.testing.expect(contains(script, "-l 'host' -x -a '(__advapp_zcli_complete)'")); // dynamic option
    try std.testing.expect(contains(script, "-l 'out' -rF")); // .file option forces files
    // .file positional: force-files at the command's own path, no `-f` suppression.
    try std.testing.expect(contains(script, "complete -c advapp -F -n '__fish_advapp_using_command deploy'"));
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

test "escape.powershell - doubles single quotes, nothing else" {
    const out = try escape.powershell(std.testing.allocator, adversarial);
    defer std.testing.allocator.free(out);
    // The apostrophe is doubled (PowerShell single-quoted-string escape).
    try std.testing.expect(contains(out, "a''b"));
    // Everything else passes through literally (safe inside single quotes).
    try std.testing.expect(contains(out, "\"c$d`e(f)g[h]i\\j k"));
    // No lone apostrophe remains that could terminate the surrounding '…'.
    var i: usize = 0;
    var run: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] == '\'') run += 1 else {
            try std.testing.expect(run % 2 == 0); // quotes only appear in even runs
            run = 0;
        }
    }
    try std.testing.expect(run % 2 == 0);
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

    // Root case: empty key offers the top-level commands. Patterns are
    // single-quoted so a name can never be command-substituted at TAB.
    try std.testing.expect(contains(script, "'')\n"));
    // Nested case: single-word subject "sprint".
    try std.testing.expect(contains(script, "'sprint')"));

    // Aliases surface alongside command names.
    try std.testing.expect(contains(script, "add a "));

    // Enum values are completable via compgen -W.
    try std.testing.expect(contains(script, "low medium high"));

    // A leaf's enum positional is offered at its command path...
    try std.testing.expect(contains(script, "'list')"));
    try std.testing.expect(contains(script, "open done"));
    // ...and the blanket file fallback is gone (no more CWD dump for positionals).
    try std.testing.expect(!contains(script, "compgen -f"));

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
    // Alias appears as an alternation in the case pattern (single-quoted).
    try std.testing.expect(contains(script, "'add'|'a')"));

    // A plain positional force-displays its description as a hint via _message -r
    // (an empty action would render nothing without a `format` zstyle set).
    try std.testing.expect(contains(script, "'1: : _message -r \"Task ID\"'"));
    // An enum positional offers its choices as an action group.
    try std.testing.expect(contains(script, "'1:Filter by status:(open done)'"));
    // The blanket file fallback is gone.
    try std.testing.expect(!contains(script, "_files"));
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

    // A leaf suppresses file completion at its first positional (`-f` at the
    // command's own path condition).
    try std.testing.expect(contains(script, "complete -c tasks -f -n '__fish_tasks_using_command edit'"));
    // An enum positional additionally offers its choices.
    try std.testing.expect(contains(script, "__fish_tasks_using_command list' -a 'open done'"));
}

test "powershell.generate - native completer, describe, enum, and escaping" {
    const script = try powershell.generate(std.testing.allocator, app_name, &commands, &global_options);
    defer std.testing.allocator.free(script);

    // Registered as a native argument completer for the app.
    try std.testing.expect(contains(script, "Register-ArgumentCompleter -Native -CommandName 'tasks'"));
    try std.testing.expect(contains(script, "param($wordToComplete, $commandAst, $cursorPosition)"));

    // Subcommands (with description tooltips) keyed on the command path.
    try std.testing.expect(contains(script, "Complete-Command 'add' 'Add a task'"));
    // Alias surfaces as its own command completion.
    try std.testing.expect(contains(script, "Complete-Command 'a' 'Add a task'"));
    // Nested group dispatch on the path key.
    try std.testing.expect(contains(script, "switch -CaseSensitive ($key)"));
    try std.testing.expect(contains(script, "Complete-Command 'create' 'Create a sprint'"));

    // The apostrophe in "Edit a task's title" is DOUBLED, not left raw.
    try std.testing.expect(contains(script, "Edit a task''s title"));
    try std.testing.expect(!contains(script, "task's title"));

    // Enum option: name completion + value completion.
    try std.testing.expect(contains(script, "Complete-Option '--priority' 'Task priority'"));
    try std.testing.expect(contains(script, "Complete-Value 'low'"));
    try std.testing.expect(contains(script, "Complete-Value 'high'"));

    // Enum positional offers its choices.
    try std.testing.expect(contains(script, "Complete-Value 'open'"));
    try std.testing.expect(contains(script, "Complete-Value 'done'"));

    // Global option with its short form and tooltip.
    try std.testing.expect(contains(script, "Complete-Option '--verbose' 'Verbose output'"));
    try std.testing.expect(contains(script, "Complete-Option '-v' 'Verbose output'"));
}

test "powershell gen - dynamic block, .file option + .file positional" {
    const script = try powershell.generate(std.testing.allocator, "advapp", &i2_commands, &global_options);
    defer std.testing.allocator.free(script);
    // Hook option (`--host`) is resolved dynamically → the __complete block is present.
    try std.testing.expect(contains(script, "& $exe __complete $cword '--' @dynWords"));
    // `.file` option value → dir-inclusive file completion in the $prev switch.
    try std.testing.expect(contains(script, "'--out' {"));
    try std.testing.expect(contains(script, "Complete-Files $false"));
    // `.file` positional → file completion at the command's path key.
    try std.testing.expect(contains(script, "'deploy' {"));
}

test "generators - empty command set still yields a valid skeleton" {
    const empty = [_]zcli.CommandInfo{};
    const script = try bash.generate(std.testing.allocator, app_name, &empty, &global_options);
    defer std.testing.allocator.free(script);
    try std.testing.expect(contains(script, "_tasks_completions()"));
    try std.testing.expect(contains(script, "--verbose"));

    // PowerShell skeleton is valid too (no commands → just globals + registration).
    const ps = try powershell.generate(std.testing.allocator, app_name, &empty, &global_options);
    defer std.testing.allocator.free(ps);
    try std.testing.expect(contains(ps, "Register-ArgumentCompleter -Native -CommandName 'tasks'"));
    try std.testing.expect(contains(ps, "Complete-Option '--verbose' 'Verbose output'"));
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

/// Write `content` as `name` inside `dir` and return its absolute path
/// (arena-owned). The path is resolved via realpath so shell processes spawned
/// with a different cwd can still find it — on Windows a relative write to cwd
/// fails outright, so a real temp dir is mandatory, not merely tidy.
fn writeTemp(arena: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, content: []const u8) ![]const u8 {
    try dir.writeFile(io, .{ .sub_path = name, .data = content });
    return dir.realPathFileAlloc(io, name, arena);
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

/// True when the environment flag `flag` is set to `1`.
///
/// The test root module has no direct env access under the 0.16 explicit-IO
/// model (env arrives via `std.process.Init`, which unit tests don't get), so
/// we read the flag the same way we reach every other shell here: by spawning
/// one. A spawned child inherits our environment by default, so the shell
/// echoes the value back. POSIX uses bash (guaranteed present on the CI legs
/// that set these flags); Windows — where the POSIX probe paths don't exist —
/// uses cmd.exe (always present, resolved via PATH). Anywhere the probe shell
/// is missing this returns false, which only relaxes a requirement — it can
/// never spuriously demand a shell.
fn ciEnvFlagSet(a: std.mem.Allocator, comptime flag: []const u8) bool {
    const result = if (builtin.os.tag == .windows)
        std.process.run(a, io, .{
            .argv = &.{ "cmd.exe", "/d", "/c", "echo %" ++ flag ++ "%" },
        }) catch return false
    else blk: {
        const bash_sh = findShell("bash") orelse return false;
        break :blk std.process.run(a, io, .{
            .argv = &.{ bash_sh, "-c", "printf %s \"$" ++ flag ++ "\"" },
        }) catch return false;
    };
    return std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), "1");
}

/// Whether the environment demands that the fish branch actually run (i.e. fish
/// MUST be present). Set by the CI job that installs fish so a missing binary
/// there turns from a silent skip into a hard failure — the fish generator has
/// never once been validated against real fish otherwise (no runner ships it).
fn ciRequiresFish(a: std.mem.Allocator) bool {
    return ciEnvFlagSet(a, "ZCLI_REQUIRE_FISH");
}

/// Whether the environment demands that the pwsh syntax check actually run.
/// Every GitHub-hosted runner image ships pwsh, so CI sets this on all legs —
/// a lookup regression there must be a hard failure, not a silent skip (the
/// same never-validated guard as fish).
fn ciRequiresPwsh(a: std.mem.Allocator) bool {
    return ciEnvFlagSet(a, "ZCLI_REQUIRE_PWSH");
}

test "shell syntax - bash -n / zsh -n / fish --no-execute accept generated scripts" {
    const bash_sh = findShell("bash");
    const zsh_sh = findShell("zsh");
    const fish_sh = findShell("fish");

    // On platforms with no shell at all (e.g. Windows CI) there is nothing to
    // check — skip cleanly before touching the filesystem so the build harness
    // stays quiet. Per-shell absence below just skips that one shell silently.
    if (bash_sh == null and zsh_sh == null and fish_sh == null) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No CI runner ships fish, so this is the ONE job that installs it — refuse
    // to let the fish branch skip there, or the fish generator regresses to
    // never-validated (its only other coverage is escaping unit tests). Anywhere
    // the flag is unset (dev machines, the other OS legs) fish stays optional.
    if (fish_sh == null and ciRequiresFish(a)) {
        std.debug.print("ZCLI_REQUIRE_FISH=1 but no fish binary found in the known locations\n", .{});
        return error.FishRequiredButMissing;
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bash_script = try bash.generate(a, app_name, &commands, &global_options);
    const zsh_script = try zsh.generate(a, app_name, &commands, &global_options);
    const fish_script = try fish.generate(a, app_name, &commands, &global_options);

    if (bash_sh) |sh| {
        const path = try writeTemp(a, tmp.dir, "zcli_test_completion.bash", bash_script);
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "-n", path }));
    }
    if (zsh_sh) |sh| {
        const path = try writeTemp(a, tmp.dir, "zcli_test_completion.zsh", zsh_script);
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "-n", path }));
    }
    if (fish_sh) |sh| {
        const path = try writeTemp(a, tmp.dir, "zcli_test_completion.fish", fish_script);
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "--no-execute", path }));
    }
}

/// Find the PowerShell (`pwsh`) binary: common fixed locations first (a cheap
/// access check), then a bare-name PATH probe — on the GitHub runners (all
/// three OSes ship pwsh) it lives on PATH, notably `pwsh.exe` on Windows where
/// no fixed POSIX path could ever match. `std.process.spawn` resolves a bare
/// argv[0] via PATH on POSIX and Windows alike, so a trivial `exit 0` run
/// doubles as the existence check. Kept separate from `findShell` (which keys
/// off the first letter) because pwsh's parse-check is invoked differently from
/// the POSIX shells' `-n`.
fn findPwsh(a: std.mem.Allocator) ?[]const u8 {
    const candidates: []const []const u8 = &.{ "/usr/bin/pwsh", "/usr/local/bin/pwsh", "/opt/homebrew/bin/pwsh", "/snap/bin/pwsh" };
    for (candidates) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        return path;
    }
    if (runExit(a, &.{ "pwsh", "-NoProfile", "-NonInteractive", "-Command", "exit 0" }) == 0) return "pwsh";
    return null;
}

test "shell syntax - pwsh accepts the generated PowerShell script" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pwsh = findPwsh(a) orelse {
        // Mirror the fish guard: the CI legs set ZCLI_REQUIRE_PWSH=1 (every
        // GitHub runner image ships pwsh), so a missing binary there is a hard
        // failure — otherwise the PowerShell generator regresses to
        // never-validated. Anywhere the flag is unset pwsh stays optional.
        if (ciRequiresPwsh(a)) {
            std.debug.print("ZCLI_REQUIRE_PWSH=1 but no pwsh binary found (fixed paths + PATH probe)\n", .{});
            return error.PwshRequiredButMissing;
        }
        return error.SkipZigTest;
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Exercise the full feature surface: dynamic hooks, enum/.file options, nested
    // groups. `[scriptblock]::Create` parses the whole scriptblock and throws on a
    // syntax error, so a non-zero exit means the generator emitted invalid syntax.
    const script = try powershell.generate(a, "advapp", &i2_commands, &global_options);
    const path = try writeTemp(a, tmp.dir, "advapp_completion.ps1", script);
    const cmd = try std.fmt.allocPrint(a, "$null = [scriptblock]::Create((Get-Content -Raw -LiteralPath '{s}')); exit 0", .{path});
    try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ pwsh, "-NoProfile", "-NonInteractive", "-Command", cmd }));
}

test "functional bash - COMPREPLY at root and at depth 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = findShell("bash") orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try bash.generate(a, app_name, &commands, &global_options);
    const script_path = try writeTemp(a, tmp.dir, "zcli_func_completion.bash", script);

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
        \\echo "LISTARG:$(run tasks list '')"
        \\
    , .{script_path});
    const harness_path = try writeTemp(a, tmp.dir, "zcli_func_harness.bash", harness);

    const result = try std.process.run(a, io, .{
        .argv = &.{ sh, harness_path },
    });
    const out = result.stdout;

    var root_line: ?[]const u8 = null;
    var depth2_line: ?[]const u8 = null;
    var listarg_line: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "ROOT:")) root_line = line["ROOT:".len..];
        if (std.mem.startsWith(u8, line, "DEPTH2:")) depth2_line = line["DEPTH2:".len..];
        if (std.mem.startsWith(u8, line, "LISTARG:")) listarg_line = line["LISTARG:".len..];
    }

    try std.testing.expect(root_line != null);
    try std.testing.expect(depth2_line != null);
    try std.testing.expect(listarg_line != null);

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

    // `tasks list <TAB>` completes the enum positional's values, NOT files.
    try std.testing.expect(contains(listarg_line.?, "open"));
    try std.testing.expect(contains(listarg_line.?, "done"));
}

// ============================================================================
// Layer 3c: dynamic-completion escaping (ADR-0026) — the generated read paths
// must pass adversarial candidate values through as SINGLE candidates, verbatim.
// ============================================================================

// A fixture app with one dynamic-hook positional so the generators emit the
// `__complete` callback wiring. The hook itself is never run here — a stub binary
// named `advapp` stands in for `__complete` and emits the adversarial records.
const adv_pick_args = [_]zcli.ArgInfo{.{ .name = "thing", .complete = hook_spec }};
const adv_commands = [_]zcli.CommandInfo{.{ .path = &.{"pick"}, .description = "Pick", .args = &adv_pick_args }};

// A POSIX `sh` stub that answers any `__complete` invocation with the directive
// record (`default`) followed by five nasty values, NUL-separated: a space, a
// leading dash, glob chars, a quote, a dollar.
const adv_stub =
    \\#!/bin/sh
    \\printf '%s\0' 'default' 'a b c' '-wip' 'x*y?' "it's" '$HOME'
    \\
;

fn advContains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// Assert every adversarial value survived as its own `<...>`-wrapped line.
fn assertAdvExact(out: []const u8) !void {
    try std.testing.expect(advContains(out, "<a b c>")); // space kept, one candidate
    try std.testing.expect(advContains(out, "<-wip>")); // leading dash not an option
    try std.testing.expect(advContains(out, "<x*y?>")); // glob not expanded
    try std.testing.expect(advContains(out, "<it's>")); // quote intact
    try std.testing.expect(advContains(out, "<$HOME>")); // dollar not expanded
}

test "functional bash - dynamic candidates survive adversarial values verbatim" {
    const sh = findShell("bash") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try bash.generate(a, "advapp", &adv_commands, &global_options);
    const script_path = try writeTemp(a, tmp.dir, "advapp_completion.bash", script);
    const stub_path = try writeTemp(a, tmp.dir, "advapp", adv_stub);

    // Source the completion WITHOUT bash-completion (exercises the fallback), point
    // COMP_WORDS[0] at the stub, and drive the completion at the `pick` positional.
    const harness = try std.fmt.allocPrint(a,
        \\chmod +x "{s}"
        \\source "{s}"
        \\COMP_WORDS=("{s}" pick "")
        \\COMP_CWORD=2
        \\COMPREPLY=()
        \\_advapp_completions
        \\printf '<%s>\n' "${{COMPREPLY[@]}}"
        \\
    , .{ stub_path, script_path, stub_path });
    const harness_path = try writeTemp(a, tmp.dir, "advapp_harness.bash", harness);

    const result = try std.process.run(a, io, .{ .argv = &.{ sh, harness_path } });
    try assertAdvExact(result.stdout);
    // Exactly five candidates — no glob split the `x*y?` into filenames, no split
    // of `a b c` on spaces.
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, result.stdout, "<"));
}

test "functional fish - dynamic candidates survive adversarial values verbatim" {
    const sh = findShell("fish") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try fish.generate(a, "advapp", &adv_commands, &global_options);
    const script_path = try writeTemp(a, tmp.dir, "advapp.fish", script);
    const stub_path = try writeTemp(a, tmp.dir, "advapp", adv_stub);
    const dir_path = std.fs.path.dirname(stub_path).?;

    // Put the stub dir on PATH (the fish helper invokes `advapp` by name), then ask
    // fish for the completions of `advapp pick `, wrapping each in <...>.
    const harness = try std.fmt.allocPrint(a,
        \\chmod +x "{s}"
        \\set -x PATH "{s}" $PATH
        \\source "{s}"
        \\for c in (complete -C "advapp pick ")
        \\    printf '<%s>\n' (string split -- \t $c)[1]
        \\end
        \\
    , .{ stub_path, dir_path, script_path });
    const harness_path = try writeTemp(a, tmp.dir, "advapp_harness.fish", harness);

    const result = try std.process.run(a, io, .{ .argv = &.{ sh, harness_path } });
    try assertAdvExact(result.stdout);
}

// A stub whose `__complete` returns the `also_files` directive plus two dynamic
// candidates — exercising the combine path (candidates AND native files). The
// candidates share the `zz` prefix the test completes with, since a real hook
// filters by the partial and fish's `complete -C` filters candidates by the token.
const comb_stub =
    \\#!/bin/sh
    \\printf '%s\0' 'also_files' 'zzalpha' 'zzbeta'
    \\
;

test "functional bash - also_files directive adds file completion to candidates" {
    const sh = findShell("bash") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try bash.generate(a, "advapp", &adv_commands, &global_options);
    const script_path = try writeTemp(a, tmp.dir, "advapp_completion.bash", script);
    const stub_path = try writeTemp(a, tmp.dir, "advapp", comb_stub);
    _ = try writeTemp(a, tmp.dir, "zzfile", "x"); // a file for the combine path to find
    const dir_path = std.fs.path.dirname(stub_path).?;

    // Complete `advapp pick zz` — the stub yields alpha/beta AND `also_files`, so
    // the file `zzfile` (matching `zz`) must join the candidates.
    const harness = try std.fmt.allocPrint(a,
        \\chmod +x "{s}"
        \\source "{s}"
        \\cd "{s}"
        \\COMP_WORDS=("{s}" pick "zz")
        \\COMP_CWORD=2
        \\COMPREPLY=()
        \\_advapp_completions
        \\printf '<%s>\n' "${{COMPREPLY[@]}}"
        \\
    , .{ stub_path, script_path, dir_path, stub_path });
    const harness_path = try writeTemp(a, tmp.dir, "advapp_comb_harness.bash", harness);

    const result = try std.process.run(a, io, .{ .argv = &.{ sh, harness_path } });
    try std.testing.expect(advContains(result.stdout, "<zzalpha>")); // dynamic candidate
    try std.testing.expect(advContains(result.stdout, "<zzbeta>")); // the other dynamic candidate
    try std.testing.expect(advContains(result.stdout, "<zzfile>")); // native file
}

test "functional fish - also_files directive adds file completion to candidates" {
    const sh = findShell("fish") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try fish.generate(a, "advapp", &adv_commands, &global_options);
    const script_path = try writeTemp(a, tmp.dir, "advapp.fish", script);
    const stub_path = try writeTemp(a, tmp.dir, "advapp", comb_stub);
    _ = try writeTemp(a, tmp.dir, "zzfile", "x");
    const dir_path = std.fs.path.dirname(stub_path).?;

    const harness = try std.fmt.allocPrint(a,
        \\chmod +x "{s}"
        \\set -x PATH "{s}" $PATH
        \\cd "{s}"
        \\source "{s}"
        \\for c in (complete -C "advapp pick zz")
        \\    printf '<%s>\n' (string split -- \t $c)[1]
        \\end
        \\
    , .{ stub_path, dir_path, dir_path, script_path });
    const harness_path = try writeTemp(a, tmp.dir, "advapp_comb_harness.fish", harness);

    const result = try std.process.run(a, io, .{ .argv = &.{ sh, harness_path } });
    try std.testing.expect(advContains(result.stdout, "<zzalpha>"));
    try std.testing.expect(advContains(result.stdout, "<zzbeta>"));
    try std.testing.expect(advContains(result.stdout, "<zzfile>"));
}

// A stub whose `__complete` returns `default` + a matching candidate — used to
// prove the shells only add native files when the DIRECTIVE says so (the shell
// half of the flood guard: no directive combine → no file completion).
const default_stub =
    \\#!/bin/sh
    \\printf '%s\0' 'default' 'zzalpha'
    \\
;

// A stub emitting `also_files` plus the adversarial values — for the zsh helper,
// which is exercised by stubbing `compadd`/`_files`.
const zsh_comb_stub =
    \\#!/bin/sh
    \\printf '%s\0' 'also_files' 'a b c' '-wip' 'x*y?' "it's" '$HOME'
    \\
;

test "gen - combine directive branches present in bash, zsh, fish" {
    const b = try bash.generate(std.testing.allocator, "advapp", &adv_commands, &global_options);
    defer std.testing.allocator.free(b);
    try std.testing.expect(contains(b, "also_files") and contains(b, "compgen -f"));
    try std.testing.expect(contains(b, "also_dirs") and contains(b, "compgen -d"));

    const z = try zsh.generate(std.testing.allocator, "advapp", &adv_commands, &global_options);
    defer std.testing.allocator.free(z);
    try std.testing.expect(contains(z, "also_files) _files"));
    try std.testing.expect(contains(z, "also_dirs) _files -/"));

    const f = try fish.generate(std.testing.allocator, "advapp", &adv_commands, &global_options);
    defer std.testing.allocator.free(f);
    try std.testing.expect(contains(f, "case also_files") and contains(f, "__fish_complete_path"));
    try std.testing.expect(contains(f, "case also_dirs") and contains(f, "__fish_complete_directories"));

    const p = try powershell.generate(std.testing.allocator, "advapp", &adv_commands, &global_options);
    defer std.testing.allocator.free(p);
    try std.testing.expect(contains(p, "$directive -eq 'also_files'") and contains(p, "Complete-Files $false"));
    try std.testing.expect(contains(p, "$directive -eq 'also_dirs'") and contains(p, "Complete-Files $true"));
}

test "functional zsh - dynamic candidates verbatim + combine invokes _files" {
    const sh = findShell("zsh") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try zsh.generate(a, "advapp", &adv_commands, &global_options);
    const script_path = try writeTemp(a, tmp.dir, "_advapp", script);
    const stub_path = try writeTemp(a, tmp.dir, "advapp", zsh_comb_stub);

    // Drive the helper directly with `compadd`/`_files` stubbed to capture their
    // args — deterministic, unlike interactive completion. `_advapp_*` globals are
    // set AFTER sourcing because `_advapp()` clears them (it captures `$words`).
    const harness = try std.fmt.allocPrint(a,
        \\chmod +x "{s}"
        \\compadd() {{ while (( $# )); do print -r -- "ARG:$1"; shift; done }}
        \\_files() {{ print -r -- "FILES:$@" }}
        \\source "{s}" 2>/dev/null
        \\_advapp_words=("{s}" pick "x")
        \\_advapp_current=3
        \\_advapp_zcli_complete
        \\
    , .{ stub_path, script_path, stub_path });
    const harness_path = try writeTemp(a, tmp.dir, "advapp_zharness.zsh", harness);

    const result = try std.process.run(a, io, .{ .argv = &.{ sh, "-f", harness_path } });
    const out = result.stdout;
    // Each adversarial value reached compadd as one verbatim argument.
    try std.testing.expect(advContains(out, "ARG:a b c"));
    try std.testing.expect(advContains(out, "ARG:-wip"));
    try std.testing.expect(advContains(out, "ARG:x*y?"));
    try std.testing.expect(advContains(out, "ARG:it's"));
    try std.testing.expect(advContains(out, "ARG:$HOME"));
    // The combine directive invoked native file completion.
    try std.testing.expect(advContains(out, "FILES:"));
}

test "functional bash - default directive adds NO file completion (guard, shell half)" {
    const sh = findShell("bash") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try bash.generate(a, "advapp", &adv_commands, &global_options);
    const script_path = try writeTemp(a, tmp.dir, "advapp_completion.bash", script);
    const stub_path = try writeTemp(a, tmp.dir, "advapp", default_stub);
    _ = try writeTemp(a, tmp.dir, "zzfile", "x");
    const dir_path = std.fs.path.dirname(stub_path).?;

    const harness = try std.fmt.allocPrint(a,
        \\chmod +x "{s}"
        \\source "{s}"
        \\cd "{s}"
        \\COMP_WORDS=("{s}" pick "zz")
        \\COMP_CWORD=2
        \\COMPREPLY=()
        \\_advapp_completions
        \\printf '<%s>\n' "${{COMPREPLY[@]}}"
        \\
    , .{ stub_path, script_path, dir_path, stub_path });
    const harness_path = try writeTemp(a, tmp.dir, "advapp_default_harness.bash", harness);

    const result = try std.process.run(a, io, .{ .argv = &.{ sh, harness_path } });
    try std.testing.expect(advContains(result.stdout, "<zzalpha>")); // dynamic candidate present
    try std.testing.expect(!advContains(result.stdout, "<zzfile>")); // NO file: directive was default
}

test "functional fish - also_dirs directive offers directories" {
    const sh = findShell("fish") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try fish.generate(a, "advapp", &adv_commands, &global_options);
    const script_path = try writeTemp(a, tmp.dir, "advapp.fish", script);
    const dir_stub =
        \\#!/bin/sh
        \\printf '%s\0' 'also_dirs' 'zzcand'
        \\
    ;
    const stub_path = try writeTemp(a, tmp.dir, "advapp", dir_stub);
    try tmp.dir.createDir(io, "zzdir", .default_dir);
    const dir_path = std.fs.path.dirname(stub_path).?;

    const harness = try std.fmt.allocPrint(a,
        \\chmod +x "{s}"
        \\set -x PATH "{s}" $PATH
        \\cd "{s}"
        \\source "{s}"
        \\for c in (complete -C "advapp pick zz")
        \\    printf '<%s>\n' (string split -- \t $c)[1]
        \\end
        \\
    , .{ stub_path, dir_path, dir_path, script_path });
    const harness_path = try writeTemp(a, tmp.dir, "advapp_dirs_harness.fish", harness);

    const result = try std.process.run(a, io, .{ .argv = &.{ sh, harness_path } });
    try std.testing.expect(advContains(result.stdout, "<zzcand>")); // dynamic candidate
    try std.testing.expect(advContains(result.stdout, "<zzdir/>")); // directory (fish appends /)
}

// ============================================================================
// Layer 4: adversarial command/option/alias NAMES (issue #290)
//
// Names — unlike descriptions — flow into `case` patterns (bash/zsh) and spec
// operands (zsh `_arguments`, fish `-a`/`-l`). Bash expands `case` patterns
// (command substitution included) before matching, so a name like `$(cmd)`
// runs `cmd` on every TAB. These fixtures embed both a quote (breaks a quoted
// context → parse error if unescaped) and a `$(touch …)` command substitution
// (executes at TAB if unescaped) in every name-bearing position.
// ============================================================================

const pwn_file_spec: zcli.completion.Spec = .file;

// A `.file` option so it emits a `$prev` value case (`'--<name>'|'-o')`) without
// dragging an enum's `compgen -W` re-expansion (a separate, out-of-scope vector)
// into the command-substitution assertion.
const adv_name_opts = [_]zcli.OptionInfo{
    .{ .name = "o'p$(touch PWNED_opt)", .short = 'o', .description = "danger opt", .takes_value = true, .complete = pwn_file_spec },
};

// A group (`g'p…`) whose case pattern carries the name, with a leaf child
// (`l'f…`) plus an adversarial alias — the leaf name + alias land in the command
// list and in zsh's `case $line[N]` alternation.
const adv_name_commands = [_]zcli.CommandInfo{
    .{
        .path = &.{ "g'p$(touch PWNED_grp)", "l'f$(touch PWNED_leaf)" },
        .description = "danger",
        .options = &adv_name_opts,
        .aliases = &.{"a'x$(touch PWNED_alias)"},
    },
};

test "gen - adversarial NAMES are escaped, never emitted raw in a case/spec" {
    // Every generator must escape the embedded quote (the `'\''` bash/zsh dance,
    // fish's `\'`) so no name survives as a raw `'`-terminated token — the marker
    // that a name reached a pattern/spec unescaped.
    const b = try bash.generate(std.testing.allocator, "advapp", &adv_name_commands, &global_options);
    defer std.testing.allocator.free(b);
    const z = try zsh.generate(std.testing.allocator, "advapp", &adv_name_commands, &global_options);
    defer std.testing.allocator.free(z);
    const f = try fish.generate(std.testing.allocator, "advapp", &adv_name_commands, &global_options);
    defer std.testing.allocator.free(f);

    // bash/zsh single-quote dance turns `g'p` into `g'\''p`; a raw `case`/spec
    // interpolation would instead show the unescaped `'g'p` prefix.
    try std.testing.expect(contains(b, "g'\\''p"));
    try std.testing.expect(contains(z, "g'\\''p"));
    // fish escapes the quote as `\'` (so `l'f` → `l\'f`).
    try std.testing.expect(contains(f, "l\\'f"));

    // The option name reached its spec/case escaped too (bash `$prev` case; zsh
    // `_arguments` spec).
    try std.testing.expect(contains(b, "o'\\''p"));
    try std.testing.expect(contains(z, "o'\\''p"));
    try std.testing.expect(contains(f, "o\\'p"));
}

test "shell syntax - generators accept adversarial NAMES (bash -n / zsh -n / fish)" {
    const bash_sh = findShell("bash");
    const zsh_sh = findShell("zsh");
    const fish_sh = findShell("fish");
    if (bash_sh == null and zsh_sh == null and fish_sh == null) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (fish_sh == null and ciRequiresFish(a)) return error.FishRequiredButMissing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The embedded quote breaks an unescaped quoted context → the parse fails.
    if (bash_sh) |sh| {
        const s = try bash.generate(a, "advapp", &adv_name_commands, &global_options);
        const path = try writeTemp(a, tmp.dir, "adv_names.bash", s);
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "-n", path }));
    }
    if (zsh_sh) |sh| {
        const s = try zsh.generate(a, "advapp", &adv_name_commands, &global_options);
        const path = try writeTemp(a, tmp.dir, "adv_names.zsh", s);
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "-n", path }));
    }
    if (fish_sh) |sh| {
        const s = try fish.generate(a, "advapp", &adv_name_commands, &global_options);
        const path = try writeTemp(a, tmp.dir, "adv_names.fish", s);
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "--no-execute", path }));
    }
}

test "functional bash - adversarial command/option NAMES do NOT execute at TAB" {
    const sh = findShell("bash") orelse return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try bash.generate(a, "advapp", &adv_name_commands, &global_options);
    const script_path = try writeTemp(a, tmp.dir, "advapp_names.bash", script);
    // Resolve the temp dir (via a throwaway file) so the harness can `cd` into it;
    // any `$(touch PWNED_*)` that fires would drop its marker right here.
    const anchor = try writeTemp(a, tmp.dir, "anchor", "");
    const dir_path = std.fs.path.dirname(anchor).?;

    // Drive the completion function at the two cursor positions that reach the
    // `case` blocks carrying the adversarial names: a bare word (command +
    // `$prev` value cases) and an option prefix (option-name case). Bash expands
    // every pattern in a reached `case` regardless of whether it matches, so an
    // unescaped name's `$(touch …)` would run now. (We never type the adversarial
    // name — doing so would run its substitution in the harness itself.)
    const harness = try std.fmt.allocPrint(a,
        \\source "{s}"
        \\cd "{s}"
        \\drive() {{
        \\    COMP_WORDS=("$@")
        \\    COMP_CWORD=$(( ${{#COMP_WORDS[@]}} - 1 ))
        \\    COMPREPLY=()
        \\    _advapp_completions
        \\}}
        \\drive advapp ''
        \\drive advapp -
        \\echo DONE
        \\
    , .{ script_path, dir_path });
    const harness_path = try writeTemp(a, tmp.dir, "advapp_names_harness.bash", harness);

    const result = try std.process.run(a, io, .{ .argv = &.{ sh, harness_path } });
    try std.testing.expect(advContains(result.stdout, "DONE"));

    // Not a single marker may exist: every name stayed a literal single-quoted
    // pattern, so no command substitution fired.
    for ([_][]const u8{ "PWNED_grp", "PWNED_leaf", "PWNED_alias", "PWNED_opt" }) |marker| {
        const present = if (tmp.dir.access(io, marker, .{})) |_| true else |_| false;
        try std.testing.expect(!present);
    }
}
