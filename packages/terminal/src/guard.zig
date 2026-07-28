//! Process-global terminal restore guard (ADR-0015 choice 5).
//!
//! A full-screen App — and, more mildly, a hybrid one — takes over process-global
//! terminal state (raw mode, the alternate screen, a hidden cursor) that outlives
//! the process: the kernel does not undo it on exit. `App.deinit` restores it on
//! the normal path, but four exits skip `deinit`:
//!
//! - **External termination** — `SIGTERM`/`SIGINT`/`SIGHUP` from a `kill`, or a
//!   console-close on Windows. Caught by the handlers installed here.
//! - **A panic** — Zig panics do not run `defer`, so `defer app.deinit()` never
//!   fires. Caught by the `ui.panic` hook, which calls `restore` before the
//!   default handler prints (so the trace lands on the restored screen).
//! - **A hardware fault** — SIGSEGV/SIGILL/SIGBUS/SIGFPE do NOT route through
//!   `root.panic`; Zig sends them to `root.debug.handleSegfault` instead, and in
//!   ReleaseFast it installs no handler at all. `ui.debug` covers the former,
//!   `fault_sigs` below covers the latter (#759).
//! - **A suspend** — Ctrl-Z on the cooked-mode path (progress indicators, a
//!   hybrid App without raw mode) stops the process with the cursor still
//!   hidden, so the shell prompt comes back invisible. `SIGTSTP` is caught,
//!   restored, and re-entered on resume (#762).
//!
//! The mechanism is mode-agnostic: whoever takes over registers a precomputed
//! restore blob (escape bytes + an optional saved raw mode) via `arm`; the signal
//! handlers and the panic hook replay it via `restore`, which just writes back
//! whatever was registered — hybrid registers "show cursor", full-screen registers
//! "show cursor + leave alt-screen + restore termios".
//!
//! Process-global because a signal handler and the panic hook cannot reach the App
//! instance — the same one-active-takeover assumption the SIGWINCH watcher already
//! makes. Takeovers *nest*, though (a `prompts` prompt opened inside a full-screen
//! App), so the registration is a stack rather than a single slot: see `stack`.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("backend.zig");

const Handle = backend.Handle;
const RawMode = backend.RawMode;

/// The restore blob is short and bounded: undo the paint modes (`\x1b[?7h`
/// autowrap 5B, `\x1b[?2026l` synchronized output 8B), show the cursor
/// (`\x1b[?25h`, 6B), leave the alt-screen (`\x1b[?1049l`, 8B), and disable any
/// opt-in input modes (mouse `?1002l?1006l` 16B, focus `?1004l` 8B, paste
/// `?2004l` 8B). That worst case is 59B; 96 leaves room for a sequence or two
/// more without another audit.
///
/// The bound used to be 48 with ~2 bytes of headroom, enforced by
/// `std.debug.assert` — which compiles out in ReleaseFast, where an oversized
/// blob would have been a silent `@memcpy` past `Entry.blob` (#760). It is now
/// enforced three ways: a `@compileError` at the one site that composes a blob
/// (`ui.terminal_session`, which sizes its scratch buffer from this constant), a
/// debug/safe-build assert here, and a clamp in `write` below that survives
/// ReleaseFast.
pub const blob_max = 96;

/// How deep takeovers may nest. Two is the real world — a `prompts` prompt
/// (hybrid) opened inside a full-screen App — and four is slack. A push past
/// this is *dropped* rather than overwriting an entry: `restore` replays the
/// stack outward, so the entries that matter most (the outer ones, which own the
/// alt-screen and the true pre-raw termios) are the ones kept.
const max_depth = 4;

/// One registered takeover.
const Entry = struct {
    out: Handle = undefined,
    /// Bytes that undo this takeover's terminal state.
    blob: [blob_max]u8 = undefined,
    blob_len: usize = 0,
    /// Bytes that put it back, replayed after a SIGTSTP suspend resumes (#762).
    /// Empty for takeovers that can't be suspended (any raw-mode session — raw
    /// mode clears `ISIG`, so no `SIGTSTP` handler is installed for one).
    reenter: [blob_max]u8 = undefined,
    reenter_len: usize = 0,
    /// The termios/console mode to put back. For a *nested* takeover this is
    /// whatever `enableRawMode` saw when it ran — which, inside an already-raw
    /// session, is the raw mode itself. That is exactly why `restore` keeps
    /// walking outward instead of stopping at the top of the stack: the
    /// outermost entry is the one holding the true pre-raw termios (#761).
    raw: ?RawMode = null,
};

