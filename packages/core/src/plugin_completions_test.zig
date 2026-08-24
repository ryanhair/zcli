//! Tests for the zcli_completions plugin.
//!
//! Layers:
//!   1. unit tests on the shared command-tree builder (nesting, aliases, enums),
//!   2. escaper tests with adversarial input for each shell,
//!   3. generated-script structural assertions (that would catch the depth
//!      off-by-one and unescaped-quote bugs) plus real-shell validation:
//!      `bash -n`/`zsh -n`/`fish --no-execute` syntax checks and a FUNCTIONAL
//!      bash completion test that sources the script and asserts COMPREPLY at
//!      the root AND at depth 2,
//!   4-5. adversarial command/option NAMES and short chars, driven through real
//!      shells to prove no `<TAB>` executes anything,
//!   6. the plugin module itself (`plugins/zcli_completions/plugin.zig`): the
//!      `__complete` command, the ADR-0026 Request/Result round trip, shell
//!      detection, and the script install/uninstall path.
//!
//! Every test that drives a real shell resolves it through `shellOrSkip` /
//! `requireFound`, so `ZCLI_REQUIRE_BASH`/`_ZSH`/`_FISH` can turn a missing
//! binary into a hard failure instead of a silent skip.

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

// Pull the wire module's own tests (NUL framing / scrubbing) and the plugin's
// own tests (install-path resolution across conventions, shell quoting) into
// this binary.
test {
    _ = wire;
    _ = @import("plugins/zcli_completions/plugin.zig");
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

// A command option colliding with a global on long name AND short char, differing
// in both `takes_value` and `complete`. The resolver's arity walk and its spec
// lookup must agree on precedence; the runtime parser extracts globals first, so
// the collision resolves to the GLOBAL definition (issue #577). Two distinct
// hooks let the test tell which definition won.
fn globalHook(_: *zcli.completion.Request) anyerror!zcli.completion.Result {
    return .{};
}
fn commandHook(_: *zcli.completion.Request) anyerror!zcli.completion.Result {
    return .{};
}

test "resolve - option name collision resolves to the global (arity + spec agree)" {
    // Global `--out`/`-o` takes a value and has globalHook; command `gen`'s
    // `--out`/`-o` is a valueless boolean with commandHook. Completing the token
    // after `--out` must (a) treat it as the option's value, not a positional
    // (global-first arity), and (b) complete with the global's hook (global-first
    // spec). A command-first order would classify `--out` as boolean and shift the
    // slot, completing against the wrong definition.
    const collide_globals = [_]zcli.OptionInfo{
        .{ .name = "out", .short = 'o', .takes_value = true, .complete = .{ .hook = globalHook } },
    };
    const gen_opts = [_]zcli.OptionInfo{
        .{ .name = "out", .short = 'o', .takes_value = false, .complete = .{ .hook = commandHook } },
    };
    const gen_args = [_]zcli.ArgInfo{.{ .name = "target", .complete = hook_spec }};
    const collide_commands = [_]zcli.CommandInfo{
        .{ .path = &.{"gen"}, .options = &gen_opts, .args = &gen_args },
    };

    // Long form: `tasks gen --out <TAB>`.
    {
        const m = (try resolve.resolve(std.testing.allocator, &collide_commands, &collide_globals, &.{ "tasks", "gen", "--out", "" }, 3)) orelse return error.NoMatch;
        defer std.testing.allocator.free(m.positionals);
        try std.testing.expectEqual(@as(usize, 0), m.positionals.len);
        try std.testing.expect(m.spec == .hook);
        try std.testing.expectEqual(&globalHook, m.spec.hook);
    }

    // Short form: `tasks gen -o <TAB>`.
    {
        const m = (try resolve.resolve(std.testing.allocator, &collide_commands, &collide_globals, &.{ "tasks", "gen", "-o", "" }, 3)) orelse return error.NoMatch;
        defer std.testing.allocator.free(m.positionals);
        try std.testing.expectEqual(@as(usize, 0), m.positionals.len);
        try std.testing.expect(m.spec == .hook);
        try std.testing.expectEqual(&globalHook, m.spec.hook);
    }
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

test "tree.build - a hidden group suppresses its visible children" {
    // `secret/index.zig` is hidden but `secret/list.zig` is visible. Hiddenness
    // must propagate downward: neither `secret` nor its child may appear, so
    // completions never offer the hidden group via a materialised child node.
    const cmds = [_]zcli.CommandInfo{
        .{ .path = &.{"visible"}, .description = "Shown" },
        .{ .path = &.{"secret"}, .description = "Hidden group", .hidden = true },
        .{ .path = &.{ "secret", "list" }, .description = "List secrets" },
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

// Multi-line descriptions (issue #638): a literal `\n`/`\r\n` is legal inside a
// shell single-quoted string, so it never breaks the SCRIPT's syntax — but it
// splits a logical one-line entry (a `complete`/`_describe`/case-pattern line)
// across physical lines, corrupting that entry. Every escaper collapses
// `\r`/`\n` to a single space so a multi-line `meta.description` always stays
// on one physical line.
const multiline_desc = "first line\nsecond line\r\nthird $(touch PWNED) line 'quoted'";

test "escape.bash - collapses embedded newlines to spaces" {
    const out = try escape.bash(std.testing.allocator, multiline_desc);
    defer std.testing.allocator.free(out);
    try std.testing.expect(!contains(out, "\n"));
    try std.testing.expect(!contains(out, "\r"));
    try std.testing.expect(contains(out, "first line second line  third"));
    // The apostrophe dance still applies to the trailing quoted word.
    try std.testing.expect(contains(out, "'\\''quoted"));
}

test "escape.fish - collapses embedded newlines to spaces" {
    const out = try escape.fish(std.testing.allocator, multiline_desc);
    defer std.testing.allocator.free(out);
    try std.testing.expect(!contains(out, "\n"));
    try std.testing.expect(!contains(out, "\r"));
    try std.testing.expect(contains(out, "first line second line  third"));
}

test "escape.zsh - collapses embedded newlines to spaces" {
    const out = try escape.zsh(std.testing.allocator, multiline_desc);
    defer std.testing.allocator.free(out);
    try std.testing.expect(!contains(out, "\n"));
    try std.testing.expect(!contains(out, "\r"));
    try std.testing.expect(contains(out, "first line second line  third"));
}

test "escape.powershell - collapses embedded newlines to spaces" {
    const out = try escape.powershell(std.testing.allocator, multiline_desc);
    defer std.testing.allocator.free(out);
    try std.testing.expect(!contains(out, "\n"));
    try std.testing.expect(!contains(out, "\r"));
    try std.testing.expect(contains(out, "first line second line  third"));
}

// A `short: ?u8` option character (issue #638): previously interpolated raw via
// `{c}` with no escaping at all, so `.short = '\''` broke the surrounding
// single-quoted context outright. Every escaper must be safe to run on a
// one-byte slice too.
test "escape.bash - a single-quote short char stays safe inside '-…'" {
    const out = try escape.bash(std.testing.allocator, &[_]u8{'\''});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("'\\''", out);
}

test "escape.fish - a single-quote short char stays safe inside '-…'" {
    const out = try escape.fish(std.testing.allocator, &[_]u8{'\''});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\\'", out);
}

test "escape.zsh - a single-quote short char stays safe inside '-…'" {
    const out = try escape.zsh(std.testing.allocator, &[_]u8{'\''});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("'\\''", out);
}

test "escape.powershell - a single-quote short char stays safe inside '-…'" {
    const out = try escape.powershell(std.testing.allocator, &[_]u8{'\''});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("''", out);
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
/// we read the flag the way we reach everything else here: by spawning a shell.
/// A spawned child inherits our environment by default, so it echoes the value
/// back. Windows — where the POSIX probe paths don't exist — uses cmd.exe
/// (always present, resolved via PATH).
///
/// POSIX deliberately spawns `/bin/sh` DIRECTLY rather than the bash that
/// `findShell` resolves. This probe decides whether a *missing* shell is fatal,
/// so routing it through the same lookup it guards would make the guard vanish
/// exactly when it is needed: break `findShell` and every ZCLI_REQUIRE_* flag
/// silently reads as unset, every site skips, and CI passes green — which is
/// precisely the mutation this guard has to survive (#783). `/bin/sh` is
/// mandated by POSIX and present on every leg that sets these flags.
///
/// If even that probe cannot run, this returns false, which only relaxes a
/// requirement — it can never spuriously demand a shell.
fn ciEnvFlagSet(a: std.mem.Allocator, comptime flag: []const u8) bool {
    const result = if (builtin.os.tag == .windows)
        std.process.run(a, io, .{
            .argv = &.{ "cmd.exe", "/d", "/c", "echo %" ++ flag ++ "%" },
        }) catch return false
    else
        std.process.run(a, io, .{
            .argv = &.{ "/bin/sh", "-c", "printf %s \"$" ++ flag ++ "\"" },
        }) catch return false;
    return std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), "1");
}

/// The `ZCLI_REQUIRE_*` variable guarding `name`'s branch.
fn requireFlag(comptime name: []const u8) []const u8 {
    // A `comptime` block, so the untaken branches (including the @compileError)
    // are never analyzed and the result is usable as a comptime argument.
    return comptime blk: {
        if (std.mem.eql(u8, name, "bash")) break :blk "ZCLI_REQUIRE_BASH";
        if (std.mem.eql(u8, name, "zsh")) break :blk "ZCLI_REQUIRE_ZSH";
        if (std.mem.eql(u8, name, "fish")) break :blk "ZCLI_REQUIRE_FISH";
        if (std.mem.eql(u8, name, "pwsh")) break :blk "ZCLI_REQUIRE_PWSH";
        @compileError("no ZCLI_REQUIRE_* flag defined for shell: " ++ name);
    };
}

/// What a missing `name` means here: `error.SkipZigTest` when the shell is
/// genuinely optional (a dev box without zsh), or a named hard failure when the
/// environment declared it must be present.
///
/// Every shell-driven test below routes its absence through this. Without it a
/// leg that stopped shipping bash — or a `findShell` that stopped finding it —
/// would turn the whole functional half of this suite into silent skips and
/// still report green, which is the failure mode the sibling `_INTERACTIVE`
/// flag was introduced to prevent (#783).
fn missingShell(a: std.mem.Allocator, comptime name: []const u8) anyerror {
    const flag = comptime requireFlag(name);
    if (!ciEnvFlagSet(a, flag)) return error.SkipZigTest;
    std.debug.print(flag ++ "=1 but no " ++ name ++ " binary was found\n", .{});
    if (comptime std.mem.eql(u8, name, "bash")) return error.BashRequiredButMissing;
    if (comptime std.mem.eql(u8, name, "zsh")) return error.ZshRequiredButMissing;
    if (comptime std.mem.eql(u8, name, "fish")) return error.FishRequiredButMissing;
    return error.PwshRequiredButMissing;
}

/// Resolve `name`, turning a miss into `missingShell`'s decision rather than an
/// unconditional skip. The single entry point for every test that needs ONE
/// shell — bash, zsh, fish AND pwsh, so no shell keeps its own bespoke guard;
/// `requireFound` covers the tests that probe several at once.
///
/// pwsh dispatches to `findPwsh` because its lookup differs (fixed paths plus a
/// bare-name PATH probe, which is the only way it is found on Windows); the
/// require-flag half is identical, which is the point.
fn shellOrSkip(a: std.mem.Allocator, comptime name: []const u8) ![]const u8 {
    const found = if (comptime std.mem.eql(u8, name, "pwsh")) findPwsh(a) else findShell(name);
    if (found) |path| return path;
    return missingShell(a, name);
}

/// For the multi-shell tests, which run whichever shells are present and skip
/// the others' branches individually: fail if any absent shell was demanded.
fn requireFound(a: std.mem.Allocator, bash_sh: ?[]const u8, zsh_sh: ?[]const u8, fish_sh: ?[]const u8) !void {
    if (bash_sh == null) {
        const err = missingShell(a, "bash");
        if (err != error.SkipZigTest) return err;
    }
    if (zsh_sh == null) {
        const err = missingShell(a, "zsh");
        if (err != error.SkipZigTest) return err;
    }
    if (fish_sh == null) {
        const err = missingShell(a, "fish");
        if (err != error.SkipZigTest) return err;
    }
}

test "shell syntax - bash -n / zsh -n / fish --no-execute accept generated scripts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bash_sh = findShell("bash");
    const zsh_sh = findShell("zsh");
    const fish_sh = findShell("fish");

    // Refuse to let a demanded shell's branch skip: the POSIX CI legs set
    // ZCLI_REQUIRE_BASH/_ZSH/_FISH, so a shell going missing there (or a
    // findShell regression) fails loudly instead of quietly validating nothing.
    // Anywhere a flag is unset — dev boxes, the Windows leg — that shell stays
    // optional. Checked BEFORE the all-missing skip below, or the one case where
    // the suite runs no shell at all would be the one case that escapes the flags.
    try requireFound(a, bash_sh, zsh_sh, fish_sh);

    // On platforms with no shell at all (e.g. Windows CI) there is nothing to
    // check — skip cleanly before touching the filesystem so the build harness
    // stays quiet. Per-shell absence below just skips that one shell.
    if (bash_sh == null and zsh_sh == null and fish_sh == null) return error.SkipZigTest;

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

    // Same guard as every other shell here: the CI legs set ZCLI_REQUIRE_PWSH=1
    // (every GitHub runner image ships pwsh), so a missing binary there is a
    // hard failure — otherwise the PowerShell generator regresses to
    // never-validated. Anywhere the flag is unset pwsh stays optional.
    const pwsh = try shellOrSkip(a, "pwsh");

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

    const sh = try shellOrSkip(a, "bash");

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
// Layer 3b: value-taking global option before the command (issue #511) — the
// option's VALUE must not be mis-counted as part of the command path.
// ============================================================================

// A global option set with a value-taking global (`--config`, boolean `--verbose`).
const gopt_globals = [_]zcli.OptionInfo{
    .{ .name = "verbose", .short = 'v', .description = "Verbose output" },
    .{ .name = "config", .short = 'c', .description = "Config file", .takes_value = true },
};

// A command set with NO value-taking options anywhere (so the look-ahead patterns
// come only from the globals). `sprint create` is a nested pure-group leaf; `list`
// declares an enum positional but no options.
const no_value_opt_commands = [_]zcli.CommandInfo{
    .{ .path = &.{"list"}, .description = "List tasks", .args = &list_args },
    .{ .path = &.{ "sprint", "create" }, .description = "Create a sprint" },
};

test "bash gen - value-taking global option skips its value in the command path" {
    const script = try bash.generate(std.testing.allocator, app_name, &no_value_opt_commands, &gopt_globals);
    defer std.testing.allocator.free(script);

    // The look-ahead skip machinery is emitted...
    try std.testing.expect(contains(script, "skip_val=0"));
    // ...keyed on the value-taking global's long AND short forms (single-quoted),
    // and NOT on the boolean `--verbose` (which consumes no following word).
    try std.testing.expect(contains(script, "'--config'|'-c') skip_val=1"));
    try std.testing.expect(!contains(script, "'--verbose'"));
}

test "bash gen - no skip machinery when no option takes a value" {
    // Both the `global_options` fixture and `no_value_opt_commands` are value-free
    // → no look-ahead case at all.
    const script = try bash.generate(std.testing.allocator, app_name, &no_value_opt_commands, &global_options);
    defer std.testing.allocator.free(script);
    try std.testing.expect(!contains(script, "skip_val=1"));
}

// ============================================================================
// Layer 3b': value-taking COMMAND-scoped option before a positional (issue #578).
// A command-scoped `--target prod` must have its VALUE skipped too, or `prod`
// pollutes the command path and the command's static positional completions die.
// ============================================================================

const scoped_envs = [_][]const u8{ "staging", "production" };
// `deploy` has a value-taking option (`--target`) AND a static enum positional.
const scoped_deploy_opts = [_]zcli.OptionInfo{
    .{ .name = "target", .short = 't', .description = "Deploy target", .takes_value = true },
};
const scoped_deploy_args = [_]zcli.ArgInfo{
    .{ .name = "env", .description = "Environment", .enum_values = &scoped_envs },
};
const scoped_commands = [_]zcli.CommandInfo{
    .{ .path = &.{"deploy"}, .description = "Deploy", .options = &scoped_deploy_opts, .args = &scoped_deploy_args },
};

test "bash gen - value-taking command option skips its value in the command path (issue #578)" {
    const script = try bash.generate(std.testing.allocator, app_name, &scoped_commands, &global_options);
    defer std.testing.allocator.free(script);

    // The command-scoped value option's long AND short forms are recognised by the
    // command-path look-ahead — even though `--target` is not a GLOBAL option.
    try std.testing.expect(contains(script, "'--target'|'-t') skip_val=1"));
}

test "functional bash - value-taking command option preserves static positional completion (issue #578)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = try shellOrSkip(a, "bash");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try bash.generate(a, app_name, &scoped_commands, &global_options);
    const script_path = try writeTemp(a, tmp.dir, "zcli_scoped_completion.bash", script);

    // Drive completion with a command-scoped value option (`--target h1`) before the
    // positional. The value `h1` must be skipped so the command path resolves to
    // `deploy` (not `deploy h1`) and the enum positional's choices are offered.
    // The separate-word (`--target h1` / `-t h1`) and `=`-joined forms must all work.
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
        \\echo "LONG:$(run tasks deploy --target h1 '')"
        \\echo "SHORT:$(run tasks deploy -t h1 '')"
        \\echo "EQ:$(run tasks deploy --target=h1 '')"
        \\echo "PLAIN:$(run tasks deploy '')"
        \\
    , .{script_path});
    const harness_path = try writeTemp(a, tmp.dir, "zcli_scoped_harness.bash", harness);

    const result = try std.process.run(a, io, .{
        .argv = &.{ sh, harness_path },
    });
    const out = result.stdout;

    var long_line: ?[]const u8 = null;
    var short_line: ?[]const u8 = null;
    var eq_line: ?[]const u8 = null;
    var plain_line: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "LONG:")) long_line = line["LONG:".len..];
        if (std.mem.startsWith(u8, line, "SHORT:")) short_line = line["SHORT:".len..];
        if (std.mem.startsWith(u8, line, "EQ:")) eq_line = line["EQ:".len..];
        if (std.mem.startsWith(u8, line, "PLAIN:")) plain_line = line["PLAIN:".len..];
    }

    try std.testing.expect(long_line != null);
    try std.testing.expect(short_line != null);
    try std.testing.expect(eq_line != null);
    try std.testing.expect(plain_line != null);

    // Every form keys to `deploy` and offers the enum positional's choices — the
    // #578 bug keyed to `deploy h1`, matched no positional case, and offered none.
    try std.testing.expect(contains(long_line.?, "staging"));
    try std.testing.expect(contains(long_line.?, "production"));
    try std.testing.expect(contains(short_line.?, "staging"));
    try std.testing.expect(contains(short_line.?, "production"));
    try std.testing.expect(contains(eq_line.?, "staging"));
    try std.testing.expect(contains(eq_line.?, "production"));
    // Sanity: with no option at all the positional still completes.
    try std.testing.expect(contains(plain_line.?, "staging"));
}

