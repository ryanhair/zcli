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

/// Set last by `arm` (release) and cleared first by `disarm` — so a handler that
/// fires mid-`arm` either sees `false` (does nothing) or a fully written `g`.
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
    g.out = out;
    @memcpy(g.blob[0..blob.len], blob);
    g.blob_len = blob.len;
    g.raw = raw;
    impl.install();
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

    fn install() void {
        _ = SetConsoleCtrlHandler(ctrlHandler, 1);
    }
    fn remove() void {
        _ = SetConsoleCtrlHandler(ctrlHandler, 0);
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

    fn install() void {
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
    }
    fn remove() void {
        inline for (sigs, 0..) |signo, i| posix.sigaction(signo, &old[i], null);
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

test "arm registers the blob and raw mode; disarm clears the armed flag" {
    defer disarm();
    try std.testing.expect(!armed.load(.acquire));

    const raw = std.mem.zeroes(RawMode);
    arm(test_handle, "\x1b[?25h", raw);
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

test "disarm is idempotent when never armed" {
    // No prior arm — disarm must be a safe no-op (the headless/never-armed path).
    disarm();
    try std.testing.expect(!armed.load(.acquire));
    disarm();
    try std.testing.expect(!armed.load(.acquire));
}

test "restore is a no-op after disarm" {
    arm(test_handle, "\x1b[?25h", std.mem.zeroes(RawMode));
    disarm();
    // Armed is false, so restore returns before touching the handle or raw
    // mode — safe to call on the test handle.
    restore();
    try std.testing.expect(!armed.load(.acquire));
}