/// Number of stack entries published to the async restore path — and the gate on
/// reading `stack` at all. Every mutator withdraws it (swaps 0 in, acq_rel)
/// before touching `stack`/`depth` and republishes after (release);
/// `restore`/`reenter` read it with acquire. So a handler that fires mid-`arm`
/// sees 0 and replays nothing rather than a half-written entry. Never a torn
/// read of a blob.
var active = std.atomic.Value(usize).init(0);

/// The takeover stack, innermost last. Only `stack[0..active]` is ever read by
/// the async path.
var stack: [max_depth]Entry = @splat(.{});

/// The main-thread view of the stack height. Distinct from `active`, which is
/// transiently 0 while a mutator is rewriting the stack. Touched only by
/// `arm`/`rearm`/`disarm`, never by the async restore path — a plain `usize`
/// for the same reason `impl.installed` is a plain `bool`.
var depth: usize = 0;

/// Pushes refused for want of room (see `max_depth`). Counted, not ignored, so
/// the matching `disarm` cancels its own drop instead of popping a *tracked*
/// outer entry and unguarding a session that is still live.
var dropped: usize = 0;

/// What a takeover registers. A struct, not positional arguments, because two of
/// the four fields are escape blobs and swapping them silently would replace
/// "undo the takeover" with "redo it".
pub const Restore = struct {
    /// The tty the escape bytes are written to.
    out: Handle,
    /// Bytes that undo the takeover.
    blob: []const u8,
    /// Bytes that re-enter it after a suspend/resume (#762). Only meaningful for
    /// a cooked-mode takeover; see `Entry.reenter`.
    reenter: []const u8 = "",
    /// The saved terminal mode to `disable()` on an abnormal exit.
    raw: ?RawMode = null,
};

/// Push a takeover onto the guard stack and install the abnormal-exit handlers.
/// Called on takeover, from the main thread. Pair with exactly one `disarm`; to
/// re-register the *same* takeover (hybrid arms in `App.init` and again in
/// `App.start`) use `rearm`, which replaces the top entry instead of stacking a
/// second one.
pub fn arm(r: Restore) void {
    set(r, false);
}

/// Replace the top entry — the same takeover re-registering, e.g. hybrid's
/// `start` swapping its empty init blob for the cursor-show one. Distinct from
/// `arm` so that a genuinely *nested* takeover (a prompt inside a full-screen
/// App) stacks instead of clobbering the outer session's blob and termios, and
/// so that its `disarm` pops only its own entry (#761).
pub fn rearm(r: Restore) void {
    set(r, true);
}

fn set(r: Restore, replace_top: bool) void {
    // Withdraw first: the async restore path — a POSIX signal handler
    // interrupting this thread, or Windows' console-ctrl handler on its own
    // thread — would otherwise race the writes below. The acq_rel swap fences
    // them to happen after the withdrawal, so no handler observes a torn entry;
    // the tiny window where `active` is 0 just means such a handler restores
    // nothing (the same disarm-then-arm tradeoff).
    _ = active.swap(0, .acq_rel);
    if (dropped > 0) {
        // Already past `max_depth`: this takeover is untracked, and so is its
        // re-arm. Its `disarm` cancels the drop.
        if (!replace_top) dropped += 1;
    } else if (replace_top and depth > 0) {
        write(&stack[depth - 1], r);
    } else if (depth == max_depth) {
        dropped += 1;
    } else {
        write(&stack[depth], r);
        depth += 1;
    }
    // Idempotent, and it has to be: this is also the re-arm path, and installing
    // twice would capture the guard's *own* handlers as the saved originals.
    impl.install(cookedSession());
    // Republish as a unit: the acquire load in `restore` pairs with this release
    // store, so a handler that sees a nonzero count sees every write above.
    active.store(depth, .release);
}

fn write(e: *Entry, r: Restore) void {
    e.out = r.out;
    e.blob_len = copyBounded(&e.blob, r.blob);
    e.reenter_len = copyBounded(&e.reenter, r.reenter);
    e.raw = r.raw;
}