test "powershell gen - value-taking global option skips its value in the command path" {
    const script = try powershell.generate(std.testing.allocator, app_name, &commands, &gopt_globals);
    defer std.testing.allocator.free(script);

    // The look-ahead skip machinery is emitted, keyed on the value-taking global's
    // long AND short forms; the boolean `--verbose` contributes no skip case.
    try std.testing.expect(contains(script, "$skipVal = $false"));
    try std.testing.expect(contains(script, "'--config' { $skipVal = $true }"));
    try std.testing.expect(contains(script, "'-c' { $skipVal = $true }"));
    try std.testing.expect(!contains(script, "'--verbose' { $skipVal"));
}

test "functional bash - value-taking global option before the command keys correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = try shellOrSkip(a, "bash");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try bash.generate(a, app_name, &commands, &gopt_globals);
    const script_path = try writeTemp(a, tmp.dir, "zcli_gopt_completion.bash", script);

    // Drive completion with a value-taking global (`--config x.json`) preceding the
    // command. The value `x.json` must be skipped, so the command path resolves to
    // `sprint` (depth 2) / the root — NOT to `x.json` (which matches no case → no
    // completions, the bug in #511). The `=`-joined and boolean forms must also work.
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
        \\echo "SEP:$(run tasks --config x.json sprint '')"
        \\echo "EQ:$(run tasks --config=x.json sprint '')"
        \\echo "ROOT:$(run tasks --config x.json '')"
        \\echo "BOOL:$(run tasks --verbose '')"
        \\
    , .{script_path});
    const harness_path = try writeTemp(a, tmp.dir, "zcli_gopt_harness.bash", harness);

    const result = try std.process.run(a, io, .{
        .argv = &.{ sh, harness_path },
    });
    const out = result.stdout;

    var sep_line: ?[]const u8 = null;
    var eq_line: ?[]const u8 = null;
    var root_line: ?[]const u8 = null;
    var bool_line: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "SEP:")) sep_line = line["SEP:".len..];
        if (std.mem.startsWith(u8, line, "EQ:")) eq_line = line["EQ:".len..];
        if (std.mem.startsWith(u8, line, "ROOT:")) root_line = line["ROOT:".len..];
        if (std.mem.startsWith(u8, line, "BOOL:")) bool_line = line["BOOL:".len..];
    }

    try std.testing.expect(sep_line != null);
    try std.testing.expect(eq_line != null);
    try std.testing.expect(root_line != null);
    try std.testing.expect(bool_line != null);

    // `tasks --config x.json sprint <TAB>` → sprint subcommands (value skipped).
    try std.testing.expect(contains(sep_line.?, "create"));
    try std.testing.expect(contains(sep_line.?, "list"));
    try std.testing.expect(!contains(sep_line.?, "add"));

    // The `=`-joined form resolves identically.
    try std.testing.expect(contains(eq_line.?, "create"));
    try std.testing.expect(contains(eq_line.?, "list"));

    // `tasks --config x.json <TAB>` → the root commands (key is empty, not x.json).
    try std.testing.expect(contains(root_line.?, "add"));
    try std.testing.expect(contains(root_line.?, "sprint"));

    // A boolean global consumes no value, so the root commands still complete.
    try std.testing.expect(contains(bool_line.?, "add"));
    try std.testing.expect(contains(bool_line.?, "sprint"));
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = try shellOrSkip(a, "bash");

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = try shellOrSkip(a, "fish");

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = try shellOrSkip(a, "bash");

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = try shellOrSkip(a, "fish");

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = try shellOrSkip(a, "zsh");

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = try shellOrSkip(a, "bash");

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = try shellOrSkip(a, "fish");

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bash_sh = findShell("bash");
    const zsh_sh = findShell("zsh");
    const fish_sh = findShell("fish");

    // Same require-flag guard as the first syntax test, before the all-missing
    // skip: a demanded shell that has gone missing must fail, not skip.
    try requireFound(a, bash_sh, zsh_sh, fish_sh);
    if (bash_sh == null and zsh_sh == null and fish_sh == null) return error.SkipZigTest;

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sh = try shellOrSkip(a, "bash");

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

