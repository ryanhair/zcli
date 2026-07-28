//! Process-global terminal restore guard (ADR-0015 choice 5).
//!
//! A full-screen App — and, more mildly, a hybrid one — takes over process-global
//! terminal state (raw mode, the alternate screen, a hidden cursor) that outlives
//! the process: the kernel does not undo it on exit. `App.deinit` restores it on
//! the normal path, but two exits skip `deinit`:
//!
//! - **External termination** — `SIGTERM`/`SIGINT`/`SIGHUP` from a `kill`, or a
//!   console-close on Windows. Caught by the handlers installed here.
//! - **A panic** — Zig panics do not run `defer`, so `defer app.deinit()` never
//!   fires. Caught by the `ui.panic` hook, which calls `restore` before the
//!   default handler prints (so the trace lands on the restored screen).
//!
//! The mechanism is mode-agnostic: whoever takes over registers a precomputed
//! restore blob (escape bytes + an optional saved raw mode) via `arm`; the signal
//! handlers and the panic hook replay it via `restore`, which just writes back
//! whatever was registered — hybrid registers "show cursor", full-screen registers
//! "show cursor + leave alt-screen + restore termios".
//!
//! Process-global because a signal handler and the panic hook cannot reach the App
//! instance — the same one-active-takeover assumption the SIGWINCH watcher already
//! makes.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("backend.zig");

const Handle = backend.Handle;
const RawMode = backend.RawMode;

/// The restore blob is short and bounded: show cursor (`\x1b[?25h`, 6B), leave
/// the alt-screen (`\x1b[?1049l`, 8B), and disable any opt-in input modes
/// (mouse `?1002l?1006l`, focus `?1004l`). 48B covers all of them at once.
const blob_max = 48;

/// Gates every read of `g` by the async restore path. `arm` withdraws it before
/// touching `g` and republishes it after (release), `restore`/`disarm` read it
/// with acquire — so a handler that fires mid-`arm` (including a *re*-arm over an
/// already-armed guard) sees `false` and replays nothing rather than a
/// half-written `g`. Never a torn read of the blob.
var armed = std.atomic.Value(bool).init(false);

var g: struct {
    out: Handle = undefined,
    blob: [blob_max]u8 = undefined,
    blob_len: usize = 0,
    raw: ?RawMode = null,
} = .{};

/// Register the restore blob and install the external-termination handlers.
/// `out` is the tty the escape bytes are written to; `raw`, when present, is the
/// saved terminal mode to `disable()` on an abnormal exit. Called on takeover,
/// from the main thread.
pub fn arm(out: Handle, blob: []const u8, raw: ?RawMode) void {
    std.debug.assert(blob.len <= blob_max);
    // Withdraw first: a re-arm over an already-armed guard (e.g. hybrid's
    // `start` re-arming with the cursor-show blob) would otherwise race the
    // async restore path reading `g` — a POSIX signal handler interrupting this
    // thread, or Windows' console-ctrl handler on its own thread. The acq_rel
    // swap fences the `g` stores below to happen after the withdrawal, so no
    // handler observes a torn `g`; the tiny window where `armed` is false just
    // means such a handler restores nothing (the same disarm-then-arm tradeoff).
    _ = armed.swap(false, .acq_rel);
    g.out = out;
    @memcpy(g.blob[0..blob.len], blob);
    g.blob_len = blob.len;
    g.raw = raw;
    // Idempotent, and it has to be: this is also the re-arm path, and installing
    // twice would capture the guard's *own* handlers as the saved originals.
    impl.install();
    // Republish as a unit: the acquire load in `restore` pairs with this release
    // store, so a handler that sees `true` sees every `g` write above.
    armed.store(true, .release);
}

/// Remove the handlers and stop replaying. Idempotent — a no-op if not armed, so
/// `deinit` can call it unconditionally (including on the headless path that
/// never armed).
pub fn disarm() void {
    if (!armed.swap(false, .acq_rel)) return;
    impl.remove();
}