/// Copy into a `blob_max` buffer, clamping rather than overrunning. The assert
/// fires loudly in debug/ReleaseSafe (where the mistake gets made); the `@min`
/// is what survives ReleaseFast, where `std.debug.assert` is a no-op and an
/// oversized blob would smash whatever follows `stack` (#760). A truncated
/// restore is a cosmetic loss; a memory-safety bug in shipped binaries is not.
fn copyBounded(dst: *[blob_max]u8, src: []const u8) usize {
    std.debug.assert(src.len <= blob_max);
    const n = @min(src.len, blob_max);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// Whether every live takeover is in cooked mode, i.e. `ISIG` is still on and
/// Ctrl-Z/Ctrl-\ reach the process as signals rather than as key bytes. One
/// raw-mode entry anywhere in the stack makes the whole terminal raw, so the
/// answer is "all of them or none" (#762).
fn cookedSession() bool {
    if (depth == 0) return false;
    for (stack[0..depth]) |e| {
        if (e.raw != null) return false;
    }
    return true;
}

/// Pop the top takeover. If an outer takeover is still on the stack it becomes
/// active again — its blob and its (pre-raw) termios — rather than the guard
/// disarming wholesale and leaving the outer session unguarded (#761). Only the
/// last pop removes the handlers. Idempotent — a no-op if nothing is armed, so
/// `deinit` can call it unconditionally (including on the headless path that
/// never armed).
pub fn disarm() void {
    if (depth == 0 and dropped == 0) return;
    _ = active.swap(0, .acq_rel);
    if (dropped > 0) {
        dropped -= 1;
    } else {
        depth -= 1;
    }
    if (depth == 0) impl.remove() else impl.install(cookedSession());
    active.store(depth, .release);
}

/// Replay every registered restore blob, innermost takeover first: write the
/// escape bytes, then put back the saved terminal mode. Async-signal-safe — a
/// raw `write`/`WriteFile` plus `tcsetattr`/`SetConsoleMode`, no buffered writer
/// and no allocator — so it is safe from both a signal handler and the panic
/// hook. A no-op if nothing is armed.
///
/// Walking the *whole* stack (rather than just the top) is what makes a nested
/// takeover safe: the inner entry of a prompt-inside-a-full-screen-App carries
/// the alt-screen-less blob and an already-raw "original" termios, so stopping
/// there would leave the alt-screen up and the terminal raw. The outermost entry
/// is written last and therefore wins (#761).
pub fn restore() void {
    var i = active.load(.acquire);
    while (i > 0) {
        i -= 1;
        const e = &stack[i];
        impl.writeRaw(e.out, e.blob[0..e.blob_len]);
        if (e.raw) |r| r.disable();
    }
}

/// The inverse of `restore`, replayed outermost takeover first when a SIGTSTP
/// suspend resumes (#762). Escape bytes only: `SIGTSTP` is installed exclusively
/// for cooked-mode takeovers, so no entry on the stack has a raw mode to
/// re-enable (`cookedSession`). Async-signal-safe on the same terms as `restore`.
fn reenter() void {
    const n = active.load(.acquire);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e = &stack[i];
        impl.writeRaw(e.out, e.reenter[0..e.reenter_len]);
    }
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

    /// `cooked` (the POSIX suspend/quit split, #762) has no Windows analogue:
    /// there is no SIGTSTP, and the console-ctrl handler already covers Ctrl-C /
    /// Ctrl-Break / close / logoff regardless of the input mode.
    fn install(cooked: bool) void {
        _ = cooked;
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

    /// Signals Zig's own machinery handles in safe builds but not in ReleaseFast
    /// (#759). A fault does NOT route through `root.panic` — Zig sends it to
    /// `root.debug.handleSegfault`, which is only reachable when std installed
    /// its handler at startup, i.e. when `enable_segfault_handler` is on
    /// (`runtime_safety` by default). In ReleaseFast nothing is installed, so a
    /// SIGSEGV in a TUI kills the process with the alt-screen up and the
    /// terminal raw. There we install the ordinary restore-then-die-by-the-signal
    /// handler; the core dump and `WTERMSIG` are preserved, and there is no
    /// stack trace to lose. In safe builds std owns these four and `ui.debug`
    /// does the restore, so we stay out of the way entirely — installing over
    /// std's handler would cost the trace.
    ///
    /// Note the one case neither covers: a SIGSEGV from stack *overflow* needs an
    /// alternate signal stack to be catchable at all, and std only configures one
    /// (`std.options.signal_stack_size`) when its own handler is enabled.
    const fault_sigs = if (std.options.enable_segfault_handler)
        .{}
    else
        .{ posix.SIG.SEGV, posix.SIG.ILL, posix.SIG.BUS, posix.SIG.FPE };

    /// The always-installed abnormal-exit signals: external termination
    /// (`SIGTERM`/`SIGINT`/`SIGHUP` from a `kill`) plus, in ReleaseFast only, the
    /// hardware faults above. Raw mode clears `ISIG`, so an in-session Ctrl-C is
    /// a key and not `SIGINT`; the termination three fire only for an actual
    /// `kill`, which is why they are safe to install in both modes.
    const sigs = .{ posix.SIG.INT, posix.SIG.TERM, posix.SIG.HUP } ++ fault_sigs;
    var old: [sigs.len]posix.Sigaction = undefined;

    /// Signals only a COOKED-mode takeover needs (#762). Raw mode clears `ISIG`,
    /// so in a prompt or a full-screen App Ctrl-\ is a key byte and SIGQUIT never
    /// arrives — installing a handler there would be dead code that also
    /// rewrites the app's inherited disposition for no reason. But progress
    /// indicators never enter raw mode (`Progress` builds a hybrid App with no
    /// `hybrid_raw`), so ISIG is live and Ctrl-\ dumps core with the cursor still
    /// hidden. `SIGTSTP` is the same shape but needs the suspend/resume handler
    /// below rather than the die-by-the-signal one, so it is tracked separately.
    const cooked_sigs = .{posix.SIG.QUIT};
    var old_cooked: [cooked_sigs.len]posix.Sigaction = undefined;
    var old_tstp: posix.Sigaction = undefined;

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
    /// `install`/`remove`, i.e. only from `arm`/`rearm`/`disarm` on the main
    /// thread, and never by the async restore path — which reads `active` and
    /// `stack` and nothing here. (`suspendHandler` is the one exception, and it
    /// deliberately re-installs *without* touching this flag or `old_tstp`.)
    var installed = false;

    /// Companion flag for `cooked_sigs` + `SIGTSTP`, with the same
    /// capture-once/give-back-once discipline as `installed` and for the same
    /// reason: these come and go *within* a guarded lifetime (a raw prompt opened
    /// inside a cooked spinner takes them away and its `disarm` brings them
    /// back), so a second capture would record the guard's own handlers as the
    /// process's.
    var cooked_installed = false;

    fn install(cooked: bool) void {
        if (!installed) {
            inline for (sigs, 0..) |signo, i| {
                var act = actionFor(signo);
                posix.sigaction(signo, &act, &old[i]);
            }
            installed = true;
        }
        setCooked(cooked);
    }

    fn remove() void {
        // Cooked first, so the dispositions unwind in the reverse of install.
        setCooked(false);
        if (!installed) return;
        inline for (sigs, 0..) |signo, i| posix.sigaction(signo, &old[i], null);
        installed = false;
    }

    /// Install or remove the cooked-only handlers to match the current stack.
    /// Called on every arm/disarm, because nesting can flip the answer in both
    /// directions (#762).
    fn setCooked(want: bool) void {
        if (want == cooked_installed) return;
        if (want) {
            inline for (cooked_sigs, 0..) |signo, i| {
                var act = actionFor(signo);
                posix.sigaction(signo, &act, &old_cooked[i]);
            }
            setSuspendHandler(&old_tstp);
        } else {
            inline for (cooked_sigs, 0..) |signo, i| posix.sigaction(signo, &old_cooked[i], null);
            posix.sigaction(posix.SIG.TSTP, &old_tstp, null);
        }
        cooked_installed = want;
    }

    fn actionFor(comptime signo: anytype) posix.Sigaction {
        return .{
            .handler = .{ .handler = handlerFor(signo) },
            .mask = posix.sigemptyset(),
            // RESETHAND: the disposition is back to default on entry, so the
            // handler's re-raise finds SIG_DFL (no recursion). NODEFER: the
            // signal isn't blocked during the handler, so the re-raise is
            // delivered synchronously and terminates us then and there —
            // together, the "clean up, then die BY the signal" idiom.
            .flags = posix.SA.RESETHAND | posix.SA.NODEFER,
        };
    }

    /// `old_out` is `null` when the suspend handler re-installs itself from
    /// inside the handler: RESETHAND has already reset the disposition to
    /// SIG_DFL by then, so capturing it would overwrite the process's real
    /// SIGTSTP disposition with the default — the #733 mistake in miniature.
    fn setSuspendHandler(old_out: ?*posix.Sigaction) void {
        var act = posix.Sigaction{
            .handler = .{ .handler = suspendHandler },
            .mask = posix.sigemptyset(),
            // Same RESETHAND|NODEFER idiom as the death handlers, used here to
            // *stop* by the signal rather than die by it.
            .flags = posix.SA.RESETHAND | posix.SA.NODEFER,
        };
        posix.sigaction(posix.SIG.TSTP, &act, old_out);
    }

    /// Ctrl-Z on the cooked path (#762). Undo the display state, stop by the
    /// signal the way an unhandled Ctrl-Z would, and put the display back when
    /// SIGCONT resumes us.
    ///
    /// Everything here is async-signal-safe: `restore`/`reenter` are raw
    /// `write(2)` loops, and `sigaction` and `raise` are both on POSIX's
    /// async-signal-safe list.
    ///
    /// One thing it does NOT try to do: coordinate with a concurrent renderer. A
    /// `progress` spinner animates from a background task, and SIGTSTP stops the
    /// whole process, so the restore/re-enter bytes can interleave with a frame
    /// that thread was midway through. Locking would be the cure and is worse
    /// than the disease — no mutex is async-signal-safe, and the worst case here
    /// is one scrambled frame that the next tick repaints, against a certain
    /// invisible cursor if we do nothing.
    fn suspendHandler(_: posix.SIG) callconv(.c) void {
        // The shell prompt is about to come back on a terminal we no longer own.
        // A hidden cursor there stays invisible until the user types `reset`.
        restore();
        // RESETHAND put SIG_DFL back on entry and NODEFER left TSTP unblocked, so
        // this suspends us here and now — and the parent sees a real job-control
        // stop, not a process that quietly ignored Ctrl-Z.
        posix.raise(posix.SIG.TSTP) catch {};
        // --- resumed by SIGCONT ---
        // RESETHAND cleared our handler on entry; re-arm it so a second Ctrl-Z
        // behaves the same, then put the takeover's display state back.
        setSuspendHandler(null);
        reenter();
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
    /// plain exit, and the signals that dump core (`SIGQUIT` and the ReleaseFast
    /// `fault_sigs`) still do. `posix.raise` is reachable on every target this branch compiles
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

// The active (top) entry, for tests that assert on what a signal would replay.
fn topBlob() []const u8 {
    const n = active.load(.acquire);
    return stack[n - 1].blob[0..stack[n - 1].blob_len];
}

test "arm registers the blob and raw mode; disarm empties the stack" {
    defer disarm();
    try std.testing.expectEqual(@as(usize, 0), active.load(.acquire));

    arm(.{ .out = test_handle, .blob = "\x1b[?25h", .raw = test_raw });
    try std.testing.expectEqual(@as(usize, 1), active.load(.acquire));
    try std.testing.expectEqualStrings("\x1b[?25h", topBlob());
    // The caller's raw mode is registered so a signal restores termios, not
    // just the cursor — the hybrid-prompt fix.
    try std.testing.expect(stack[0].raw != null);

    disarm();
    try std.testing.expectEqual(@as(usize, 0), active.load(.acquire));
}

test "arm with a null raw registers cursor-only restore" {
    defer disarm();
    arm(.{ .out = test_handle, .blob = "\x1b[?25h" });
    try std.testing.expectEqual(@as(usize, 1), active.load(.acquire));
    try std.testing.expect(stack[0].raw == null);
}

test "arm registers the suspend re-enter bytes alongside the restore blob" {
    defer disarm();
    // #762: the cooked path needs both halves — what to write before the process
    // stops, and what to write back when SIGCONT resumes it.
    arm(.{ .out = test_handle, .blob = "\x1b[?25h", .reenter = "\x1b[?25l" });
    try std.testing.expectEqualStrings("\x1b[?25h", topBlob());
    try std.testing.expectEqualStrings("\x1b[?25l", stack[0].reenter[0..stack[0].reenter_len]);
}

test "rearm replaces the top entry's blob and raw mode without stacking" {
    defer disarm();
    // The hybrid path arms with an empty blob in `init`, then `start` re-arms
    // with the cursor-show blob over the still-armed guard (#458 item 2).
    arm(.{ .out = test_handle, .blob = "", .raw = test_raw });
    try std.testing.expectEqual(@as(usize, 1), active.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), stack[0].blob_len);

    rearm(.{ .out = test_handle, .blob = "\x1b[?25h" });
    // Still one entry: a re-registration by the same session, not a nested one.
    try std.testing.expectEqual(@as(usize, 1), active.load(.acquire));
    try std.testing.expectEqualStrings("\x1b[?25h", topBlob());
    // The re-arm's fields fully replaced the prior arm's — no stale raw mode.
    try std.testing.expect(stack[0].raw == null);
}

// The #761 regression test. Before the guard became a stack, the inner `arm`
// overwrote the outer session's registration wholesale: the alt-screen leave was
// lost from the blob, the outer session's true pre-raw termios was replaced by
// whatever `enableRawMode` captured *inside* raw mode (i.e. a restore-TO-raw),
// and the inner `disarm` left the still-live outer App unguarded entirely.
test "a nested takeover stacks, and its disarm hands the outer one back" {
    defer disarm();
    const outer_blob = "\x1b[?7h\x1b[?25h\x1b[?1049l";

    // Outer: a full-screen App, holding the true pre-raw termios.
    arm(.{ .out = test_handle, .blob = outer_blob, .raw = test_raw });
    // Inner: a prompt opened inside it. Its "original" termios is the already-raw
    // one — harmless here precisely because it no longer displaces the outer's.
    arm(.{ .out = test_handle, .blob = "\x1b[?25h", .raw = test_raw });

    try std.testing.expectEqual(@as(usize, 2), active.load(.acquire));
    try std.testing.expectEqualStrings("\x1b[?25h", topBlob());
    // The outer entry is untouched underneath — a signal *during* the prompt
    // replays both, so the alt-screen still gets left.
    try std.testing.expectEqualStrings(outer_blob, stack[0].blob[0..stack[0].blob_len]);

    // The prompt closes.
    disarm();

    // The full-screen App is still guarded, with its own blob and termios.
    try std.testing.expectEqual(@as(usize, 1), active.load(.acquire));
    try std.testing.expectEqualStrings(outer_blob, topBlob());
    try std.testing.expect(stack[0].raw != null);
    try std.testing.expect(impl.installed);
}

test "nesting past max_depth drops the innermost and stays balanced" {
    defer {
        var i: usize = 0;
        while (i < max_depth) : (i += 1) disarm();
    }
    var i: usize = 0;
    while (i < max_depth) : (i += 1) {
        arm(.{ .out = test_handle, .blob = "\x1b[?25h" });
    }
    try std.testing.expectEqual(@as(usize, max_depth), active.load(.acquire));

    // One too many: dropped, not written past the end of `stack`, and not
    // allowed to displace an outer entry either.
    arm(.{ .out = test_handle, .blob = "X" });
    try std.testing.expectEqual(@as(usize, max_depth), active.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), dropped);
    try std.testing.expectEqualStrings("\x1b[?25h", topBlob());

    // Its disarm cancels the drop rather than popping a live outer entry.
    disarm();
    try std.testing.expectEqual(@as(usize, 0), dropped);
    try std.testing.expectEqual(@as(usize, max_depth), active.load(.acquire));
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

    arm(.{ .out = test_handle, .blob = "", .raw = test_raw });
    try std.testing.expect(impl.installed);
    rearm(.{ .out = test_handle, .blob = "\x1b[?25h" });
    try std.testing.expect(impl.installed);

    // One disarm against an arm + a re-arm still fully unwinds — a `rearm`
    // replaces the top entry rather than pushing a second one to pop.
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
    arm(.{ .out = test_handle, .blob = "", .raw = test_raw });
    var during: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.HUP, null, &during);
    // Sanity: the guard really did take SIGHUP over, so the assertions below are
    // testing a restore and not an install that never happened.
    try std.testing.expect(during.handler.handler != posix.SIG.IGN);

    rearm(.{ .out = test_handle, .blob = "\x1b[?25h" });
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
    try std.testing.expectEqual(@as(usize, 0), active.load(.acquire));
    disarm();
    try std.testing.expectEqual(@as(usize, 0), active.load(.acquire));
}

