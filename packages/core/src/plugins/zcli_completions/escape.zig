//! Per-shell string escapers for the completion generators.
//!
//! Every user-supplied string (command descriptions, option descriptions) that
//! is interpolated into a generated script MUST be routed through the matching
//! shell's escaper. Skipping this is exactly the bug that produced unterminated
//! quotes in fish output (see the "Edit a task's title" apostrophe).
//!
//! Each escaper returns an arena/allocator-owned string that is safe to place
//! *inside a single-quoted context* for that shell:
//!   - bash/fish: inside `'…'`
//!   - zsh:       inside a `'…'` completion spec, additionally backslash-escaping
//!                the `[](): ` metacharacters that zsh's `_describe`/`_arguments`
//!                specs treat specially.

const std = @import("std");

/// Escape for placement inside a bash single-quoted string `'…'`.
/// Single quotes are the only metacharacter: end the quote, emit an escaped
/// quote, reopen — the classic `'\''` dance.
pub fn bash(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Escape for placement inside a fish single-quoted string `'…'`.
/// Fish only special-cases `\` and `'` inside single quotes, and — unlike POSIX
/// shells — allows `\'` and `\\` escapes directly within them.
pub fn fish(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '\'' => try out.appendSlice(allocator, "\\'"),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Escape for placement inside a zsh `'…'` completion spec. Beyond the `'\''`
/// single-quote dance, zsh completion specs use `[`, `]`, `(`, `)`, and `:` as
/// structural metacharacters (description brackets, action groups, spec field
/// separators), so those are backslash-escaped too.
pub fn zsh(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '\'' => try out.appendSlice(allocator, "'\\''"),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '[', ']', '(', ')', ':' => {
                try out.append(allocator, '\\');
                try out.append(allocator, c);
            },
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}
