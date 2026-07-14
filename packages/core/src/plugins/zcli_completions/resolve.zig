//! Cursor resolution for dynamic completion (ADR-0026).
//!
//! Given the shell's word array (`word[0]` = app name) and the cursor word index
//! (COMP_CWORD-style), work out which command the cursor is inside, how many
//! positional slots precede it, and therefore which field's completion applies.
//!
//! This is a *parsing* problem, not a token count: to know that the cursor in
//! `deploy --host x <TAB>` sits on positional slot 0 (not slot 1, and not the
//! value of `--host`), we must know `--host` takes a value and consumed `x`. That
//! arity knowledge is read at runtime from the current command's `OptionInfo`
//! (`takes_value`, `name`, `short`) plus the global options — no comptime
//! `OptionsType` needed. `--` end-of-options, `--flag=value`, single short
//! `-x value`, clustered `-xyz` booleans, and negative-number-is-not-a-flag are
//! all handled so the positional count stays correct.
//!
//! Increment 1 resolves *positional* slots. Option-value completion (`--host
//! <TAB>`) uses this same walk — the arity handling already classifies it — and is
//! wired in increment 2.

const std = @import("std");
const zcli = @import("zcli");

pub const Match = struct {
    /// The completion source for the field the cursor is on.
    spec: zcli.completion.Spec,
    /// Positional tokens entered for the command so far (options stripped), for
    /// `completion.Request.args`. Allocator-owned.
    positionals: []const []const u8,
    /// The word being completed (slice into `words`, or empty).
    partial: []const u8,
};

const max_depth = 64;

/// Resolve the field the cursor is on, or `null` when nothing dynamic applies
/// (no command match, cursor on a command name, no field/hook at that slot).
/// `commands` is the full introspected command list (user + plugin);
/// `global_options` are the app-level options valid before/around any command.
pub fn resolve(
    allocator: std.mem.Allocator,
    commands: []const zcli.CommandInfo,
    global_options: []const zcli.OptionInfo,
    words: []const []const u8,
    cword: usize,
) !?Match {
    if (words.len == 0) return null;

    const partial: []const u8 = if (cword < words.len) words[cword] else "";

    // Command segments matched so far (empty = root). Used to look up the current
    // command's options for arity as the walk descends.
    var matched: [max_depth][]const u8 = undefined;
    var matched_len: usize = 0;

    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(allocator);

    // Set when the cursor is the separately-typed value of a value-taking option
    // (`--host <TAB>`): the option whose value we're completing.
    var option_at_cursor: ?[]const u8 = null;

    var end_of_options = false;
    var i: usize = 1; // skip word[0] (app name)
    while (i < cword and i < words.len) {
        const tok = words[i];

        if (!end_of_options and std.mem.eql(u8, tok, "--")) {
            end_of_options = true;
            i += 1;
            continue;
        }

        if (!end_of_options and isOption(tok)) {
            // `--flag=value` is self-contained: consumes only this token.
            if (std.mem.startsWith(u8, tok, "--") and std.mem.indexOfScalar(u8, tok, '=') != null) {
                i += 1;
                continue;
            }
            const cmd_options = optionsOfPath(commands, matched[0..matched_len]);
            if (optionTakesSeparateValue(tok, global_options, cmd_options)) {
                // The value is the next token. If that next token IS the cursor,
                // the cursor is this option's value — resolve to it.
                if (i + 1 == cword) {
                    option_at_cursor = tok;
                    break;
                }
                i += 2;
            } else {
                i += 1;
            }
            continue;
        }

        // A bare token: extend the command path if it names a deeper command and no
        // positional has been consumed yet; otherwise it is a positional.
        if (positionals.items.len == 0 and matched_len < max_depth and
            extendsCommand(commands, matched[0..matched_len], tok))
        {
            matched[matched_len] = tok;
            matched_len += 1;
        } else {
            try positionals.append(allocator, tok);
        }
        i += 1;
    }

    const cmd_options = optionsOfPath(commands, matched[0..matched_len]);

    // Option value, separated form: `--host <TAB>`.
    if (option_at_cursor) |opt_tok| {
        const spec = optionSpecFor(opt_tok, global_options, cmd_options) orelse return null;
        return .{ .spec = spec, .positionals = try positionals.toOwnedSlice(allocator), .partial = partial };
    }

    // Option value, joined form: the cursor token itself is `--host=partial`.
    if (!end_of_options and std.mem.startsWith(u8, partial, "--")) {
        if (std.mem.indexOfScalar(u8, partial, '=')) |eq| {
            const spec = optionSpecFor(partial[0..eq], global_options, cmd_options) orelse return null;
            return .{ .spec = spec, .positionals = try positionals.toOwnedSlice(allocator), .partial = partial[eq + 1 ..] };
        }
    }

    const cmd = commandOfPath(commands, matched[0..matched_len]) orelse return null;

    // The cursor sits on positional slot `positionals.items.len`.
    const arg = argForSlot(cmd.args, positionals.items.len) orelse return null;
    const spec = arg.complete orelse return null;

    return .{
        .spec = spec,
        .positionals = try positionals.toOwnedSlice(allocator),
        .partial = partial,
    };
}

