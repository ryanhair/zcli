//! `@file` response-file argument expansion.
//!
//! Many CLIs (Cobra, clap-rs, GCC/clang, .NET) let you replace a long or
//! awkward argument list with `myapp @args.txt`, where the `@file` token is
//! substituted by arguments read from a file. This is handy for very long
//! invocations and for working around OS `argv` length limits.
//!
//! Expansion happens exactly once, at the very front of parsing (before global
//! options, arg transforms, and command routing), so a response file may
//! contribute the command name, options, and positionals alike.
//!
//! Semantics (see `expandArgs`):
//!   * A token `@PATH` (leading `@`, length > 1) is replaced by the arguments
//!     read from the file at PATH: one argument per line. Blank lines and lines
//!     whose first non-blank character is `#` are skipped; leading/trailing
//!     whitespace is trimmed. A line's remaining text is one argument verbatim —
//!     internal spaces stay part of that single argument.
//!   * Expansion is **single-level by construction**: arguments pulled from a
//!     response file are never rescanned for `@file`, so a `@`-prefixed line is
//!     a literal argument (e.g. an `@scope/pkg` name or an `@handle`) and
//!     recursion is impossible. This is the guard against runaway/nested
//!     expansion — there is nothing to depth-limit because the second level
//!     never exists.
//!   * `--` stops expansion: the `--` token and everything after it are copied
//!     through verbatim, so a literal `@value` argument can still be passed
//!     after `--`.
//!   * A bare `@` (no path) is a literal argument.
//!
//! A missing or unreadable response file is a reported CLI misuse error
//! (`error.ResponseFileUnreadable`, exit code 2 at the registry front).

const std = @import("std");

/// Errors specific to response-file expansion. `error.ResponseFileUnreadable`
/// is treated as a reported CLI misuse error by the registry entry point.
pub const Error = error{ResponseFileUnreadable};

/// Upper bound on the bytes read from a single response file. Generous enough
/// for any realistic argument list while bounding memory from a pathological or
/// hostile path.
pub const max_file_bytes: usize = 1 << 20; // 1 MiB

/// Filled on failure so the caller can name the offending file in its message.
pub const Diagnostic = struct {
    /// The response-file path that could not be read (the token after `@`).
    path: []const u8,
};

/// Expand `@file` response-file tokens in `argv`.
///
/// When `argv` contains no expandable token this returns `argv` itself — no
/// allocation, and every argument keeps its original (caller-owned) lifetime.
/// This matters: plugins and diagnostics may hold argv slices beyond the parse,
/// so pass-through tokens must never be moved into shorter-lived memory.
///
/// When expansion does occur, the returned outer slice and the file-derived
/// argument strings are allocated from `allocator`; pass-through tokens are
/// still borrowed from `argv` unchanged. The mixed ownership is intended for
/// an arena (the registry's per-command arena) — free by discarding the arena,
/// not element-by-element.
///
/// `dir` is the directory `@PATH` is resolved against (normally
/// `std.Io.Dir.cwd()`); `io` threads file I/O. On a missing/unreadable file,
/// sets `diag` and returns `error.ResponseFileUnreadable`.
pub fn expandArgs(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    argv: []const []const u8,
    diag: *?Diagnostic,
) ![]const []const u8 {
    // Fast path: leave argv untouched when there is nothing to expand.
    if (!hasExpandableToken(argv)) return argv;

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    var passthrough = false;
    for (argv) |arg| {
        if (!passthrough) {
            // Everything from `--` onward is literal — including a `@value`
            // a command legitimately wants to receive.
            if (std.mem.eql(u8, arg, "--")) {
                passthrough = true;
            } else if (isResponseToken(arg)) {
                const path = arg[1..];
                const content = dir.readFileAlloc(io, path, allocator, .limited(max_file_bytes)) catch {
                    diag.* = .{ .path = path };
                    return Error.ResponseFileUnreadable;
                };
                // Not freed: the file-derived argument slices point into it
                // (arena-owned, reclaimed with everything else).
                try appendFileArgs(allocator, &out, content);
                continue;
            }
        }
        // A plain argument (or a bare `@`, or anything after `--`): borrowed
        // from argv verbatim, keeping its original lifetime.
        try out.append(allocator, arg);
    }

    return out.toOwnedSlice(allocator);
}

/// Whether `arg` is a `@PATH` response-file reference (leading `@`, non-empty
/// path). A bare `@` is a literal argument.
fn isResponseToken(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '@';
}

/// Whether any token before a `--` terminator is a `@PATH` reference — i.e.
/// whether `expandArgs` has any work to do.
fn hasExpandableToken(argv: []const []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--")) return false;
        if (isResponseToken(arg)) return true;
    }
    return false;
}

/// Parse one response file's `content` into arguments and append them to `out`.
/// One argument per line; blank lines and `#` comment lines skipped; each line
/// trimmed. Lines are taken verbatim (never rescanned for `@file`) and the
/// appended slices point into `content`.
fn appendFileArgs(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), content: []const u8) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        // Tolerate CRLF line endings.
        const unterminated = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        const line = std.mem.trim(u8, unterminated, " \t");
        if (line.len == 0) continue; // blank line
        if (line[0] == '#') continue; // comment
        try out.append(allocator, line);
    }
}

