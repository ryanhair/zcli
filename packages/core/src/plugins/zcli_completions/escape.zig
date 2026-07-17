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
//!
//! Every escaper also space-collapses `\r` and `\n`: a literal newline is legal
//! inside a shell single-quoted string (it doesn't break the quoting), but it
//! splits a logical one-line completion entry — a `complete`/`_describe`/case
//! pattern line, or a `-s`/short-option token — across physical lines, which
//! corrupts the entry even though the script still parses. Descriptions (and any
//! other developer-controlled string) are collapsed to a single physical line
//! before being placed in the generated script.

const std = @import("std");

/// Escape for placement inside a bash single-quoted string `'…'`.
/// Single quotes are the only metacharacter: end the quote, emit an escaped
/// quote, reopen — the classic `'\''` dance. `\r`/`\n` are collapsed to a space
/// so multi-line input can't split a one-line entry across physical lines.
pub fn bash(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '\'' => try out.appendSlice(allocator, "'\\''"),
            '\r', '\n' => try out.append(allocator, ' '),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Escape for placement inside a fish single-quoted string `'…'`.
/// Fish only special-cases `\` and `'` inside single quotes, and — unlike POSIX
/// shells — allows `\'` and `\\` escapes directly within them. `\r`/`\n` are
/// collapsed to a space (see module doc).
pub fn fish(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '\'' => try out.appendSlice(allocator, "\\'"),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\r', '\n' => try out.append(allocator, ' '),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Escape for placement inside a PowerShell single-quoted string `'…'`.
/// PowerShell single-quoted strings are fully literal except for the single quote
/// itself, which is escaped by DOUBLING it (`''`) — the same rule for every
/// interpolated identifier the generator emits (command/option/enum names,
/// descriptions), so a pathological `@"a'b"` Zig identifier can never break out of
/// its quote. `\r`/`\n` are collapsed to a space (see module doc).
pub fn powershell(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '\'' => try out.appendSlice(allocator, "''"),
            '\r', '\n' => try out.append(allocator, ' '),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Escape for placement inside a zsh `'…'` completion spec. Beyond the `'\''`
/// single-quote dance, zsh completion specs use `[`, `]`, `(`, `)`, and `:` as
/// structural metacharacters (description brackets, action groups, spec field
/// separators), so those are backslash-escaped too. `\r`/`\n` are collapsed to a
/// space (see module doc).
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
            '\r', '\n' => try out.append(allocator, ' '),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}