/// Replay the registered restore blob: write the escape bytes, then restore the
/// saved raw mode. Async-signal-safe — a raw `write`/`WriteFile` plus
/// `tcsetattr`/`SetConsoleMode`, no buffered writer and no allocator — so it is
/// safe from both a signal handler and the panic hook. A no-op if not armed.
pub fn restore() void {
    if (!armed.load(.acquire)) return;
    impl.writeRaw(g.out, g.blob[0..g.blob_len]);
    if (g.raw) |r| r.disable();
}

const impl = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const DWORD = windows.DWORD;
    const HANDLE = windows.HANDLE;

    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (DWORD) callconv(.winapi) c_int,
        add: c_int,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: *DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) c_int;

    /// Runs on a thread the console spawns for Ctrl-C / close / logoff / shutdown.
    /// Returning FALSE lets the default handler run next, which terminates the
    /// process — so we restore first, then fall through to the normal death.
    fn ctrlHandler(_: DWORD) callconv(.winapi) c_int {
        restore();
        return 0; // FALSE
    }

    /// See the POSIX `installed` comment — same reentrancy problem, different
    /// symptom. `SetConsoleCtrlHandler(h, TRUE)` *appends* to the console's
    /// handler list, so a re-arm registers `ctrlHandler` twice, while `disarm`'s
    /// single remove pops only one entry: the guard stays wired to the console
    /// after the App is gone, replaying a stale `g` on the next Ctrl-C.
    var installed = false;

    fn install() void {
        if (installed) return;
        _ = SetConsoleCtrlHandler(ctrlHandler, 1);
        installed = true;
    }
    fn remove() void {
        if (!installed) return;
        _ = SetConsoleCtrlHandler(ctrlHandler, 0);
        installed = false;
    }
    fn writeRaw(h: Handle, bytes: []const u8) void {
        var written: DWORD = 0;
        _ = WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null);
    }
} else struct {
    const posix = std.posix;

    /// The external-termination signals. Raw mode clears `ISIG`, so an in-session
    /// Ctrl-C is a key, not `SIGINT`; these fire only for an actual `kill`.
    const sigs = .{ posix.SIG.INT, posix.SIG.TERM, posix.SIG.HUP };
    var old: [sigs.len]posix.Sigaction = undefined;

    /// Whether `old` currently holds the *process's* dispositions rather than the
    /// guard's own. `arm` is called over an already-armed guard on every hybrid
    /// prompt (`App.init` arms with the empty blob, then `App.start` re-arms with
    /// the cursor-show blob) against a single `disarm` — and a second `sigaction`
    /// would write our own handler into `old`, so `disarm` would install the guard
    /// handler *permanently*. That silently rewrites inherited dispositions: a
    /// `nohup`'d CLI inherits `SIG_IGN` for SIGHUP, and one `confirm()` prompt
    /// later SIGHUP is the guard handler, whose re-raise finds SIG_DFL and kills
    /// the job on terminal close. Same for a consumer's own SIGTERM cleanup
    /// handler. So only the *first* install captures, and only a matching remove
    /// gives the capture back.
    ///
    /// A plain `bool`, deliberately not an atomic: it is touched only by
    /// `install`/`remove`, i.e. only from `arm`/`disarm` on the main thread, and
    /// never by the async restore path — which reads `armed`/`g` and nothing here.
    var installed = false;

    fn install() void {
        if (installed) return;
        inline for (sigs, 0..) |signo, i| {
            var act = posix.Sigaction{
                .handler = .{ .handler = handlerFor(signo) },
                .mask = posix.sigemptyset(),
                // RESETHAND: the disposition is back to default on entry, so the
                // handler's re-raise finds SIG_DFL (no recursion). NODEFER: the
                // signal isn't blocked during the handler, so the re-raise is
                // delivered synchronously and terminates us then and there —
                // together, the "clean up, then die BY the signal" idiom.
                .flags = posix.SA.RESETHAND | posix.SA.NODEFER,
            };
            posix.sigaction(signo, &act, &old[i]);
        }
        installed = true;
    }
    fn remove() void {
        if (!installed) return;
        inline for (sigs, 0..) |signo, i| posix.sigaction(signo, &old[i], null);
        installed = false;
    }
    /// The raw `write(2)` syscall — `std.posix.write` is gone in 0.16's IO model,
    /// and a signal handler can't use a buffered writer anyway. Best-effort: a
    /// short escape blob to a tty won't partial-write in practice, and the
    /// process is dying regardless.
    fn writeRaw(h: Handle, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = posix.system.write(h, bytes.ptr + off, bytes.len - off);
            const n: isize = @bitCast(rc); // usize (linux) or isize (darwin)
            if (n <= 0) return;
            off += @intCast(n);
        }
    }

    /// A distinct handler per signal so each knows its own number without reading
    /// the (platform-varying) handler argument. Restore, then re-raise the signal
    /// so the process dies BY it — the parent sees `WIFSIGNALED`/`WTERMSIG`, not a
    /// plain exit. `posix.raise` is reachable on every target this branch compiles
    /// for (macOS always links libSystem; libc-free Linux uses `tkill`; Windows
    /// takes the other `impl`), so no libc dependency is added. The `exit` is a
    /// fallback for the practically-impossible case where `raise` returns.
    fn handlerFor(comptime signo: anytype) fn (posix.SIG) callconv(.c) void {
        return struct {
            fn h(_: posix.SIG) callconv(.c) void {
                restore();
                posix.raise(signo) catch {};
                std.process.exit(128 +| sigNum(signo));
            }
        }.h;
    }

    /// The `SIG` constants are an `enum(u32)` on Darwin and plain ints elsewhere.
    fn sigNum(comptime signo: anytype) u8 {
        return switch (@typeInfo(@TypeOf(signo))) {
            .@"enum" => @intCast(@intFromEnum(signo)),
            else => @intCast(signo),
        };
    }
};

