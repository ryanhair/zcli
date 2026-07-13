//! Custom parse types (ADR-0024, increment 2).
//!
//! A field type is *custom-parsed* when — after unwrapping one optional level —
//! it is a struct declaring `pub fn parse(s: []const u8) E!@This()`. The field
//! then holds the user's own domain type (a `Duration`, `Port`, `Email`), built
//! from the argument string by its own `parse`, which validates as it constructs.
//!
//! Optional companions on the type:
//!   - `pub const hint: []const u8` — the "Expected …" phrase / help placeholder.
//!   - `pub fn describe(err) []const u8` — a humane message per failure variant.
//!
//! Every value source (CLI, env, config) constructs the type the same way, so the
//! parse sites and the config deserializer all route through `parse`. A parse
//! failure is reported as an ordinary invalid-value error (reusing the #206
//! `OptionInvalidValue`/`ArgumentInvalidValue` diagnostics), showing `describe`'s
//! reason when present, else the hint.

const std = @import("std");

/// One optional level removed; identity otherwise. The value a `parse` produces
/// and a `validate` hook sees.
pub fn Base(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Whether `T` (or its optional child) is a struct declaring `pub fn parse`.
/// Kept lenient — the exact signature is checked by `assertValidParse` at the
/// parse site so a mistake is a clear message, not a cryptic call error.
pub fn isCustomParsed(comptime T: type) bool {
    const B = Base(T);
    return switch (@typeInfo(B)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(B, "parse"),
        else => false,
    };
}

/// Comptime contract check for a custom-parse type, with friendly errors.
pub fn assertValidParse(comptime T: type) void {
    const B = Base(T);
    const name = @typeName(B);
    const info = @typeInfo(@TypeOf(B.parse));
    if (info != .@"fn") @compileError("`" ++ name ++ ".parse` must be a function `fn(s: []const u8) !" ++ name ++ "`");
    const f = info.@"fn";
    if (f.params.len != 1 or (f.params[0].type orelse void) != []const u8)
        @compileError("`" ++ name ++ ".parse` must take a single `[]const u8`, e.g. `fn(s: []const u8) !" ++ name ++ "`");
    const ret = f.return_type orelse @compileError("`" ++ name ++ ".parse` must return `!" ++ name ++ "`");
    const ret_info = @typeInfo(ret);
    if (ret_info != .error_union or ret_info.error_union.payload != B)
        @compileError("`" ++ name ++ ".parse` must return an error union yielding `" ++ name ++ "` (e.g. `error{ … }!" ++ name ++ "`)");
}

/// The "Expected …" phrase for a custom type: its `pub const hint` if declared,
/// else the bare type name.
pub fn hintFor(comptime T: type) []const u8 {
    const B = Base(T);
    if (@hasDecl(B, "hint")) return B.hint;
    return @typeName(B);
}

/// On the error path, the humane reason for why `value` failed to parse as the
/// custom type — from `pub fn describe` if declared, else null (the caller then
/// falls back to the hint). Re-parses to recover the typed error; `parse` is a
/// pure string→value function, so this is deterministic and only runs on failure.
pub fn describeError(comptime T: type, value: []const u8) ?[]const u8 {
    const B = Base(T);
    if (comptime isCustomParsed(T) and @hasDecl(B, "describe")) {
        _ = B.parse(value) catch |e| return B.describe(e);
    }
    return null;
}

test "isCustomParsed detects a struct with parse, through optionals" {
    const Port = struct {
        value: u16,
        pub fn parse(s: []const u8) error{Bad}!@This() {
            return .{ .value = std.fmt.parseInt(u16, s, 10) catch return error.Bad };
        }
    };
    try std.testing.expect(isCustomParsed(Port));
    try std.testing.expect(isCustomParsed(?Port));
    try std.testing.expect(!isCustomParsed(u16));
    try std.testing.expect(!isCustomParsed([]const u8));
    try std.testing.expect(!isCustomParsed(struct { x: u8 }));
}

test "hintFor prefers a declared hint" {
    const WithHint = struct {
        v: u8,
        pub const hint = "a small number";
        pub fn parse(s: []const u8) error{Bad}!@This() {
            return .{ .v = std.fmt.parseInt(u8, s, 10) catch return error.Bad };
        }
    };
    try std.testing.expectEqualStrings("a small number", hintFor(WithHint));
    try std.testing.expectEqualStrings("a small number", hintFor(?WithHint));
}

test "describeError maps the failure variant when describe is present" {
    const Dur = struct {
        secs: u64,
        pub fn parse(s: []const u8) error{ Empty, Bad }!@This() {
            if (s.len == 0) return error.Empty;
            return .{ .secs = std.fmt.parseInt(u64, s, 10) catch return error.Bad };
        }
        pub fn describe(err: error{ Empty, Bad }) []const u8 {
            return switch (err) {
                error.Empty => "must not be empty",
                error.Bad => "expected a whole number of seconds",
            };
        }
    };
    try std.testing.expectEqualStrings("expected a whole number of seconds", describeError(Dur, "xyz").?);
    try std.testing.expect(describeError(Dur, "10") == null); // parses fine → no reason
}