/// The completion `Spec` of the option named by `tok` (a `--long` or `-x` flag,
/// optionally with a trailing `=`), looked up in the command's options then the
/// globals, or null when unknown / no completion declared.
fn optionSpecFor(
    tok: []const u8,
    global_options: []const zcli.OptionInfo,
    cmd_options: []const zcli.OptionInfo,
) ?zcli.completion.Spec {
    if (std.mem.startsWith(u8, tok, "--")) {
        const name = tok[2..];
        if (lookupLong(cmd_options, name)) |o| return o.complete;
        if (lookupLong(global_options, name)) |o| return o.complete;
        return null;
    }
    if (tok.len == 2 and tok[0] == '-') {
        const ch = tok[1];
        if (lookupShort(cmd_options, ch)) |o| return o.complete;
        if (lookupShort(global_options, ch)) |o| return o.complete;
    }
    return null;
}

/// True when `tok` is an option flag (starts with `-`, is not `-` alone, and is
/// not a negative number).
fn isOption(tok: []const u8) bool {
    if (tok.len < 2) return false;
    if (tok[0] != '-') return false;
    if (zcli.isNegativeNumber(tok)) return false;
    return true;
}

/// Whether `tok` (a `--long` or `-x` flag, no `=`) consumes the following token as
/// its value, per the option's `takes_value`. Unknown options are treated as
/// booleans (consume nothing) — a conservative default that keeps the positional
/// count stable for flags the app doesn't declare.
fn optionTakesSeparateValue(
    tok: []const u8,
    global_options: []const zcli.OptionInfo,
    cmd_options: []const zcli.OptionInfo,
) bool {
    if (std.mem.startsWith(u8, tok, "--")) {
        const name = tok[2..];
        if (std.mem.startsWith(u8, name, "no-")) return false; // negation is boolean
        if (lookupLong(global_options, name)) |o| return o.takes_value;
        if (lookupLong(cmd_options, name)) |o| return o.takes_value;
        return false;
    }
    // Short form. A single `-x` may take a value; a cluster `-xyz` is booleans.
    if (tok.len != 2) return false;
    const ch = tok[1];
    if (lookupShort(global_options, ch)) |o| return o.takes_value;
    if (lookupShort(cmd_options, ch)) |o| return o.takes_value;
    return false;
}

fn lookupLong(options: []const zcli.OptionInfo, name: []const u8) ?zcli.OptionInfo {
    for (options) |o| if (std.mem.eql(u8, o.name, name)) return o;
    return null;
}

fn lookupShort(options: []const zcli.OptionInfo, ch: u8) ?zcli.OptionInfo {
    for (options) |o| {
        if (o.short) |s| if (s == ch) return o;
    }
    return null;
}

/// True when some command's path is `prefix ++ [tok]` as a prefix — i.e. `tok`
/// names a deeper command/group at the current depth.
fn extendsCommand(commands: []const zcli.CommandInfo, prefix: []const []const u8, tok: []const u8) bool {
    for (commands) |c| {
        if (c.path.len <= prefix.len) continue;
        if (!std.mem.eql(u8, c.path[prefix.len], tok)) continue;
        var eq = true;
        for (prefix, 0..) |p, k| {
            if (!std.mem.eql(u8, p, c.path[k])) {
                eq = false;
                break;
            }
        }
        if (eq) return true;
    }
    return false;
}

/// The command whose path exactly equals `path`, or null (e.g. a pure group with
/// no CommandInfo entry of its own, or the root).
fn commandOfPath(commands: []const zcli.CommandInfo, path: []const []const u8) ?zcli.CommandInfo {
    if (path.len == 0) return null;
    for (commands) |c| {
        if (c.path.len != path.len) continue;
        var eq = true;
        for (c.path, 0..) |p, k| {
            if (!std.mem.eql(u8, p, path[k])) {
                eq = false;
                break;
            }
        }
        if (eq) return c;
    }
    return null;
}

/// The options declared on the command whose path exactly equals `path`, or empty
/// (root or a group without its own entry).
fn optionsOfPath(commands: []const zcli.CommandInfo, path: []const []const u8) []const zcli.OptionInfo {
    const cmd = commandOfPath(commands, path) orelse return &.{};
    return cmd.options;
}

/// The `ArgInfo` for positional slot `slot`: the slot-th declared arg, or the
/// trailing variadic arg once the slots run out.
fn argForSlot(args: []const zcli.ArgInfo, slot: usize) ?zcli.ArgInfo {
    if (args.len == 0) return null;
    if (slot < args.len) return args[slot];
    const last = args[args.len - 1];
    return if (last.is_variadic) last else null;
}