// A handle the tests can `arm` against without writing to a real terminal —
// `arm` only stores, it never writes, and every test disarms before returning.
const test_handle: Handle = if (builtin.os.tag == .windows) undefined else 0;

// std.mem.zeroes refuses the Windows RawMode (its Handles are non-nullable
// pointers), so build the dummy explicitly per platform.
const test_raw: RawMode = if (builtin.os.tag == .windows) .{
    .in = test_handle,
    .in_mode = 0,
    .out = test_handle,
    .out_mode = 0,
    .out_changed = false,
    .out_prev_cp = 0,
} else std.mem.zeroes(RawMode);

test "arm registers the blob and raw mode; disarm clears the armed flag" {
    defer disarm();
    try std.testing.expect(!armed.load(.acquire));

    arm(test_handle, "\x1b[?25h", test_raw);
    try std.testing.expect(armed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 6), g.blob_len);
    try std.testing.expectEqualStrings("\x1b[?25h", g.blob[0..g.blob_len]);
    // The caller's raw mode is registered so a signal restores termios, not
    // just the cursor — the hybrid-prompt fix.
    try std.testing.expect(g.raw != null);

    disarm();
    try std.testing.expect(!armed.load(.acquire));
}

test "arm with a null raw registers cursor-only restore" {
    defer disarm();
    arm(test_handle, "\x1b[?25h", null);
    try std.testing.expect(armed.load(.acquire));
    try std.testing.expect(g.raw == null);
}

test "re-arm over an armed guard replaces the blob and raw mode" {
    defer disarm();
    // The hybrid path arms with an empty blob in `init`, then `start` re-arms
    // with the cursor-show blob over the still-armed guard (#458 item 2).
    arm(test_handle, "", test_raw);
    try std.testing.expect(armed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), g.blob_len);

    arm(test_handle, "\x1b[?25h", null);
    try std.testing.expect(armed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 6), g.blob_len);
    try std.testing.expectEqualStrings("\x1b[?25h", g.blob[0..g.blob_len]);
    // The re-arm's fields fully replaced the prior arm's — no stale raw mode.
    try std.testing.expect(g.raw == null);
}

