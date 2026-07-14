//! Example: the **E2E (PTY) tier** — `InteractiveScript` + `runInteractive`.
//!
//! This tier drives a binary through a real pseudo-terminal (or, optionally, a
//! plain pipe) so you can test genuinely interactive behavior: prompts, hidden
//! password input, control keys, signals, and TTY-dependent formatting. It ships
//! as its own module, `testing_e2e`, and feeds the terminal output through a
//! `vterm` so you can assert on the RENDERED screen, not just the raw stream.
//!
//! `zig build examples` runs the `test` blocks below. To stay hermetic they
//! drive `cat` — a stock tool that echoes stdin to stdout — instead of a project
//! binary; against your CLI the first element of the argv is your built binary,
//! e.g. `&.{ "./zig-out/bin/myapp", "login" }`.
//!
//! Platform notes:
//!   * The PTY path is POSIX-only. On a host without a working PTY it *degrades
//!     to a skip*, never a hard failure — CI greps for the skip marker so the
//!     tier can't go silently vacuous.
//!   * The pipe path (`allocate_pty = false`) needs no TTY and runs anywhere
//!     POSIX; it's the right default for CI assertions that don't need a real
//!     terminal.

const std = @import("std");
const builtin = @import("builtin");
const e2e = @import("testing_e2e");

// ---------------------------------------------------------------------------
// 1. Building a script — the fluent builder API (no process needed).
// ---------------------------------------------------------------------------

test "InteractiveScript builder records steps" {
    const allocator = std.testing.allocator;

    var script = e2e.InteractiveScript.init(allocator);
    defer script.deinit();

    // Each call appends a step and returns the script, so they chain. A real
    // login flow reads like a transcript of the expected interaction:
    _ = script
        .expect("Username:") // wait until this substring appears in output
        .send("alice") // type this (with a trailing newline)
        .expect("Password:")
        .sendHidden("s3cret") // typed but not echoed to the transcript
        .expect("Welcome");

    // The builder is pure data until you run it — handy to assert the shape of a
    // script, or to build one conditionally before executing.
    try std.testing.expect(script.steps.items.len == 5);
    try std.testing.expectEqualStrings("Username:", script.steps.items[0].expect.?);
}

// ---------------------------------------------------------------------------
// 2. Running a script over pipes (no TTY required — runs in CI everywhere).
// ---------------------------------------------------------------------------

test "runInteractive over pipes: send then expect the echo" {
    if (builtin.os.tag == .windows) return; // pipe mode + `cat` are POSIX here

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var script = e2e.InteractiveScript.init(allocator);
    defer script.deinit();

    // `cat` echoes stdin to stdout: send a line, then expect it back.
    _ = script.send("ping-42").expect("ping-42");

    var result = e2e.runInteractive(allocator, io, &.{"cat"}, script, .{
        // Pipe mode: no pseudo-terminal is allocated, so this runs on any POSIX
        // host without a controlling TTY.
        .allocate_pty = false,
        .total_timeout_ms = 5000,
    }) catch |err| {
        // Spawning may be restricted in some sandboxes; skip rather than fail.
        std.log.warn("runInteractive (pipe) skipped: {any}", .{err});
        return;
    };
    defer result.deinit();

    // `result.output` is everything the child wrote. In a real test you'd also
    // check `result.success` (all steps matched) and `result.exit_code`.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ping-42") != null);
}

// ---------------------------------------------------------------------------
// 3. Running over a real PTY — degrades to a skip where no TTY is available.
// ---------------------------------------------------------------------------

test "runInteractive over a real PTY (skips gracefully without a TTY)" {
    if (builtin.os.tag == .windows) return;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var script = e2e.InteractiveScript.init(allocator);
    defer script.deinit();

    _ = script.send("tty-hello").expect("tty-hello");

    // `.allocate_pty = true` (the default) gives the child a real pseudo-terminal
    // — the only way to exercise password prompts, raw-mode key handling, and
    // TTY-only formatting. On a host where a PTY can't be allocated this returns
    // an error; we treat that as a SKIP so the suite stays green in constrained
    // environments (this is the same policy the harness documents). Locally on
    // macOS the POSIX PTY path works and this really runs.
    var result = e2e.runInteractive(allocator, io, &.{"cat"}, script, .{
        .allocate_pty = true,
        .total_timeout_ms = 5000,
    }) catch |err| {
        std.log.warn("runInteractive (PTY) skipped — no working TTY: {any}", .{err});
        return;
    };
    defer result.deinit();

    try std.testing.expect(std.mem.indexOf(u8, result.output, "tty-hello") != null);
}

// ---------------------------------------------------------------------------
// 4. Asserting on the RENDERED screen — frame assertions.
// ---------------------------------------------------------------------------

test "runInteractive frame assertions check the rendered screen" {
    if (builtin.os.tag == .windows) return;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // A shell one-liner that clears the screen, then positions the cursor and
    // paints "READY" on row 3 (1-based) via an absolute CUP escape, and finally
    // waits for a line of input so the harness can end the session. The literal
    // "READY" is preceded by cursor-movement bytes — exactly the case where a
    // raw-stream `.expect("READY")` would pass without proving WHERE it landed.
    const program = "printf '\\033[2J\\033[3;1HREADY'; read _dummy";

    var script = e2e.InteractiveScript.init(allocator);
    defer script.deinit();
    _ = script
        // `.expectFrameContains` walks the rendered cells: it only matches if
        // "READY" is visible on screen. `.expectRow` is stricter still — it
        // pins the exact row (0-based) the text was drawn on. Both poll until
        // the frame matches or the step times out (no fixed sleeps).
        .expectFrameContains("READY").withTimeout(4000)
        .expectRow(2, "READY").withTimeout(4000)
        .send("go"); // let `read` return so `sh` exits

    var result = e2e.runInteractive(allocator, io, &.{ "/bin/sh", "-c", program }, script, .{
        .allocate_pty = true, // a real terminal is required for frame assertions
        .terminal_size = .{ .rows = 24, .cols = 40 },
        .total_timeout_ms = 8000,
    }) catch |err| {
        std.log.warn("runInteractive (frame) skipped — no working TTY: {any}", .{err});
        return;
    };
    defer result.deinit();

    try std.testing.expect(result.steps_executed >= 2);
}
