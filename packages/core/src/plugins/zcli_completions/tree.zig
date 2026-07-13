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

    /// A command with no children is a leaf (a runnable command); one with
    /// children is (at least) a command group.
    pub fn isLeaf(self: *const CommandNode) bool {
        return self.children.len == 0;
    }
};

/// True if any command in the tree declares a positional arg with a dynamic
/// completion hook (`complete == .hook`) — i.e. the generated script needs the
/// `__complete` callback helper wired in.
pub fn hasDynamicArg(node: *const CommandNode) bool {
    for (node.args) |arg| {
        if (arg.complete) |c| if (c == .hook) return true;
    }
    for (node.children) |child| if (hasDynamicArg(child)) return true;
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
        if (cmd.path.len == 0) continue;
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

    const grown = try arena.alloc(*CommandNode, parent.children.len + 1);
    @memcpy(grown[0..parent.children.len], parent.children);
    grown[parent.children.len] = child;
    parent.children = grown;
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