// ============================================================================
// Layer 5: adversarial SHORT chars + multi-line DESCRIPTIONS (issue #638)
//
// `short: ?u8` used to be interpolated raw via `{c}` in every generator — no
// escaper in the path at all — so `.short = '\''` broke the surrounding
// single-quoted context outright. Separately, a `meta.description` containing
// `\n` split a logical one-line completion entry across physical lines. Both
// are exercised end to end here: a real single-quote short AND a multi-line,
// quote-and-`$(...)`-bearing description, on every generator, plus a real-shell
// syntax check.
// ============================================================================

const adv_short_desc = "line one\nline two 'quoted' $(touch PWNED_desc)";

const adv_short_opts = [_]zcli.OptionInfo{
    .{ .name = "quiet", .short = '\'', .description = adv_short_desc },
};

const adv_short_commands = [_]zcli.CommandInfo{
    .{ .path = &.{"run"}, .description = adv_short_desc, .options = &adv_short_opts },
};

test "gen - adversarial SHORT char and multi-line description are escaped everywhere" {
    const b = try bash.generate(std.testing.allocator, "advapp", &adv_short_commands, &global_options);
    defer std.testing.allocator.free(b);
    const z = try zsh.generate(std.testing.allocator, "advapp", &adv_short_commands, &global_options);
    defer std.testing.allocator.free(z);
    const f = try fish.generate(std.testing.allocator, "advapp", &adv_short_commands, &global_options);
    defer std.testing.allocator.free(f);
    const p = try powershell.generate(std.testing.allocator, "advapp", &adv_short_commands, &global_options);
    defer std.testing.allocator.free(p);

    // No generator emits a raw newline: every description stays on one physical
    // line, so a corrupted multi-line entry can never appear in the script.
    // (bash never emits descriptions at all — COMPREPLY has no description
    // channel — so it has nothing to collapse; zsh/fish/powershell do.)
    try std.testing.expect(!contains(b, "line one\nline two"));
    try std.testing.expect(!contains(z, "line one\nline two"));
    try std.testing.expect(!contains(f, "line one\nline two"));
    try std.testing.expect(!contains(p, "line one\nline two"));

    // The collapsed, single-line description text is present in some escaped form.
    try std.testing.expect(contains(z, "line one line two"));
    try std.testing.expect(contains(f, "line one line two"));
    try std.testing.expect(contains(p, "line one line two"));

    // The short char (a literal `'`) never survives as a raw, unescaped quote
    // immediately after a `-`: bash/zsh dance it to `-'\''`, fish escapes to
    // `-\'` (quoted), powershell doubles it to `-''`.
    try std.testing.expect(contains(b, "-'\\''"));
    try std.testing.expect(contains(z, "-'\\''"));
    try std.testing.expect(contains(f, " -s '\\''"));
    try std.testing.expect(contains(p, "-''"));
}