// Deliberately narrow name. This asserts the `installed` *flag* transitions and
// nothing else — it does NOT prove the registration is idempotent, and it would
// still pass if someone dropped the `if (installed) return;` early-outs while
// leaving the assignments. That gap is on purpose, and it is split by platform:
//
// - POSIX: the effect is directly observable, so it is tested for real in
//   "double arm then disarm restores the true process dispositions" below. That
//   is the regression test for #733; this one is only a cheap guard on the
//   arm/disarm gating around it.
// - Windows: `SetConsoleCtrlHandler` is add/remove only — the console exposes no
//   way to read the handler list or its length back, and the duplicate
//   registration is invisible in-process until a real Ctrl-C arrives on a
//   console this test doesn't have. So the flag is the only observable there and
//   the effect is untestable by construction, not by omission.
//
// Assert on the bookkeeping only where the bookkeeping is all you can reach —
// the pre-existing re-arm test above asserted on the blob alone and that is
// exactly how #733 got in.
test "arm/disarm track the install flag across a re-arm" {
    defer disarm();
    try std.testing.expect(!impl.installed);

    arm(test_handle, "", test_raw);
    try std.testing.expect(impl.installed);
    arm(test_handle, "\x1b[?25h", null);
    try std.testing.expect(impl.installed);

    // One disarm against two arms still fully unwinds — arm/disarm are gated on
    // `armed`, not counted.
    disarm();
    try std.testing.expect(!impl.installed);
}

// The #733 regression test: asserts the *effect* — real `sigaction` state read
// back from the kernel — not the flag that produces it.
test "double arm then disarm restores the true process dispositions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const posix = std.posix;
    defer disarm();

    var saved_hup: posix.Sigaction = undefined;
    var saved_term: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.HUP, null, &saved_hup);
    posix.sigaction(posix.SIG.TERM, null, &saved_term);
    defer {
        posix.sigaction(posix.SIG.HUP, &saved_hup, null);
        posix.sigaction(posix.SIG.TERM, &saved_term, null);
    }

    // Non-default dispositions on purpose: SIG_DFL restores look correct even
    // when the bookkeeping is broken, because the guard's own handler and the
    // process default both "work" for a naive check. These are the two real
    // cases — an inherited `SIG_IGN` for SIGHUP (`nohup mycli deploy &`) and a
    // consumer's own SIGTERM cleanup handler.
    var want_hup = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var want_term = posix.Sigaction{
        .handler = .{ .handler = consumerTermHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.HUP, &want_hup, null);
    posix.sigaction(posix.SIG.TERM, &want_term, null);

    // Exactly the hybrid-prompt sequence: `App.init` arms with the empty blob,
    // `App.start` re-arms with the cursor-show blob, a single `App.deinit`
    // disarms (app.zig:211 / app.zig:700 / app.zig:312).
    arm(test_handle, "", test_raw);
    var during: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.HUP, null, &during);
    // Sanity: the guard really did take SIGHUP over, so the assertions below are
    // testing a restore and not an install that never happened.
    try std.testing.expect(during.handler.handler != posix.SIG.IGN);

    arm(test_handle, "\x1b[?25h", null);
    disarm();

    var after_hup: posix.Sigaction = undefined;
    var after_term: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.HUP, null, &after_hup);
    posix.sigaction(posix.SIG.TERM, null, &after_term);
    // The process's dispositions, not the guard's own handlers. Before the
    // idempotence fix both of these came back as the guard handler, so a
    // `nohup`'d run died on terminal close and the consumer's cleanup never ran.
    try std.testing.expectEqual(posix.SIG.IGN, after_hup.handler.handler);
    try std.testing.expectEqual(
        @as(?@TypeOf(want_term).handler_fn, consumerTermHandler),
        after_term.handler.handler,
    );
}

/// Stands in for a consumer-installed SIGTERM cleanup handler. Never runs — the
/// test only ever reads the disposition back, it does not raise anything.
fn consumerTermHandler(_: std.posix.SIG) callconv(.c) void {}

test "disarm is idempotent when never armed" {
    // No prior arm — disarm must be a safe no-op (the headless/never-armed path).
    disarm();
    try std.testing.expect(!armed.load(.acquire));
    disarm();
    try std.testing.expect(!armed.load(.acquire));
}

test "restore is a no-op after disarm" {
    arm(test_handle, "\x1b[?25h", test_raw);
    disarm();
    // Armed is false, so restore returns before touching the handle or raw
    // mode — safe to call on the test handle.
    restore();
    try std.testing.expect(!armed.load(.acquire));
}
