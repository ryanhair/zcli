//! Integration/snapshot tier (`zcli_testing`'s `runSubprocess` + `expectSnapshot`)
//! run against the actual compiled `greeter` binary — the full stack: parsing,
//! routing, and exit codes, not just `execute()` in isolation (see
//! `src/commands/greet.zig`'s unit-tier tests for that). `build.zig` wires this
//! file as its own test module (see the comment there) and makes its `Run`
//! step depend on the install step, so `./zig-out/bin/greeter` exists before
//! any test here runs.

const std = @import("std");
const builtin = @import("builtin");
const testing = @import("zcli-testing");

const exe_path = if (builtin.os.tag == .windows) "./zig-out/bin/greeter.exe" else "./zig-out/bin/greeter";

test "greet world prints a greeting and exits 0" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var result = try testing.runSubprocess(allocator, io, exe_path, &.{"world"});
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "Hello, world!");
    try testing.expectStderrEmpty(result);
}

test "greet --loud shouts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var result = try testing.runSubprocess(allocator, io, exe_path, &.{ "world", "--loud" });
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "HELLO, WORLD!");
}

test "an unrecognized flag is reported misuse (exit code 2)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var result = try testing.runSubprocess(allocator, io, exe_path, &.{ "world", "--bogus" });
    defer result.deinit();

    // See DESIGN.md's exit-code table: 2 is reserved for CLI misuse (unknown
    // options, bad values, missing arguments), distinct from 1 (a command's own
    // `context.fail()`) and 3 (command not found).
    try testing.expectExitCode(result, 2);
}

test "greet output matches a golden snapshot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var result = try testing.runSubprocess(allocator, io, exe_path, &.{"snapshot-friend"});
    defer result.deinit();

    // Compares against the golden checked in at
    // `tests/snapshots/integration_test/greet-output.txt`. If `greet`'s output
    // ever changes on purpose, regenerate it with `.update = true` (typically
    // threaded from a build option, e.g. `zig build test -Dupdate-snapshots`)
    // and review the diff like any other file.
    try testing.expectSnapshot(allocator, io, std.Io.Dir.cwd(), result.stdout, @src(), "greet-output", .{});
}