test "shell syntax - generators accept an adversarial SHORT char (bash -n / zsh -n / fish)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bash_sh = findShell("bash");
    const zsh_sh = findShell("zsh");
    const fish_sh = findShell("fish");

    // Same require-flag guard as the first syntax test, before the all-missing
    // skip: a demanded shell that has gone missing must fail, not skip.
    try requireFound(a, bash_sh, zsh_sh, fish_sh);
    if (bash_sh == null and zsh_sh == null and fish_sh == null) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    if (bash_sh) |sh| {
        const s = try bash.generate(a, "advapp", &adv_short_commands, &global_options);
        const path = try writeTemp(a, tmp.dir, "adv_short.bash", s);
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "-n", path }));
    }
    if (zsh_sh) |sh| {
        const s = try zsh.generate(a, "advapp", &adv_short_commands, &global_options);
        const path = try writeTemp(a, tmp.dir, "adv_short.zsh", s);
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "-n", path }));
    }
    if (fish_sh) |sh| {
        const s = try fish.generate(a, "advapp", &adv_short_commands, &global_options);
        const path = try writeTemp(a, tmp.dir, "adv_short.fish", s);
        try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ sh, "--no-execute", path }));
    }
}

test "shell syntax - pwsh accepts an adversarial SHORT char and multi-line description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pwsh = try shellOrSkip(a, "pwsh");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script = try powershell.generate(a, "advapp", &adv_short_commands, &global_options);
    const path = try writeTemp(a, tmp.dir, "adv_short.ps1", script);
    const cmd = try std.fmt.allocPrint(a, "$null = [scriptblock]::Create((Get-Content -Raw -LiteralPath '{s}')); exit 0", .{path});
    try std.testing.expectEqual(@as(u8, 0), runExit(a, &.{ pwsh, "-NoProfile", "-NonInteractive", "-Command", cmd }));
}

