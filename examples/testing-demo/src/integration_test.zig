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

    // The first arg is the command name — `greeter greet world`, exactly as a
    // user would type it (runSubprocess supplies the binary as argv[0]).
    var result = try testing.runSubprocess(allocator, io, exe_path, &.{ "greet", "world" }, .{});
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "Hello, world!");
    try testing.expectStderrEmpty(result);
}

test "greet --loud shouts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var result = try testing.runSubprocess(allocator, io, exe_path, &.{ "greet", "world", "--loud" }, .{});
    defer result.deinit();

    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "HELLO, WORLD!");
}

test "an unrecognized flag is reported misuse (exit code 2)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var result = try testing.runSubprocess(allocator, io, exe_path, &.{ "greet", "world", "--bogus" }, .{});
    defer result.deinit();

    // See DESIGN.md's exit-code table: 2 is reserved for CLI misuse (unknown
    // options, bad values, missing arguments), distinct from 1 (a command's own
    // `context.fail()`) and 3 (command not found).
    try testing.expectExitCode(result, 2);
}

test "greet output matches a golden snapshot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var result = try testing.runSubprocess(allocator, io, exe_path, &.{ "greet", "snapshot-friend" }, .{});
    defer result.deinit();

    // Compares against the golden checked in at
    // `tests/snapshots/integration_test/greet-output.txt`. If `greet`'s output
    // ever changes on purpose, regenerate it with `.update = true` (typically
    // threaded from a build option, e.g. `zig build test -Dupdate-snapshots`)
    // and review the diff like any other file.
    try testing.expectSnapshot(allocator, io, std.Io.Dir.cwd(), result.stdout, @src(), "greet-output", .{});
}

// ---------------------------------------------------------------------------
// Output-integrity tier: what the exit status says when a standard stream
// cannot be written at all (#731 / #740). These need a *closed* descriptor,
// which `runSubprocess` cannot express — it always pipes both streams — so
// they spawn directly with `StdIo.close`, the harness equivalent of the shell's
// `>&-` / `2>&-`: the child is started with that descriptor missing and its
// writes fail, exactly as they do under the redirection.
// ---------------------------------------------------------------------------

const ClosedStream = enum { stdout, stderr };

/// Spawn `greeter` with one standard stream closed and the other piped.
/// Returns the child's exit status and whatever the open stream produced
/// (caller frees).
fn runWithClosedStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    closed: ClosedStream,
    args: []const []const u8,
) !struct { exit_code: u8, other: []u8 } {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, args);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = if (closed == .stdout) .close else .pipe,
        .stderr = if (closed == .stderr) .close else .pipe,
    });

    // Exactly one stream is a pipe here, so draining it to EOF cannot deadlock
    // against an un-drained sibling — the hazard that makes `runSubprocess`
    // drain both concurrently does not arise.
    const open_stream = if (closed == .stdout) child.stderr.? else child.stdout.?;
    var buf: [4096]u8 = undefined;
    var reader = open_stream.reader(io, &buf);
    const captured = reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch |err| {
        _ = child.wait(io) catch {};
        return err;
    };
    errdefer allocator.free(captured);

    const term = testing.Termination.fromChild(try child.wait(io));
    return .{ .exit_code = term.exitCode(), .other = captured };
}

test "output that cannot be written exits non-zero, not a silent success" {
    // A closed standard descriptor is a POSIX shell situation (`>&-`); Windows
    // has no equivalent spelling and the contract under test is the shell one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Regression for #731: `greeter greet world >&-`. "Hello, world!\n" is 14
    // bytes — far under the 4096-byte stdout buffer — so nothing reaches the
    // descriptor until the framework's final flush, and that flush is the only
    // write that can fail. Its error used to be swallowed outright, so the
    // process exited **0** having written nothing at all: `myapp gen-manifest
    // > /mnt/full/manifest.json && deploy` reported success and deployed an
    // empty manifest.
    const r = try runWithClosedStream(allocator, io, .stdout, &.{ "greet", "world" });
    defer allocator.free(r.other);

    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    // And it says so, rather than failing mutely. The prefix is
    // framework-authored (the errno name after it varies by platform).
    try testing.expectContains(r.other, "failed to write output");
}

test "a misuse diagnostic that cannot be written still exits 2" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Regression for #740: `greeter greet world --bogus 2>&-`. The diagnostic
    // is under 4 KB, so the only write that reaches the descriptor is
    // `reportParseError`'s trailing flush; while that was a `try`, its
    // `error.WriteFailed` replaced `error.OptionUnknown` and the misuse status
    // degraded from 2 to 1. Scripts key on 2 to tell "you used it wrong" apart
    // from "it failed" (see the exit-code table test above).
    //
    // This is also the precedence test, and the reason it uses stderr rather
    // than stdout: the failed flush genuinely records a write error on the
    // stderr writer, so at the moment `run()` decides, *both* a classified
    // parse error and lost output are true at once. Exit 2 is the assertion
    // that the classification outranks the lost write. (Closing stdout here
    // would prove nothing — a parse error never writes to stdout, so there
    // would be no buffered bytes to fail on and nothing to outrank.)
    const closed_stderr = try runWithClosedStream(allocator, io, .stderr, &.{ "greet", "world", "--bogus" });
    defer allocator.free(closed_stderr.other);
    try std.testing.expectEqual(@as(u8, 2), closed_stderr.exit_code);
    // Nothing leaked onto stdout in the process.
    try std.testing.expectEqualStrings("", closed_stderr.other);
}
