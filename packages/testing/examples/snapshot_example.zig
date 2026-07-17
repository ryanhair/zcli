//! Example: the **integration/snapshot tier** — `runSubprocess` and
//! `expectSnapshot`.
//!
//! This tier is std-only (no zcli/vterm). It has two jobs:
//!
//!   * `runSubprocess` runs a *compiled binary* and captures stdout/stderr/exit
//!     code, so you test the full stack: parsing, routing, plugin hooks, exit
//!     codes — the real thing, end to end.
//!   * `expectSnapshot` compares output against a golden file, with dynamic
//!     content (UUIDs, timestamps, addresses) masked so goldens don't churn.
//!     It also drives the update path (writing the golden) and the
//!     mismatch/missing error paths — kept noise-free here via
//!     `.report = false`, a first-class quiet switch on `SnapshotOptions`.
//!
//! `zig build examples` runs every `test` below. Because a package-test
//! environment has no CLI binary of its own to point `runSubprocess` at, the
//! subprocess examples drive small stock system tools (`echo`, `false`) — the
//! mechanics are identical to running `./zig-out/bin/myapp`.

const std = @import("std");
const testing = @import("zcli-testing");

// ---------------------------------------------------------------------------
// 1. runSubprocess + assertions.
// ---------------------------------------------------------------------------

test "runSubprocess captures stdout and exit code" {
    if (@import("builtin").os.tag == .windows) return; // `echo`/`false` are POSIX here

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // In a real suite the first arg is your built binary, e.g.
    // `"./zig-out/bin/myapp"`, and the slice is its CLI args. Here `echo hi`
    // stands in for that binary.
    var result = testing.runSubprocess(allocator, io, "/bin/echo", &.{"hi"}, .{}) catch |err| {
        // Spawning can be restricted in some sandboxes; skip rather than fail.
        std.log.warn("runSubprocess skipped: {any}", .{err});
        return;
    };
    defer result.deinit();

    // The assertion helpers give clear failure messages (they print the actual
    // output/exit code on mismatch when run outside `is_test`).
    try testing.expectExitCode(result, 0);
    try testing.expectContains(result.stdout, "hi");
    try testing.expectStderrEmpty(result);
}

test "runSubprocess sees a non-zero exit" {
    if (@import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // `/usr/bin/false` exits 1 and prints nothing.
    var result = testing.runSubprocess(allocator, io, "/usr/bin/false", &.{}, .{}) catch |err| {
        std.log.warn("runSubprocess skipped: {any}", .{err});
        return;
    };
    defer result.deinit();

    try testing.expectExitCodeNot(result, 0);
    try testing.expectStdoutEmpty(result);
}

// ---------------------------------------------------------------------------
// 2. Golden-file snapshots.
// ---------------------------------------------------------------------------

// A note on the two snapshot workflows:
//
//   * Compare (the default, `.{}`): read the golden, mask/strip, and assert it
//     matches. A mismatch returns error.SnapshotMismatch and prints a diff box;
//     a missing golden returns error.SnapshotMissing.
//   * Update (`.{ .update = true }`): WRITE the golden instead of comparing.
//     Thread this from a build option in a real project —
//     `zig build test -Dupdate-snapshots` — and it prints a confirmation line.
//
// The update, mismatch, and missing paths print human-facing diagnostics to
// stderr — exactly what you want when driving them by hand. But an *always-on*
// example that exercises the update path would spew that confirmation line into
// `zig build examples`, which trips the build runner into echoing a misleading
// `failed command: …` even though every test passed. So these examples pass
// `.report = false` on the paths they drive on purpose: a first-class quiet
// switch on `SnapshotOptions`. In your own project you'd leave it at the loud
// default and let the diagnostics guide you.

test "expectSnapshot round-trip: update writes the golden, compare then matches" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // `snapshot_root` is the directory that `tests/snapshots/<file>/<name>.txt`
    // is resolved against. A normal suite passes `std.Io.Dir.cwd()` so goldens
    // live in your repo and are reviewed in PRs. This example uses a throwaway
    // tmp dir so it stays self-contained and leaves no files behind.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // First run: `.update = true` WRITES the golden (masked form). This is the
    // real update workflow — no hand-seeding. `.report = false` keeps the
    // confirmation line out of the examples build; drop it in a real project.
    // `@src()` tells the harness which file this is (it derives the snapshot
    // subdirectory `snapshot_example` from the file name).
    const first = "user id=550e8400-e29b-41d4-a716-446655440000 created 2024-01-15T10:30:00Z";
    try testing.expectSnapshot(allocator, io, tmp.dir, first, @src(), "profile", .{ .update = true, .report = false });

    // Later run: a DIFFERENT UUID and timestamp still MATCHES against the golden
    // just written, because both are masked before comparison — only the stable
    // structure is asserted. A match prints nothing, so the loud default is fine.
    const later = "user id=00000000-1111-2222-3333-444444444444 created 2025-09-09T00:00:00Z";
    try testing.expectSnapshot(allocator, io, tmp.dir, later, @src(), "profile", .{});
}

test "SnapshotOptions.ansi=false compares only visible text" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // With `.ansi = false`, escape codes are stripped before comparison, so a
    // color change doesn't churn the golden — only the rendered text matters.
    // Write the golden from one colored string, then compare a differently-colored
    // string against it: still a match once both are stripped.
    try testing.expectSnapshot(allocator, io, tmp.dir, "\x1b[31mERROR\x1b[0m: nope", @src(), "message", .{ .ansi = false, .update = true, .report = false });
    try testing.expectSnapshot(allocator, io, tmp.dir, "\x1b[33mERROR\x1b[0m: nope", @src(), "message", .{ .ansi = false });
}

test "expectSnapshot compare path: mismatch and missing goldens error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Seed a golden via the update path, then feed a genuinely different value:
    // that's `error.SnapshotMismatch` (in a loud run it also prints a diff box).
    try testing.expectSnapshot(allocator, io, tmp.dir, "stable output", @src(), "diagnostics", .{ .update = true, .report = false });
    try std.testing.expectError(error.SnapshotMismatch, testing.expectSnapshot(allocator, io, tmp.dir, "changed output", @src(), "diagnostics", .{ .report = false }));

    // A golden that was never written is `error.SnapshotMissing`.
    try std.testing.expectError(error.SnapshotMissing, testing.expectSnapshot(allocator, io, tmp.dir, "anything", @src(), "never-written", .{ .report = false }));
}

// ---------------------------------------------------------------------------
// 3. The masking/stripping primitives, used directly.
// ---------------------------------------------------------------------------

test "maskDynamicContent and stripAnsi standalone" {
    const allocator = std.testing.allocator;

    const masked = try testing.maskDynamicContent(
        allocator,
        "id=550e8400-e29b-41d4-a716-446655440000 ptr=0x7fff5fbff8a0",
    );
    defer allocator.free(masked);
    try std.testing.expectEqualStrings("id=[UUID] ptr=[MEMORY_ADDR]", masked);

    const stripped = try testing.stripAnsi(allocator, "\x1b[1;32mOK\x1b[0m done");
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings("OK done", stripped);
}