test "restore is a no-op after disarm" {
    arm(.{ .out = test_handle, .blob = "\x1b[?25h", .raw = test_raw });
    disarm();
    // The stack is empty, so restore returns before touching the handle or raw
    // mode — safe to call on the test handle.
    restore();
    try std.testing.expectEqual(@as(usize, 0), active.load(.acquire));
}

// The #762 regression tests. The rule is asymmetric on purpose: SIGTSTP/SIGQUIT
// are installed ONLY while every live takeover is in cooked mode, because raw
// mode clears `ISIG` and Ctrl-Z/Ctrl-\ arrive as key bytes there — installing
// then would rewrite an inherited disposition for a signal that can never fire.
test "cooked takeovers take SIGTSTP/SIGQUIT over; raw ones do not" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    defer disarm();

    // A progress indicator: a hybrid App with no raw mode, so ISIG is live.
    arm(.{ .out = test_handle, .blob = "\x1b[?25h", .reenter = "\x1b[?25l" });
    try std.testing.expect(impl.cooked_installed);

    // A prompt opened inside it turns the terminal raw, which clears ISIG —
    // the handlers must go back until it closes.
    arm(.{ .out = test_handle, .blob = "\x1b[?25h", .raw = test_raw });
    try std.testing.expect(!impl.cooked_installed);

    disarm();
    try std.testing.expect(impl.cooked_installed);

    disarm();
    try std.testing.expect(!impl.cooked_installed);
}