// ============================================================================
// Layer 6: the plugin shell itself — `__complete` and
// `completions generate|install|uninstall`
// (plugins/zcli_completions/plugin.zig).
//
// Everything above tests the GENERATORS. The 400-line module that wires them to
// commands was imported by no test at all (#782): the `__complete` dispatch, the
// ADR-0026 Request/Result round trip, `$SHELL` detection, and the script
// install/uninstall path were compiled and never once executed. These drive the
// real `execute` functions through a duck-typed context — the same shape the
// registry passes — and assert emitted bytes, files on disk and error values,
// never just "it returned".
// ============================================================================

const plugin = @import("plugins/zcli_completions/plugin.zig");
const complete_cmd = plugin.commands.__complete;
const generate_cmd = plugin.commands.completions.generate;
const install_cmd = plugin.commands.completions.install;
const uninstall_cmd = plugin.commands.completions.uninstall;

/// The slice of the framework `Context` this plugin actually touches. `execute`
/// takes `context: anytype`, so a struct with these members IS the contract —
/// if the plugin starts reaching for something else, this stops compiling, which
/// is the point.
const PluginCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    app_name: []const u8,
    command_info: []const zcli.CommandInfo = &.{},
    globals: []const zcli.OptionInfo = &.{},
    out: *std.Io.Writer,
    err: *std.Io.Writer,

    pub fn stdout(self: *@This()) *std.Io.Writer {
        return self.out;
    }
    pub fn stderr(self: *@This()) *std.Io.Writer {
        return self.err;
    }
    pub fn getAvailableCommandInfo(self: *@This()) []const zcli.CommandInfo {
        return self.command_info;
    }
    pub fn getGlobalOptions(self: *@This()) []const zcli.OptionInfo {
        return self.globals;
    }
    /// Mirrors `Context.paths()` — the plugin creates its install directory
    /// through the guarded `ensureParent`.
    pub fn paths(self: *@This()) zcli.Paths {
        return .{
            .allocator = self.allocator,
            .environ = self.environ,
            .app_name = self.app_name,
        };
    }
};

/// An environment map holding exactly `pairs`, arena-owned.
fn envWith(a: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(a);
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

// --- What the hook was handed -----------------------------------------------
// Recorded at file scope because a completion hook is a plain function pointer
// with no user-data channel; the tests reset these before each run.

var seen_partial: []const u8 = "";
var seen_args: []const []const u8 = &.{};
var seen_env: ?[]const u8 = null;
var seen_calls: usize = 0;

fn resetSeen() void {
    seen_partial = "";
    seen_args = &[_][]const u8{};
    seen_env = null;
    seen_calls = 0;
}

/// Records its `Request` and echoes the partial back as a candidate, so one
/// assertion covers both directions of the round trip. The echo is built with
/// `req.allocator`, which proves the arena handed over is usable.
fn recordingHook(req: *zcli.completion.Request) anyerror!zcli.completion.Result {
    seen_calls += 1;
    seen_partial = req.partial;
    seen_args = req.args;
    seen_env = req.environ.get("ZCLI_TEST_MARK");

    const echoed = try std.fmt.allocPrint(req.allocator, "got:{s}", .{req.partial});
    const list = try req.allocator.alloc(zcli.completion.Candidate, 2);
    list[0] = .{ .value = echoed, .description = "echo of the partial" };
    // A tab inside a value would corrupt the value/description framing; the
    // plugin must route through wire.writeResult (which scrubs it), not print
    // candidates itself.
    list[1] = .{ .value = "a b\tc", .description = "adversarial" };
    return .{ .candidates = list };
}

fn failingHook(_: *zcli.completion.Request) anyerror!zcli.completion.Result {
    seen_calls += 1;
    return error.HookBlewUp;
}

const combine_candidates = [_]zcli.completion.Candidate{.{ .value = "alpha" }};

fn alsoFilesHook(_: *zcli.completion.Request) anyerror!zcli.completion.Result {
    seen_calls += 1;
    return .{ .candidates = &combine_candidates, .directive = .also_files };
}

const pc_edit_args = [_]zcli.ArgInfo{.{ .name = "id", .complete = .{ .hook = recordingHook } }};
const pc_move_args = [_]zcli.ArgInfo{
    .{ .name = "id", .complete = .{ .hook = recordingHook } },
    .{ .name = "sprint", .complete = .{ .hook = recordingHook } },
};
const pc_boom_args = [_]zcli.ArgInfo{.{ .name = "id", .complete = .{ .hook = failingHook } }};
const pc_import_args = [_]zcli.ArgInfo{.{ .name = "path", .complete = .file }};
const pc_combine_args = [_]zcli.ArgInfo{.{ .name = "id", .complete = .{ .hook = alsoFilesHook } }};
const pc_plain_args = [_]zcli.ArgInfo{.{ .name = "status" }};

const plugin_commands = [_]zcli.CommandInfo{
    .{ .path = &.{"edit"}, .description = "Edit a task", .args = &pc_edit_args },
    .{ .path = &.{"move"}, .description = "Move a task", .args = &pc_move_args },
    .{ .path = &.{"boom"}, .description = "Failing hook", .args = &pc_boom_args },
    .{ .path = &.{"import"}, .description = "Native file completion", .args = &pc_import_args },
    .{ .path = &.{"combine"}, .description = "Combine directive", .args = &pc_combine_args },
    .{ .path = &.{"list"}, .description = "No completion", .args = &pc_plain_args },
};

const Emitted = struct { out: []const u8, err: []const u8 };

/// Run `__complete <cword> -- words…` against `plugin_commands` and return what
/// it wrote to each stream. Buffers are arena-backed, so the slices outlive the
/// call.
fn runComplete(
    a: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    words: []const []const u8,
    cword: usize,
) !Emitted {
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    var ctx: PluginCtx = .{
        .allocator = a,
        .io = io,
        .environ = environ,
        .app_name = app_name,
        .command_info = &plugin_commands,
        .globals = &global_options,
        .out = &out.writer,
        .err = &err.writer,
    };
    try complete_cmd.execute(.{ .cword = cword, .words = words }, .{}, &ctx);
    return .{ .out = out.written(), .err = err.written() };
}

test "__complete - runs the resolved hook and emits the exact NUL wire stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    resetSeen();
    var environ = try envWith(a, &.{.{ "ZCLI_TEST_MARK", "threaded" }});
    const emitted = try runComplete(a, &environ, &.{ "tasks", "edit", "ta" }, 2);

    // The hook ran exactly once, and saw the word under the cursor.
    try std.testing.expectEqual(@as(usize, 1), seen_calls);
    try std.testing.expectEqualStrings("ta", seen_partial);
    // `environ` reached the hook — a hook that reads config/env would otherwise
    // silently see an empty environment.
    try std.testing.expectEqualStrings("threaded", seen_env orelse "");

    // Directive record first, then one record per candidate; the value tab is
    // scrubbed to a space while the description tab would have been kept.
    try std.testing.expectEqualStrings(
        "default\x00got:ta\techo of the partial\x00a b c\tadversarial\x00",
        emitted.out,
    );
    // stdout is the protocol channel: nothing else may appear on it, and errors
    // stay silent unless ZCLI_COMPLETE_DEBUG asks for them.
    try std.testing.expectEqualStrings("", emitted.err);
}

