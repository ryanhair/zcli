//! Shared command-tree model for the shell-completion generators.
//!
//! The three shell generators (bash/zsh/fish) all need the same thing: the flat
//! `[]const zcli.CommandInfo` list turned into a parent→children tree, with each
//! node carrying its options/args/aliases. Historically each generator rebuilt
//! this tree ad-hoc with duplicated (and buggy) bookkeeping. This module builds
//! it ONCE so every generator is a pure renderer over the same structure.
//!
//! Memory: the whole tree is allocated from a single arena passed to `build()`.
//! Callers own the arena and free it after rendering — nodes never need
//! individual cleanup.

const std = @import("std");
const zcli = @import("zcli");

/// One command in the tree. The root is a synthetic node with an empty `name`
/// and `depth == 0`; its children are the app's top-level commands.
pub const CommandNode = struct {
    /// This command's own name (last path segment). Empty for the synthetic root.
    name: []const u8 = "",
    /// Full command path from the app root (e.g. `["sprint", "list"]`). Empty for
    /// the synthetic root. 1-based depth is `path.len`.
    path: []const []const u8 = &.{},
    description: ?[]const u8 = null,
    /// Alternate names for this command (from `meta.aliases`).
    aliases: []const []const u8 = &.{},
    /// Options declared on this command (empty for pure command groups).
    options: []const zcli.OptionInfo = &.{},
    /// Positional args declared on this command.
    args: []const zcli.ArgInfo = &.{},
    /// Child commands, sorted by name for deterministic output.
    children: []const *CommandNode = &.{},
    /// Internal: full-capacity backing store for `children`, grown by doubling as
    /// children are appended. `children` is always `children_buf[0..children.len]`.
    /// Not part of the public tree shape — renderers use `children`.
    children_buf: []*CommandNode = &.{},

    /// A command with no children is a leaf (a runnable command); one with
    /// children is (at least) a command group.
    pub fn isLeaf(self: *const CommandNode) bool {
        return self.children.len == 0;
    }
};

fn specIsHook(spec: ?zcli.completion.Spec) bool {
    return if (spec) |c| c == .hook else false;
}

/// True if any command in the tree declares a positional arg OR an option with a
/// dynamic completion hook — i.e. the generated script needs the `__complete`
/// callback helper wired in.
pub fn hasDynamicHook(node: *const CommandNode) bool {
    for (node.args) |arg| if (specIsHook(arg.complete)) return true;
    for (node.options) |opt| if (specIsHook(opt.complete)) return true;
    for (node.children) |child| if (hasDynamicHook(child)) return true;
    return false;
}

/// True if any option in `options` has a dynamic completion hook (used for the
/// app-level global options, which live outside the command tree).
pub fn anyOptionHook(options: []const zcli.OptionInfo) bool {
    for (options) |opt| if (specIsHook(opt.complete)) return true;
    return false;
}

/// Build the command tree from the flat command-info list. Hidden commands are
/// dropped entirely. Intermediate path segments that have no CommandInfo of
/// their own (pure groups) still get a node so children are reachable.
///
/// All allocation is from `arena`; the returned root and everything reachable
/// from it live as long as the arena.
pub fn build(
    arena: std.mem.Allocator,
    commands: []const zcli.CommandInfo,
) !*CommandNode {
    const root = try arena.create(CommandNode);
    root.* = .{};

    for (commands) |cmd| {
        if (cmd.hidden) continue;
        // The empty path is the root group's index (ADR-0029): the app's own
        // command. Attach its metadata to the synthetic root so renderers
        // offer its options at the top level alongside command names.
        if (cmd.path.len == 0) {
            root.description = cmd.description;
            root.aliases = cmd.aliases;
            root.options = cmd.options;
            root.args = cmd.args;
            continue;
        }
        // Hiddenness propagates to descendants: a hidden group (e.g. a hidden
        // `secret/index.zig`) must also suppress its visible children, which
        // would otherwise materialise the intermediate node and offer the group
        // name in completions. Skip any command sitting under a hidden ancestor.
        if (hasHiddenAncestor(commands, cmd.path)) continue;
        // The registry emits each alias as its OWN command entry (so `app ls`
        // resolves) that still carries the module's `meta.aliases`. Such an
        // entry's leaf name equals one of its own aliases — a signal a real
        // command never has. Skip it: the canonical entry already contributes
        // the command node, and we surface aliases from there.
        if (isAliasEntry(cmd)) continue;

        // Walk/create the chain of nodes for this command's path.
        var node = root;
        for (cmd.path, 1..) |segment, depth| {
            node = try childNamed(arena, node, segment, cmd.path[0..depth]);
        }

        // The final node IS this command — attach its metadata.
        node.description = cmd.description;
        node.aliases = cmd.aliases;
        node.options = cmd.options;
        node.args = cmd.args;
    }

    sortRec(root);
    return root;
}

/// True if any hidden command in `commands` is a strict prefix (ancestor) of
/// `path` — i.e. `path` lives under a hidden group and should be suppressed.
fn hasHiddenAncestor(commands: []const zcli.CommandInfo, path: []const []const u8) bool {
    for (commands) |cmd| {
        if (!cmd.hidden) continue;
        if (cmd.path.len == 0 or cmd.path.len >= path.len) continue;
        var is_prefix = true;
        for (cmd.path, 0..) |segment, i| {
            if (!std.mem.eql(u8, segment, path[i])) {
                is_prefix = false;
                break;
            }
        }
        if (is_prefix) return true;
    }
    return false;
}

/// True when `cmd` is an auto-generated alias entry: its leaf (invoked name)
/// is listed among its own `aliases`. The canonical command entry has the real
/// name as its leaf, which is never one of its aliases.
fn isAliasEntry(cmd: zcli.CommandInfo) bool {
    const leaf = cmd.path[cmd.path.len - 1];
    for (cmd.aliases) |alias| {
        if (std.mem.eql(u8, alias, leaf)) return true;
    }
    return false;
}

/// Find the child of `parent` named `name`, creating it (with the given path
/// prefix) if absent. Used to lazily materialise intermediate group nodes.
fn childNamed(
    arena: std.mem.Allocator,
    parent: *CommandNode,
    name: []const u8,
    path: []const []const u8,
) !*CommandNode {
    for (parent.children) |child| {
        if (std.mem.eql(u8, child.name, name)) return child;
    }
    const child = try arena.create(CommandNode);
    child.* = .{ .name = name, .path = try arena.dupe([]const u8, path) };

    // Grow the backing store by doubling when full, so appending C children is
    // O(C) amortized instead of O(C²) (a fresh alloc + full copy per append) and
    // leaves only O(C) stale bytes resident in the arena rather than O(C²).
    if (parent.children.len == parent.children_buf.len) {
        const new_cap = if (parent.children_buf.len == 0) 4 else parent.children_buf.len * 2;
        const grown = try arena.alloc(*CommandNode, new_cap);
        @memcpy(grown[0..parent.children.len], parent.children);
        parent.children_buf = grown;
    }
    const n = parent.children.len;
    parent.children_buf[n] = child;
    parent.children = parent.children_buf[0 .. n + 1];
    return child;
}

fn lessByName(_: void, a: *CommandNode, b: *CommandNode) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn sortRec(node: *CommandNode) void {
    // children is `[]const *CommandNode`; sort needs a mutable slice. We built it
    // from a fresh arena alloc, so casting away const to sort in place is sound.
    const mutable: []*CommandNode = @constCast(node.children);
    std.mem.sort(*CommandNode, mutable, {}, lessByName);
    for (node.children) |child| sortRec(child);
}