test "a raw-mode takeover never installs SIGTSTP/SIGQUIT" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    defer disarm();
    arm(.{ .out = test_handle, .blob = "\x1b[?25h", .raw = test_raw });
    try std.testing.expect(impl.installed);
    try std.testing.expect(!impl.cooked_installed);
}

// The effect, not the flag: real `sigaction` state read back from the kernel,
// the same bar "double arm then disarm restores the true process dispositions"
// sets for #733. A cooked takeover must hand SIGTSTP/SIGQUIT back exactly as it
// found them — a spinner in a `nohup`'d script must not come out of a prompt
// with its inherited dispositions rewritten.
test "a cooked takeover gives SIGTSTP and SIGQUIT back on disarm" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const posix = std.posix;
    defer disarm();

    var saved_tstp: posix.Sigaction = undefined;
    var saved_quit: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.TSTP, null, &saved_tstp);
    posix.sigaction(posix.SIG.QUIT, null, &saved_quit);
    defer {
        posix.sigaction(posix.SIG.TSTP, &saved_tstp, null);
        posix.sigaction(posix.SIG.QUIT, &saved_quit, null);
    }

    // Non-default dispositions, for the reason spelled out in the #733 test: a
    // SIG_DFL readback looks correct even when the bookkeeping is broken.
    var want = posix.Sigaction{
        .handler = .{ .handler = consumerTermHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TSTP, &want, null);
    posix.sigaction(posix.SIG.QUIT, &want, null);

    arm(.{ .out = test_handle, .blob = "\x1b[?25h", .reenter = "\x1b[?25l" });
    var during: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.TSTP, null, &during);
    // Sanity: the guard really did take SIGTSTP over, so the assertion below is
    // testing a restore and not an install that never happened.
    try std.testing.expect(during.handler.handler != @as(?@TypeOf(want).handler_fn, consumerTermHandler));

    // A nested raw prompt hands them back mid-flight and takes them again on
    // close — the transition that would double-capture if `cooked_installed`
    // were not gating it.
    arm(.{ .out = test_handle, .blob = "\x1b[?25h", .raw = test_raw });
    disarm();
    disarm();

    var after_tstp: posix.Sigaction = undefined;
    var after_quit: posix.Sigaction = undefined;
    posix.sigaction(posix.SIG.TSTP, null, &after_tstp);
    posix.sigaction(posix.SIG.QUIT, null, &after_quit);
    try std.testing.expectEqual(
        @as(?@TypeOf(want).handler_fn, consumerTermHandler),
        after_tstp.handler.handler,
    );
    try std.testing.expectEqual(
        @as(?@TypeOf(want).handler_fn, consumerTermHandler),
        after_quit.handler.handler,
    );
}