// ---------------------------------------------------------------------------
// Tests
//
// expandArgs allocates arena-style (mixed borrowed/owned elements), so each
// test that can expand wraps testing.allocator in an ArenaAllocator.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "expandArgs: no @file tokens returns argv itself, untouched" {
    var diag: ?Diagnostic = null;
    const argv = [_][]const u8{ "users", "list", "--json" };
    const out = try expandArgs(testing.allocator, testing.io, std.Io.Dir.cwd(), &argv, &diag);
    // The fast path: the very same slice, no allocation, original lifetimes.
    try testing.expectEqual(@as([]const []const u8, &argv), out);
    try testing.expect(diag == null);
}

test "expandArgs: reads args from a file (one per line, comments and blanks skipped)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "args.txt", .data =
        \\# a comment
        \\--name
        \\Ada Lovelace
        \\
        \\--count
        \\3
        \\
    });

    var diag: ?Diagnostic = null;
    const argv = [_][]const u8{ "create", "@args.txt", "trailing" };
    const out = try expandArgs(arena.allocator(), testing.io, tmp.dir, &argv, &diag);

    // "create", then the four file args, then "trailing".
    try testing.expectEqual(@as(usize, 6), out.len);
    try testing.expectEqualStrings("create", out[0]);
    try testing.expectEqualStrings("--name", out[1]);
    // A whole line is one argument — internal spaces preserved.
    try testing.expectEqualStrings("Ada Lovelace", out[2]);
    try testing.expectEqualStrings("--count", out[3]);
    try testing.expectEqualStrings("3", out[4]);
    try testing.expectEqualStrings("trailing", out[5]);
    // Pass-through tokens are borrowed from argv (original lifetime kept).
    try testing.expectEqual(argv[0].ptr, out[0].ptr);
    try testing.expectEqual(argv[2].ptr, out[5].ptr);
}

test "expandArgs: -- stops expansion and passes a literal @value through" {
    var diag: ?Diagnostic = null;
    const argv = [_][]const u8{ "run", "--", "@notafile", "plain" };
    const out = try expandArgs(testing.allocator, testing.io, std.Io.Dir.cwd(), &argv, &diag);

    // Nothing expandable before `--` → argv itself, verbatim.
    try testing.expectEqual(@as([]const []const u8, &argv), out);
    try testing.expect(diag == null);
}

test "expandArgs: -- stops expansion even when a @file was expanded before it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pre.txt", .data = "--verbose\n" });

    var diag: ?Diagnostic = null;
    const argv = [_][]const u8{ "run", "@pre.txt", "--", "@notafile" };
    const out = try expandArgs(arena.allocator(), testing.io, tmp.dir, &argv, &diag);

    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqualStrings("run", out[0]);
    try testing.expectEqualStrings("--verbose", out[1]);
    try testing.expectEqualStrings("--", out[2]);
    try testing.expectEqualStrings("@notafile", out[3]);
}

test "expandArgs: expansion is single-level (a @ line in a file is literal, not recursed)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The referenced file names another file — which must NOT be expanded.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "inner.txt", .data = "should-not-be-read\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outer.txt", .data = "@inner.txt\n@scope/pkg\n" });

    var diag: ?Diagnostic = null;
    const argv = [_][]const u8{"@outer.txt"};
    const out = try expandArgs(arena.allocator(), testing.io, tmp.dir, &argv, &diag);

    try testing.expectEqual(@as(usize, 2), out.len);
    // Both @-prefixed lines are literal arguments, never treated as @file refs.
    try testing.expectEqualStrings("@inner.txt", out[0]);
    try testing.expectEqualStrings("@scope/pkg", out[1]);
    try testing.expect(diag == null);
}

test "expandArgs: a bare @ is a literal argument" {
    var diag: ?Diagnostic = null;
    const argv = [_][]const u8{ "cmd", "@" };
    const out = try expandArgs(testing.allocator, testing.io, std.Io.Dir.cwd(), &argv, &diag);
    // Not expandable → the fast path returns argv itself.
    try testing.expectEqual(@as([]const []const u8, &argv), out);
}

test "expandArgs: a missing response file is a reported error naming the path" {
    var diag: ?Diagnostic = null;
    const argv = [_][]const u8{ "cmd", "@does-not-exist.txt" };
    try testing.expectError(Error.ResponseFileUnreadable, expandArgs(testing.allocator, testing.io, std.Io.Dir.cwd(), &argv, &diag));
    try testing.expect(diag != null);
    try testing.expectEqualStrings("does-not-exist.txt", diag.?.path);
}

test "expandArgs into parseCommandLine: file-supplied options and positionals parse" {
    const command_parser = @import("command_parser.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "run.txt", .data =
        \\--verbose
        \\--count
        \\7
        \\input.txt
        \\
    });

    var diag: ?Diagnostic = null;
    const argv = [_][]const u8{"@run.txt"};
    const expanded = try expandArgs(allocator, testing.io, tmp.dir, &argv, &diag);

    const Args = struct { file: []const u8 };
    const Options = struct { verbose: bool = false, count: u32 = 1 };

    var parse_diag: ?command_parser.ZcliDiagnostic = null;
    const result = try command_parser.parseCommandLine(Args, Options, null, allocator, null, expanded, &parse_diag);
    defer result.deinit();

    try testing.expectEqualStrings("input.txt", result.args.file);
    try testing.expect(result.options.verbose);
    try testing.expectEqual(@as(u32, 7), result.options.count);
}
