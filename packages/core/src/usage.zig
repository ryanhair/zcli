//! Shared usage/synopsis conventions for the help renderer and the doc
//! generator (markdown, man, HTML).
//!
//! There used to be four near-identical "classify a positional and bracket it"
//! loops — one per surface — that had quietly drifted apart: help used bare
//! uppercase `NAME`/`[NAME]`, markdown `<name>`/`[name]`/`name...`, man a bare
//! `\fIname\fR`, HTML `&lt;name&gt;`. This is the single source of truth for
//! *how a positional argument appears in a synopsis*, so all four surfaces
//! render the same clap-style convention:
//!
//!   - `<NAME>`   required
//!   - `[NAME]`   optional
//!   - `[NAME]...`variadic
//!
//! uppercase, in the order `app cmd [OPTIONS] <ARGS>`. Only the *classification*
//! and the *bracket convention* live here; per-format escaping (HTML entities,
//! roff font macros) stays in the caller, applied to the delimiters and name it
//! gets back.

const std = @import("std");

/// How a positional argument appears in a synopsis. Variadic wins over optional:
/// a repeated positional is always shown `[NAME]...`, regardless of whether the
/// zero-count case is allowed — the ellipsis already conveys "any number".
pub const ArgKind = enum { required, optional, variadic };

/// Classify a positional from the two facts every surface already carries about
/// it. `is_variadic` (the help renderer's `is_array` for a positional field)
/// takes precedence over `is_optional`.
pub fn classify(is_optional: bool, is_variadic: bool) ArgKind {
    if (is_variadic) return .variadic;
    if (is_optional) return .optional;
    return .required;
}

/// The literal opening/closing delimiters for a kind. A format that must escape
/// `<`/`>` (HTML) routes these through its own escaper — `esc.html("<")` →
/// `&lt;`, while `[`, `]`, and `]...` pass through unchanged — so even HTML
/// inherits the convention from here rather than hard-coding entities.
pub const Delims = struct { open: []const u8, close: []const u8 };

pub fn delims(kind: ArgKind) Delims {
    return switch (kind) {
        .required => .{ .open = "<", .close = ">" },
        .optional => .{ .open = "[", .close = "]" },
        .variadic => .{ .open = "[", .close = "]..." },
    };
}

/// Uppercase `name` (ASCII) into `buf`, returning the written prefix. A name
/// longer than `buf` is truncated rather than overflowed — synopsis names are
/// short identifiers, and truncation is a display-only concern, not a
/// correctness one (mirrors the help renderer's original stack-buffer guard).
pub fn upperInto(buf: []u8, name: []const u8) []u8 {
    const n = @min(name.len, buf.len);
    for (name[0..n], 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf[0..n];
}

// ============================================================================
// Tests
// ============================================================================

test "classify: variadic wins over optional, then optional, then required" {
    try std.testing.expectEqual(ArgKind.required, classify(false, false));
    try std.testing.expectEqual(ArgKind.optional, classify(true, false));
    try std.testing.expectEqual(ArgKind.variadic, classify(false, true));
    // A variadic that also allows zero is still shown as a plain variadic.
    try std.testing.expectEqual(ArgKind.variadic, classify(true, true));
}

test "delims: the clap-style bracket convention" {
    try std.testing.expectEqualStrings("<", delims(.required).open);
    try std.testing.expectEqualStrings(">", delims(.required).close);
    try std.testing.expectEqualStrings("[", delims(.optional).open);
    try std.testing.expectEqualStrings("]", delims(.optional).close);
    try std.testing.expectEqualStrings("[", delims(.variadic).open);
    try std.testing.expectEqualStrings("]...", delims(.variadic).close);
}

test "upperInto: uppercases and truncates to the buffer" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("NAME", upperInto(&buf, "name"));
    // A name longer than the buffer truncates instead of overflowing.
    try std.testing.expectEqualStrings("ABCDEFGH", upperInto(&buf, "abcdefghij"));
}

test "delims + upperInto compose into the shared token spelling" {
    var buf: [16]u8 = undefined;
    const upper = upperInto(&buf, "files");
    const d = delims(classify(true, true));
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{s}{s}{s}", .{ d.open, upper, d.close });
    try std.testing.expectEqualStrings("[FILES]...", out.written());
}
