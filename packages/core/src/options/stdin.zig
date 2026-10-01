//! Invocation input resolution. Parsing only records requests; this operation
//! consumes stdin once after lower-precedence configuration has been applied.
const std = @import("std");
const types = @import("types.zig");

pub const ResolveError = error{ MultipleStdinOptions, StdinTooLong, StdinReadFailed, OutOfMemory };
pub const default_max_bytes = 16 * 1024 * 1024;

/// Replace the requested scalar text field with the exact remaining input.
/// Returns an owned buffer (or null with no requests). The caller owns the
/// buffer for as long as options is used. Duplicate requests never consume input.
pub fn resolveStdin(
    comptime Options: type,
    options: *Options,
    requested: [types.optionFieldCount(Options)]bool,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_bytes: usize,
) ResolveError!?[]u8 {
    var count: usize = 0;
    for (requested) |is_requested| count += @intFromBool(is_requested);
    if (count > 1) return error.MultipleStdinOptions;
    if (count == 0) return null;

    const text = reader.allocRemaining(allocator, .limited(max_bytes +| 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.StdinTooLong,
        error.ReadFailed => return error.StdinReadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (text.len > max_bytes) {
        allocator.free(text);
        return error.StdinTooLong;
    }
    inline for (@typeInfo(Options).@"struct".fields, 0..) |field, index| {
        if (comptime field.type == []const u8 or field.type == ?[]const u8) {
            if (requested[index]) @field(options, field.name) = text;
        } else {
            // A request for this field is a framework invariant violation:
            // validateMeta rejects .stdin on non-text types before compilation.
            std.debug.assert(!requested[index]);
        }
    }
    return text;
}

test "resolution preserves exact bytes, including empty and final newlines" {
    const O = struct { text: ?[]const u8 = "-" };
    for ([_][]const u8{ "", "hello\n", "\x00\r\n-" }) |input| {
        var options: O = .{};
        var reader: std.Io.Reader = .fixed(input);
        const content = (try resolveStdin(O, &options, .{true}, std.testing.allocator, &reader, 100)).?;
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings(input, options.text.?);
    }
}

test "duplicates fail before consuming and absent requests leave stream alone" {
    const O = struct { a: []const u8 = "-", b: []const u8 = "-" };
    var options: O = .{};
    var reader: std.Io.Reader = .fixed("hello");
    try std.testing.expectError(error.MultipleStdinOptions, resolveStdin(O, &options, .{ true, true }, std.testing.allocator, &reader, 100));
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
    try std.testing.expectEqual(@as(?[]u8, null), try resolveStdin(O, &options, .{ false, false }, std.testing.allocator, &reader, 100));
    try std.testing.expectEqual(@as(usize, 0), reader.seek);
}

test "bounded read accepts limit and rejects overflow" {
    const O = struct { a: []const u8 = "-" };
    var options: O = .{};
    var reader: std.Io.Reader = .fixed("hello");
    try std.testing.expectError(error.StdinTooLong, resolveStdin(O, &options, .{true}, std.testing.allocator, &reader, 4));
    reader = .fixed("hello");
    const text = (try resolveStdin(O, &options, .{true}, std.testing.allocator, &reader, 5)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "zero limit accepts EOF and rejects one byte" {
    const O = struct { a: []const u8 = "-" };
    var options: O = .{};
    var reader: std.Io.Reader = .fixed("");
    const empty = (try resolveStdin(O, &options, .{true}, std.testing.allocator, &reader, 0)).?;
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
    reader = .fixed("x");
    try std.testing.expectError(error.StdinTooLong, resolveStdin(O, &options, .{true}, std.testing.allocator, &reader, 0));
}

test "read failure is distinct from invalid input" {
    const Failing = struct {
        fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            return error.ReadFailed;
        }
    };
    var reader: std.Io.Reader = .{ .vtable = &.{ .stream = Failing.stream }, .buffer = &.{}, .seek = 0, .end = 0 };
    const O = struct { text: []const u8 = "-" };
    var options: O = .{};
    try std.testing.expectError(error.StdinReadFailed, resolveStdin(O, &options, .{true}, std.testing.allocator, &reader, 100));
    try std.testing.expectEqualStrings("-", options.text);
}