test "__complete - preceding positionals reach the hook as Request.args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    resetSeen();
    var environ = try envWith(a, &.{});
    // `move <id> <sprint>`: the cursor is on slot 1, so slot 0's token is context.
    const emitted = try runComplete(a, &environ, &.{ "tasks", "move", "7", "q" }, 3);

    try std.testing.expectEqual(@as(usize, 1), seen_calls);
    try std.testing.expectEqual(@as(usize, 1), seen_args.len);
    try std.testing.expectEqualStrings("7", seen_args[0]);
    try std.testing.expectEqualStrings("q", seen_partial);
    try std.testing.expectEqualStrings("default\x00got:q\techo of the partial\x00a b c\tadversarial\x00", emitted.out);
}

test "__complete - a failing hook yields an empty stream and stays silent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    resetSeen();
    var environ = try envWith(a, &.{});
    // No `try` slip: the hook's error must be swallowed, never propagated — a
    // returned error would make the shell print a Zig trace at <TAB>.
    const emitted = try runComplete(a, &environ, &.{ "tasks", "boom", "x" }, 2);

    try std.testing.expectEqual(@as(usize, 1), seen_calls);
    // Not even the directive record: a broken hook produces NOTHING, so the
    // shell falls back to its own default rather than reading a truncated frame.
    try std.testing.expectEqualStrings("", emitted.out);
    try std.testing.expectEqualStrings("", emitted.err);
}

test "__complete - ZCLI_COMPLETE_DEBUG surfaces the hook error on stderr only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    resetSeen();
    var environ = try envWith(a, &.{.{ "ZCLI_COMPLETE_DEBUG", "1" }});
    const emitted = try runComplete(a, &environ, &.{ "tasks", "boom", "x" }, 2);

    // The error NAME is what makes silent-nothing debuggable (ADR-0026).
    try std.testing.expect(contains(emitted.err, "hook error: HookBlewUp"));
    // stderr, never stdout — stdout is the byte stream the protocol travels on.
    try std.testing.expectEqualStrings("", emitted.out);
}

test "__complete - ZCLI_COMPLETE_DEBUG=0 and empty are off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{ "0", "" }) |value| {
        resetSeen();
        var environ = try envWith(a, &.{.{ "ZCLI_COMPLETE_DEBUG", value }});
        const emitted = try runComplete(a, &environ, &.{ "tasks", "boom", "x" }, 2);
        try std.testing.expectEqualStrings("", emitted.err);
        try std.testing.expectEqualStrings("", emitted.out);
    }
}

test "__complete - a .file builtin never calls back (resolved at generation time)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    resetSeen();
    var environ = try envWith(a, &.{});
    const emitted = try runComplete(a, &environ, &.{ "tasks", "import", "x" }, 2);

    // Emitting a directive here would make the script offer zero candidates
    // INSTEAD of the shell's native file completion the generator already wired.
    try std.testing.expectEqualStrings("", emitted.out);
    try std.testing.expectEqual(@as(usize, 0), seen_calls);
}

test "__complete - nothing resolvable prints nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = try envWith(a, &.{});
    // A positional with no `complete`, an unknown command, the command name
    // itself, and an out-of-range cursor.
    for ([_]struct { words: []const []const u8, cword: usize }{
        .{ .words = &.{ "tasks", "list", "x" }, .cword = 2 },
        .{ .words = &.{ "tasks", "nope", "x" }, .cword = 2 },
        .{ .words = &.{ "tasks", "ed" }, .cword = 1 },
        .{ .words = &.{"tasks"}, .cword = 0 },
    }) |case| {
        resetSeen();
        const emitted = try runComplete(a, &environ, case.words, case.cword);
        try std.testing.expectEqualStrings("", emitted.out);
        try std.testing.expectEqual(@as(usize, 0), seen_calls);
    }
}

test "__complete - also_files rides through, and an empty partial downgrades it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = try envWith(a, &.{});

    // A non-empty partial keeps the combine directive.
    const with_partial = try runComplete(a, &environ, &.{ "tasks", "combine", "al" }, 2);
    try std.testing.expectEqualStrings("also_files\x00alpha\x00", with_partial.out);

    // A bare <TAB> downgrades it to `default` — the flood guard, applied at this
    // boundary so no script can dump the whole CWD.
    const bare = try runComplete(a, &environ, &.{ "tasks", "combine", "" }, 2);
    try std.testing.expectEqualStrings("default\x00alpha\x00", bare.out);
}

// --- completions generate ---------------------------------------------------

const GenerateOutcome = struct {
    out: []const u8,
    err: []const u8,
    /// `execute`'s own result, captured rather than propagated so a test can
    /// assert the error value AND that stdout stayed clean.
    result: anyerror!void,
};

/// Run `completions generate [shell]`, returning what it wrote and its result.
fn runGenerate(
    a: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    shell: ?[]const u8,
) GenerateOutcome {
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    var ctx: PluginCtx = .{
        .allocator = a,
        .io = io,
        .environ = environ,
        .app_name = app_name,
        .command_info = &commands,
        .globals = &global_options,
        .out = &out.writer,
        .err = &err.writer,
    };
    const result = generate_cmd.execute(.{ .shell = shell }, .{}, &ctx);
    return .{ .out = out.written(), .err = err.written(), .result = result };
}

