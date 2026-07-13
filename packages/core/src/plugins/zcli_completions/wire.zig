//! The `__complete` output wire format (ADR-0026).
//!
//! Records are **NUL-framed**: the FIRST record is a directive token
//! (`default` / `also_files` / `also_dirs`); every record after it is a candidate
//! — `value` optionally followed by a tab and `description`. NUL is the delimiter
//! because candidate values are arbitrary runtime strings that may legally contain
//! spaces, globs, quotes, or newlines — only NUL cannot appear in one. A literal
//! tab inside a value (which would be read as the value/description separator) and
//! any stray NUL are scrubbed; everything else passes through verbatim so the
//! shell offers the exact string.

const std = @import("std");
const zcli = @import("zcli");

const Directive = zcli.completion.Directive;

fn directiveToken(d: Directive) []const u8 {
    return switch (d) {
        .default => "default",
        .also_files => "also_files",
        .also_dirs => "also_dirs",
    };
}

/// Write a completion `Result` to `writer`: the directive record first, then the
/// NUL-framed candidates. On an EMPTY partial the `also_*` directive is downgraded
/// to `default` — so a bare `<TAB>` in combine mode shows only the dynamic
/// candidates, not the entire CWD (the flood guard the static work established).
pub fn writeResult(writer: anytype, result: zcli.completion.Result, partial: []const u8) !void {
    const directive = if (partial.len == 0) Directive.default else result.directive;
    try writer.writeAll(directiveToken(directive));
    try writer.writeByte(0);
    try writeRecords(writer, result.candidates);
}

/// Write `candidates` as NUL-framed records to `writer` (no directive).
pub fn writeRecords(writer: anytype, candidates: []const zcli.completion.Candidate) !void {
    for (candidates) |c| {
        try writeScrubbed(writer, c.value, true);
        if (c.description) |d| {
            try writer.writeByte('\t');
            try writeScrubbed(writer, d, false);
        }
        try writer.writeByte(0);
    }
}

/// Emit `s` with the framing bytes removed: NUL is always dropped (it delimits
/// records); a tab is turned into a space in a value (it separates value from
/// description) but kept in a description.
fn writeScrubbed(writer: anytype, s: []const u8, comptime scrub_tab: bool) !void {
    for (s) |ch| {
        if (ch == 0) continue;
        if (scrub_tab and ch == '\t') {
            try writer.writeByte(' ');
            continue;
        }
        try writer.writeByte(ch);
    }
}

test "writeRecords - NUL frames each candidate, tab separates description" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRecords(&aw.writer, &.{
        .{ .value = "1", .description = "Write the parser" },
        .{ .value = "2" },
    });
    try std.testing.expectEqualStrings("1\tWrite the parser\x002\x00", aw.written());
}

test "writeRecords - preserves spaces, globs, quotes, dollars, leading dash, newline" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    // The value/description separator and framing must not corrupt these.
    try writeRecords(&aw.writer, &.{
        .{ .value = "a b c" },
        .{ .value = "-wip" },
        .{ .value = "x*y?" },
        .{ .value = "it's \"$HOME\"" },
        .{ .value = "line1\nline2" },
    });
    try std.testing.expectEqualStrings(
        "a b c\x00-wip\x00x*y?\x00it's \"$HOME\"\x00line1\nline2\x00",
        aw.written(),
    );
}

test "writeRecords - scrubs a tab inside a value but keeps it in a description" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRecords(&aw.writer, &.{.{ .value = "a\tb", .description = "d1\td2" }});
    // value tab -> space; description tab preserved.
    try std.testing.expectEqualStrings("a b\td1\td2\x00", aw.written());
}

test "writeRecords - drops a stray NUL in a value" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRecords(&aw.writer, &.{.{ .value = "a\x00b" }});
    try std.testing.expectEqualStrings("ab\x00", aw.written());
}

test "writeResult - directive record precedes the candidates" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeResult(&aw.writer, .{ .candidates = &.{.{ .value = "x" }}, .directive = .also_files }, "p");
    try std.testing.expectEqualStrings("also_files\x00x\x00", aw.written());
}

test "writeResult - empty partial downgrades also_* to default (flood guard)" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeResult(&aw.writer, .{ .candidates = &.{.{ .value = "x" }}, .directive = .also_files }, "");
    try std.testing.expectEqualStrings("default\x00x\x00", aw.written());
}

test "writeResult - default directive with no candidates is just the directive" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeResult(&aw.writer, .{}, "p");
    try std.testing.expectEqualStrings("default\x00", aw.written());
}
