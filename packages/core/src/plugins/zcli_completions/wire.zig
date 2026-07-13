//! The `__complete` output wire format (ADR-0026).
//!
//! Records are **NUL-framed**: each candidate is `value` optionally followed by a
//! tab and `description`, then a NUL byte. NUL is the delimiter because candidate
//! values are arbitrary runtime strings that may legally contain spaces, globs,
//! quotes, or newlines — only NUL cannot appear in one. A literal tab inside a
//! value (which would be read as the value/description separator) and any stray
//! NUL are scrubbed; everything else passes through verbatim so the shell offers
//! the exact string.

const std = @import("std");
const zcli = @import("zcli");

/// Write `candidates` as NUL-framed records to `writer`.
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