test "generate - each shell name emits that generator's script verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = try envWith(a, &.{});

    // Byte-for-byte against the generator the name selects: proves the dispatch
    // picks the right one AND that app_name/commands/globals were threaded
    // through unchanged (a swapped argument would change the output).
    const expected_bash = try bash.generate(a, app_name, &commands, &global_options);
    const expected_zsh = try zsh.generate(a, app_name, &commands, &global_options);
    const expected_fish = try fish.generate(a, app_name, &commands, &global_options);
    const expected_ps = try powershell.generate(a, app_name, &commands, &global_options);

    for ([_]struct { name: []const u8, want: []const u8 }{
        .{ .name = "bash", .want = expected_bash },
        .{ .name = "zsh", .want = expected_zsh },
        .{ .name = "fish", .want = expected_fish },
        // Every spelling PowerShell is invoked under maps to the one generator.
        .{ .name = "powershell", .want = expected_ps },
        .{ .name = "pwsh", .want = expected_ps },
        .{ .name = "powershell.exe", .want = expected_ps },
        .{ .name = "pwsh.exe", .want = expected_ps },
    }) |case| {
        const emitted = runGenerate(a, &environ, case.name);
        try emitted.result;
        try std.testing.expectEqualStrings(case.want, emitted.out);
        try std.testing.expectEqualStrings("", emitted.err);
    }
}

test "generate - no argument detects the shell from $SHELL's basename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expected_bash = try bash.generate(a, app_name, &commands, &global_options);
    const expected_zsh = try zsh.generate(a, app_name, &commands, &global_options);
    const expected_fish = try fish.generate(a, app_name, &commands, &global_options);
    const expected_ps = try powershell.generate(a, app_name, &commands, &global_options);

    // Every supported shell, each as a PATH — detection has to take the
    // basename, so a bare-name-only implementation fails here. bash first: it is
    // the overwhelmingly common value of $SHELL and the one whose regression
    // would be felt widest.
    for ([_]struct { shell_env: []const u8, want: []const u8 }{
        .{ .shell_env = "/bin/bash", .want = expected_bash },
        .{ .shell_env = "/usr/local/bin/bash", .want = expected_bash },
        .{ .shell_env = "/usr/local/bin/zsh", .want = expected_zsh },
        .{ .shell_env = "/opt/homebrew/bin/fish", .want = expected_fish },
        // A pwsh login shell is unusual but legal, and it exercises the alias
        // table through the detection path rather than the explicit-name path.
        .{ .shell_env = "/usr/bin/pwsh", .want = expected_ps },
    }) |case| {
        var environ = try envWith(a, &.{.{ "SHELL", case.shell_env }});
        const emitted = runGenerate(a, &environ, null);
        try emitted.result;
        try std.testing.expectEqualStrings(case.want, emitted.out);
        try std.testing.expectEqualStrings("", emitted.err);
    }
}

test "generate - unsupported and undetectable shells fail without writing stdout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An explicit but unknown name.
    var environ = try envWith(a, &.{});
    const bad = runGenerate(a, &environ, "tcsh");
    try std.testing.expectError(error.UnsupportedShell, bad.result);
    try std.testing.expect(contains(bad.err, "unsupported shell 'tcsh'"));
    try std.testing.expect(contains(bad.err, "bash, zsh, fish, powershell"));
    // Nothing partial on stdout: a caller redirecting to a file gets an empty
    // file, not half a script.
    try std.testing.expectEqualStrings("", bad.out);

    // No $SHELL at all.
    const undetectable = runGenerate(a, &environ, null);
    try std.testing.expectError(error.ShellNotDetected, undetectable.result);
    try std.testing.expect(contains(undetectable.err, "could not detect shell"));
    try std.testing.expectEqualStrings("", undetectable.out);

    // A $SHELL naming something we don't generate for is the same failure.
    var tcsh_env = try envWith(a, &.{.{ "SHELL", "/bin/tcsh" }});
    const unknown_env = runGenerate(a, &tcsh_env, null);
    try std.testing.expectError(error.ShellNotDetected, unknown_env.result);
    try std.testing.expectEqualStrings("", unknown_env.out);
}

// --- completions install / uninstall ----------------------------------------

/// A throwaway `$HOME` plus the environment pointing at it.
const FakeHome = struct {
    tmp: std.testing.TmpDir,
    path: []const u8,
    environ: std.process.Environ.Map,

    fn init(a: std.mem.Allocator) !FakeHome {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        // realpath via a throwaway file: the plugin builds an ABSOLUTE install
        // path from $HOME, so a relative temp dir would not do.
        const anchor = try writeTemp(a, tmp.dir, "anchor", "");
        const home = std.fs.path.dirname(anchor).?;
        // %APPDATA%/%LOCALAPPDATA% too, so the Windows host convention (which
        // PowerShell follows) resolves inside the temp dir rather than the real
        // user profile.
        return .{
            .tmp = tmp,
            .path = home,
            .environ = try envWith(a, &.{
                .{ "HOME", home },
                .{ "APPDATA", home },
                .{ "LOCALAPPDATA", home },
            }),
        };
    }

    fn deinit(self: *FakeHome) void {
        self.tmp.cleanup();
    }
};

fn runInstall(a: std.mem.Allocator, home: *FakeHome, shell: ?[]const u8) !Emitted {
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    var ctx: PluginCtx = .{
        .allocator = a,
        .io = io,
        .environ = &home.environ,
        .app_name = app_name,
        .command_info = &commands,
        .globals = &global_options,
        .out = &out.writer,
        .err = &err.writer,
    };
    try install_cmd.execute(.{ .shell = shell }, .{}, &ctx);
    return .{ .out = out.written(), .err = err.written() };
}

fn runUninstall(a: std.mem.Allocator, home: *FakeHome, shell: ?[]const u8) !Emitted {
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    var ctx: PluginCtx = .{
        .allocator = a,
        .io = io,
        .environ = &home.environ,
        .app_name = app_name,
        .command_info = &commands,
        .globals = &global_options,
        .out = &out.writer,
        .err = &err.writer,
    };
    try uninstall_cmd.execute(.{ .shell = shell }, .{}, &ctx);
    return .{ .out = out.written(), .err = err.written() };
}

/// Where each shell's script is expected to land under `home`.
/// The destination each shell's script is expected at, given a home with no
/// XDG_* or BASH_COMPLETION_USER_DIR set. Joined with the host separator,
/// because the plugin emits native paths (host `syntax`).
fn installedPath(a: std.mem.Allocator, home: []const u8, shell: []const u8) ![]const u8 {
    if (std.mem.eql(u8, shell, "bash"))
        return std.fs.path.join(a, &.{ home, ".local", "share", "bash-completion", "completions", app_name });
    if (std.mem.eql(u8, shell, "zsh"))
        return std.fs.path.join(a, &.{ home, ".zsh", "completions", "_" ++ app_name });
    if (std.mem.eql(u8, shell, "fish"))
        return std.fs.path.join(a, &.{ home, ".config", "fish", "completions", app_name ++ ".fish" });
    // PowerShell follows the HOST convention: %APPDATA%\powershell\… on
    // Windows (where there is no XDG story), ~/.config/powershell/… on POSIX.
    if (builtin.os.tag == .windows)
        return std.fs.path.join(a, &.{ home, "powershell", "completions", app_name ++ ".ps1" });
    return std.fs.path.join(a, &.{ home, ".config", "powershell", "completions", app_name ++ ".ps1" });
}

// NOTE: this is #782 wiring coverage ONLY — it passes just as well against the
// old `createFile(.{})` write, because it never puts anything at the
// destination beforehand. The #775 guarantee (a planted symlink is replaced,
// not followed) is asserted solely by the dedicated regression test below;
// don't read this one as covering it.
test "install - each shell's script lands at its documented path, byte-for-byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{ "bash", "zsh", "fish", "powershell" }) |shell| {
        var home = try FakeHome.init(a);
        defer home.deinit();

        const emitted = try runInstall(a, &home, shell);

        // The parent directories did not exist — install had to create them.
        const path = try installedPath(a, home.path, shell);
        const written = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));

        const expected = switch (shell[0]) {
            'b' => try bash.generate(a, app_name, &commands, &global_options),
            'z' => try zsh.generate(a, app_name, &commands, &global_options),
            'f' => try fish.generate(a, app_name, &commands, &global_options),
            else => try powershell.generate(a, app_name, &commands, &global_options),
        };
        try std.testing.expectEqualStrings(expected, written);

        // The path it reports is the path it wrote, and the enable instructions
        // are what make an installed-but-unloaded script debuggable.
        try std.testing.expect(contains(emitted.out, path));
        try std.testing.expect(contains(emitted.out, "✓ Installed"));
        try std.testing.expectEqualStrings("", emitted.err);
    }
}

test "install - a symlink at the destination is replaced, not followed (#775)" {
    // Creating a symlink on Windows needs Developer Mode or
    // SeCreateSymbolicLinkPrivilege, neither of which a CI test may assume — so
    // this asserts the POSIX guarantee only. Windows runs the same code path
    // unverified; see the trust-assumption comment in the plugin's `install`.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var home = try FakeHome.init(a);
    defer home.deinit();

    // A file the attacker wants overwritten, and a symlink planted at the
    // predictable install path pointing at it. This is the whole attack: the
    // destination is derived from $HOME, so its name is known in advance.
    const victim_rel = "precious.txt";
    try home.tmp.dir.writeFile(io, .{ .sub_path = victim_rel, .data = "ORIGINAL" });
    const victim_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ home.path, victim_rel });

    const dest = try installedPath(a, home.path, "zsh");
    const dest_dir = std.fs.path.dirname(dest).?;
    try std.Io.Dir.cwd().createDirPath(io, dest_dir);
    try std.Io.Dir.cwd().symLink(io, victim_path, dest, .{});

    _ = try runInstall(a, &home, "zsh");

    // The victim is untouched — the write did NOT travel through the link.
    const victim_after = try std.Io.Dir.cwd().readFileAlloc(io, victim_path, a, .limited(1 << 20));
    try std.testing.expectEqualStrings("ORIGINAL", victim_after);

    // And the link itself is gone: the destination is now a real file holding
    // the script. (`follow_symlinks = false` — otherwise this would stat through
    // a surviving link and pass while the bug was still present.)
    const st = try std.Io.Dir.cwd().statFile(io, dest, .{ .follow_symlinks = false });
    try std.testing.expect(st.kind == .file);

    const expected = try zsh.generate(a, app_name, &commands, &global_options);
    const written = try std.Io.Dir.cwd().readFileAlloc(io, dest, a, .limited(1 << 20));
    try std.testing.expectEqualStrings(expected, written);
}

test "install - replacing a symlink is reported, replacing a regular file is not" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const marker = "was a symlink";

    // Plain overwrite of a stale script: no note, because nothing about the
    // user's arrangement changed.
    {
        var home = try FakeHome.init(a);
        defer home.deinit();
        _ = try runInstall(a, &home, "zsh");
        const second = try runInstall(a, &home, "zsh");
        try std.testing.expect(!contains(second.out, marker));
        // Re-running is idempotent: the rename replaced the previous file.
        const dest = try installedPath(a, home.path, "zsh");
        const expected = try zsh.generate(a, app_name, &commands, &global_options);
        const written = try std.Io.Dir.cwd().readFileAlloc(io, dest, a, .limited(1 << 20));
        try std.testing.expectEqualStrings(expected, written);
    }

    // Replacing a symlink IS a change to the user's setup (a dotfiles link is a
    // plausible thing to find here), so it must be visible rather than silent.
    {
        var home = try FakeHome.init(a);
        defer home.deinit();
        try home.tmp.dir.writeFile(io, .{ .sub_path = "target.zsh", .data = "x" });
        const target = try std.fmt.allocPrint(a, "{s}/target.zsh", .{home.path});
        const dest = try installedPath(a, home.path, "zsh");
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(dest).?);
        try std.Io.Dir.cwd().symLink(io, target, dest, .{});

        const emitted = try runInstall(a, &home, "zsh");
        try std.testing.expect(contains(emitted.out, marker));
        try std.testing.expect(contains(emitted.out, dest));
    }
}

test "install - no HOME is an error, and nothing is written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var environ = try envWith(a, &.{});
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    var ctx: PluginCtx = .{
        .allocator = a,
        .io = io,
        .environ = &environ,
        .app_name = app_name,
        .command_info = &commands,
        .globals = &global_options,
        .out = &out.writer,
        .err = &err.writer,
    };
    try std.testing.expectError(error.HomeNotFound, install_cmd.execute(.{ .shell = "zsh" }, .{}, &ctx));
    try std.testing.expectEqualStrings("", out.written());
}

test "uninstall - removes the installed script and prints the disable steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var home = try FakeHome.init(a);
    defer home.deinit();

    _ = try runInstall(a, &home, "zsh");
    const dest = try installedPath(a, home.path, "zsh");
    // Present before.
    _ = try std.Io.Dir.cwd().statFile(io, dest, .{});

    const emitted = try runUninstall(a, &home, "zsh");
    try std.testing.expect(contains(emitted.out, "✓ Uninstalled"));
    try std.testing.expect(contains(emitted.out, dest));
    // The zsh disable instructions name the fpath line the enable step added —
    // built from the RESOLVED directory and shell-quoted, not a hard-coded ~.
    const fpath_line = try std.fmt.allocPrint(a, "fpath=('{s}' $fpath)", .{std.fs.path.dirname(dest).?});
    try std.testing.expect(contains(emitted.out, fpath_line));

    // Gone after.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, dest, .{}));
}

test "uninstall - a script that was never installed is reported, not an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var home = try FakeHome.init(a);
    defer home.deinit();

    const emitted = try runUninstall(a, &home, "fish");
    const dest = try installedPath(a, home.path, "fish");
    try std.testing.expect(contains(emitted.out, "Completions not installed at"));
    try std.testing.expect(contains(emitted.out, dest));
    // A missing file is the expected state, so the disable instructions (which
    // follow a real removal) must NOT be printed.
    try std.testing.expect(!contains(emitted.out, "✓ Uninstalled"));
    try std.testing.expectEqualStrings("", emitted.err);
}
