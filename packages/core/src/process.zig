//! Running an external program, safely, from a command.
//!
//! Every real CLI eventually shells out — `gh`, `ssh`, `kubectl`, `git`,
//! `docker`, `op`. Hand-rolling that in a command's `execute()` reproduces the
//! same four bugs each time, so this module does it once:
//!
//! 1. **No deadlock.** The stdin write and both output drains make progress
//!    independently, so a child that writes more than one pipe buffer before
//!    consuming its input cannot wedge the parent. This is the class of bug
//!    that bit zcli twice (#430, and the pre-fix `zcli_secrets` runner).
//! 2. **Bounded capture.** Every captured stream has a byte cap, with an
//!    explicit `Overflow` policy — no `allocRemaining` turning a chatty child
//!    into an OOM.
//! 3. **No ambient environment.** `Runner` requires the `environ` map threaded
//!    down from the command context. Nothing here calls `getenv`,
//!    `std.process.getEnvMap`, or reads `std.os.environ`, and there is no
//!    constructor that omits the map.
//! 4. **Lossy termination is not lossy.** `Termination` keeps all four cases
//!    the OS can report, so a clean `exit 1` and a SIGSEGV stay distinct.
//!
//! ## What gets executed
//!
//! `Program` has no "hand `argv[0]` to the OS and hope" variant.
//! `std.process.spawn` resolves a bare `argv[0]` against the PATH of the
//! *parent* environment — not the map you passed — so an implicit lookup would
//! be an ambient lookup that the environment policy cannot reach. Every variant
//! is resolved by the runner, in the parent, to an absolute path before
//! spawning.
//!
//! ## Not a sandbox
//!
//! The child is trusted code the user installed. There is no seccomp, no job
//! object, no rlimit. What this prevents is *the environment choosing the
//! binary* and *the plumbing going wrong*, not a malicious program doing
//! malicious things once it runs. It is also not a PTY (see `zcli_testing`'s
//! harness), not a process supervisor (`zcli dev` keeps its own loop), and
//! never a shell — argv is a vector, never a string.
//!
//! ## Timeouts and concurrency
//!
//! `Options.timeout` defaults to `.none`: subprocesses legitimately run for
//! minutes (`git clone`, `docker build`) and aborting one mid-flight can leave
//! remote state worse than waiting. Set it when the child is a query rather
//! than a mutation. Whatever it is set to, the runner still terminates as long
//! as the child does.
//!
//! **What actually requires concurrency**, stated precisely because it is
//! narrower than it looks: *draining captured streams* does, and on Windows so
//! does a stdin payload (the write runs on its own task there). An `Io` that
//! cannot provide it fails with `error.ConcurrencyUnavailable` rather than
//! deadlocking. The real runtime `Io` (`std.Io.Threaded` with a pool) always
//! can, so this costs nothing in practice.
//!
//! A **timeout does not**, and the runner does not pretend otherwise. Earlier
//! revisions of this design enforced the timeout by racing a concurrent
//! `Child.wait` task, which genuinely needed concurrency; this one enforces it
//! by comparing the clock at the top of its own loop and probing the child
//! itself. A run with no captured streams and no stdin payload therefore honours
//! its deadline on a single task, with nothing but `io.sleep`. Refusing such a
//! run for lacking a capability it never uses would fail something the mechanism
//! can service. See ADR-0034.
//!
//! ## Reaping precondition
//!
//! The runner reaps its own children by polling and never calls `Child.wait` or
//! `Child.kill`, so it is the only reaper of the processes it spawns. That
//! ownership is what makes stopping a child race-free — a signal is only ever
//! sent between a probe that said "still running" and the next probe. It holds
//! only if the embedding process reaps its own children exclusively. An
//! application using `Runner` must therefore not:
//!
//! - set `SIGCHLD` to `SIG_IGN` or install it with `SA_NOCLDWAIT` (either makes
//!   the kernel auto-reap), nor
//! - run a wildcard `waitpid(-1)` / `wait()` reaper that can consume children it
//!   did not spawn.
//!
//! zcli installs none of these, so a command in a zcli CLI satisfies this by
//! construction. Where the OS offers a stable identity the runner takes it
//! anyway: Windows signals through the process `HANDLE` (inherently race-free),
//! and Linux acquires a `pidfd` right after spawn and signals through it, which
//! removes the long window between acquisition and signal. Acquisition itself
//! is still pid-keyed, so the pidfd is defense in depth rather than an escape
//! from the precondition. On macOS/BSD there is only the pid.
//!
//! What is guaranteed, unconditionally: **no signal is sent after a probe has
//! reported the identity gone.** When a probe does observe that (an `ECHILD`
//! reap), the run fails with `error.ChildReapedElsewhere`, `Phase.wait`, and no
//! `Term` — and says plainly that its stop and no-zombie guarantees do not hold
//! for that run. What is *not* guaranteed is that a violated precondition
//! produces that error at all: a child reaped and its pid recycled before the
//! first probe — or on Linux before `pidfd_open` runs — leaves nothing to
//! notice, and every later signal reaches a stranger that looks perfectly
//! healthy. Detection is the good case, not the contract. That residual window
//! is why this is a documented precondition rather than a runtime check.
//!
//! ## Scrubbing: what is and is not guaranteed
//!
//! Guaranteed, for buffers this module owns, when the `Scrub` policy applies:
//! the caller's `.secret` payload when `scrub_source` is set, and capture
//! buffers for streams marked `sensitive` — the whole allocation, not just the
//! retained prefix — on every exit path. That includes the scratch a sensitive
//! `.truncate` stream reads its discarded tail into, which is module-owned and
//! never handed back.
//!
//! **Not** guaranteed, and no amount of care here can change it:
//!
//! - **Environment values cannot be scrubbed at all.** `std.process.spawn`
//!   re-serializes the whole environment into its own arena and frees it without
//!   zeroing. There is no hook. This is why `EnvEntry` has no `sensitive` flag.
//!   **Pass secrets on stdin.**
//! - Environment values are readable by other processes for the child's lifetime
//!   regardless (`/proc/<pid>/environ` on Linux, `ps -E` as root on macOS).
//! - The child's memory, and anything the child writes to disk, is out of scope.
//! - Kernel pipe buffers are not scrubbed; neither is the page cache, swap, a
//!   hibernation image, or a core dump.
//! - Arena allocators do not return pages. With `context.allocator` a scrubbed
//!   buffer *is* zeroed in place, but the allocation is not reusable until the
//!   arena resets. Many sensitive runs in one command should use a non-arena
//!   allocator.
//! - Caller copies are the caller's problem. `Result.deinit` scrubs what it owns.
//!
//! ## Platform fidelity is not equal
//!
//! Windows has no signals, so `.signaled` is never produced there and a crash
//! cannot be distinguished from an exit *by kind*. What the runner does avoid is
//! `std`'s further loss: `Child.wait` truncates the `NTSTATUS` to `u8`, turning
//! an access violation (`0xC0000005`) into exit code `5`. Because the runner
//! reads the status itself, a status that does not fit `u8` is reported as
//! `.unknown = <full NTSTATUS>`. A *forced* Windows termination reports
//! `Diagnostic.term = null` rather than passing off the runner's own
//! `NtTerminateProcess` code as the child's.
//!
//! ## Example
//!
//! ```zig
//! var runner = context.process();
//!
//! var program_buf: [512]u8 = undefined;
//! var diag: zcli.process.Diagnostic = .{ .program_buf = &program_buf };
//!
//! var result = runner.run(.{ .search_path = "gh" }, .{
//!     .args = &.{ "api", "-X", "GET", "repos/ziglang/zig" },
//!     .stdin = .ignore,
//!     .stdout = .{ .capture = .{ .limit = 4 << 20, .overflow = .fail } },
//!     .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .boot } },
//!     .diagnostic = &diag,
//! }) catch |err| switch (diag.phase) {
//!     .resolve, .spawn => return error.GhNotInstalled,
//!     else => return err,
//! };
//! defer result.deinit();
//! try result.expectOk();
//! ```

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const native_os = builtin.os.tag;
const is_windows = native_os == .windows;
const is_linux = native_os == .linux;

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

/// Default cap on captured stdout: 10 MiB — the same number as
/// `http.default_max_response_bytes`.
pub const default_stdout_limit: usize = 10 * 1024 * 1024;

/// Default cap on captured stderr: 1 MiB.
pub const default_stderr_limit: usize = 1024 * 1024;

/// Grace between the polite and the forcible stop when a run is aborted.
pub const default_stop_grace: Io.Duration = .fromSeconds(5);

/// How long the runner keeps draining after the child is known to have exited,
/// waiting for EOF that an inheriting grandchild may be holding open.
pub const default_orphan_linger: Io.Duration = .fromMilliseconds(500);

/// The run loop's first poll interval. It doubles on every idle iteration up to
/// `max_tick`, so a child that exits in 20 ms is noticed within about a
/// millisecond of slack while a ten-minute build settles into four wakeups a
/// second.
const min_tick: Io.Duration = .fromMilliseconds(1);

/// Ceiling for the poll interval. Also the worst-case detection latency between
/// the child's exit and the run noticing it.
const max_tick: Io.Duration = .fromMilliseconds(250);

/// Scratch used to keep draining a stream that has already passed its cap
/// under `.truncate`, so the child never blocks on a full pipe.
const discard_buffer_len = 4096;

// ---------------------------------------------------------------------------
// What to run
// ---------------------------------------------------------------------------

/// How the executable is located.
///
/// **Every variant is resolved by the runner, in the parent, to an absolute
/// path before spawning.** That is what makes the guarantee mechanical rather
/// than aspirational: `std.process.spawn` never performs a PATH search for an
/// absolute `argv[0]` on either platform. It also avoids `std.process.spawnPath`,
/// which is `@panic("TODO processSpawnPath")` in all three 0.16 backends.
pub const Program = union(enum) {
    /// A path, absolute or relative to the parent's cwd. Note the asymmetry this
    /// makes explicit: a relative program path resolves against the *parent's*
    /// cwd, while `Options.cwd` sets the *child's*.
    path: []const u8,

    /// A path relative to an already-open directory.
    at: struct { dir: Io.Dir, path: []const u8 },

    /// Resolve `name` by scanning `dirs` in order for an executable file.
    /// `dirs` entries must be absolute — a relative one is `error.UnsafeSearchPath`.
    /// `name` must be a bare basename: a path-shaped name is
    /// `error.UnsafeProgramName`, since `../../bin/sh` would otherwise escape
    /// the very directories the caller listed. Use `.path` for real paths.
    in_dirs: struct { name: []const u8, dirs: []const []const u8 },

    /// Resolve `name` against the PATH in the *threaded* environ — the same map
    /// the child receives — taking the first executable match in an absolute
    /// directory. Relative and empty PATH entries (the latter meaning `.`) are
    /// skipped, never searched. `name` must be a bare basename, as for
    /// `.in_dirs`. The ordinary way to find `gh`/`kubectl`, and explicit: the
    /// caller opted into "the user's PATH decides".
    search_path: []const u8,
};

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

pub const Stdin = union(enum) {
    /// /dev/null (NUL on Windows): reads hit EOF at once. The default — a tool
    /// that unexpectedly wants to prompt fails fast instead of hanging, and can
    /// never swallow the parent's piped input.
    ignore,
    /// Inherit the parent's stdin, for deliberately interactive children.
    inherit,
    /// Write these bytes, then close stdin (EOF). Written concurrently with both
    /// drains, so any size is safe.
    bytes: []const u8,
    /// As `.bytes`, but sensitive. The runner never copies the payload — it
    /// writes straight from this slice, so there is no staging copy to leak —
    /// and `scrub_source` zeroes the caller's slice once the last byte has been
    /// handed to the OS and every task that could still be reading it has been
    /// joined.
    secret: struct {
        bytes: []u8,
        scrub_source: bool = false,
    },

    /// The bytes to feed the child, or null for the variants that use no pipe.
    fn payload(self: Stdin) ?[]const u8 {
        return switch (self) {
            .ignore, .inherit => null,
            .bytes => |b| b,
            .secret => |s| s.bytes,
        };
    }
};

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

pub const Overflow = enum {
    /// Keep the first `limit` bytes, keep draining (so the child never blocks),
    /// discard the rest.
    truncate,
    /// Abort: stop the child, reap it, return `error.OutputTooLarge`.
    fail,
};

pub const Capture = struct {
    /// Hard cap on retained bytes for this stream. Overflow is observing byte
    /// `limit + 1`; a stream producing exactly `limit` bytes is neither
    /// truncated nor a failure.
    limit: usize,
    overflow: Overflow,
    /// Treat the captured bytes as secret: the buffer is allocated once at
    /// `limit` (never grown by realloc, which would strand unscrubbable copies)
    /// and `secureZero`d per the run's `scrub` policy. Set `limit` tightly for
    /// these — a sensitive stream allocates its cap up front.
    sensitive: bool = false,
};

pub const Output = union(enum) {
    capture: Capture,
    /// The child writes straight to the parent's stream. No pipe, no cap,
    /// nothing captured.
    inherit,
    /// /dev/null (NUL).
    ignore,

    pub const stdout_default: Output = .{ .capture = .{
        .limit = default_stdout_limit,
        .overflow = .fail,
    } };
    pub const stderr_default: Output = .{ .capture = .{
        .limit = default_stderr_limit,
        .overflow = .truncate,
    } };
};

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

/// Note the absence of a `sensitive` flag. `std.process.spawn` re-serializes the
/// whole environment into its own arena (`key=value` C strings on POSIX, a
/// UTF-16 block on Windows) and frees it without zeroing, so no promise about
/// scrubbing an environment value can be kept at this layer. Pass secrets on
/// stdin.
pub const EnvEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// How the child's environment is built. Every variant starts from the `environ`
/// the `Runner` was constructed with — the map threaded down from the command
/// context. Nothing in this module calls `getenv`/`getEnvMap`.
///
/// Name matching in `allow`/`deny` follows the platform rule that
/// `std.process.Environ.Map` itself uses: exact on POSIX, case-insensitive
/// (WTF-16 uppercase folding) on Windows. One list, correct on both.
pub const Env = union(enum) {
    /// The threaded environ, verbatim.
    inherit,
    /// Only these names from the threaded environ (an unset name is absent, not
    /// an error).
    allow: []const []const u8,
    /// The threaded environ minus these names.
    deny: []const []const u8,
    /// Exactly these entries. Nothing inherited — not even PATH.
    replace: []const EnvEntry,
};

pub const EnvSpec = struct {
    policy: Env = .inherit,
    /// Applied last, over whatever `policy` produced.
    add: []const EnvEntry = &.{},
};

// ---------------------------------------------------------------------------
// Sensitivity
// ---------------------------------------------------------------------------

pub const Scrub = enum {
    /// Scrub every buffer marked sensitive, on the success and error paths
    /// alike. The default.
    always,
    /// Scrub only when the run fails. On success the caller receives live bytes
    /// on purpose — the `pass show` / `op read` shape, where the captured stdout
    /// *is* the value wanted. `Result.deinit` frees without zeroing in that case;
    /// the caller owns the wipe.
    on_failure,
    /// No scrubbing. Present so the choice is visible in source, not so it is
    /// convenient.
    never,
};

// ---------------------------------------------------------------------------
// Diagnostics: which phase failed
// ---------------------------------------------------------------------------

/// The phase a failed run died in. This cannot be recovered from the error
/// value — `error.AccessDenied` is reachable from both spawn and wait,
/// `error.Canceled` and `error.Unexpected` from every phase — so the runner
/// records it explicitly rather than pretending an error value carries
/// provenance.
pub const Phase = enum {
    /// Resolving `Program` to an absolute path, or validating the env spec.
    resolve,
    /// `std.process.spawn` itself.
    spawn,
    /// Writing the stdin payload. Not reached for a broken pipe: a child that
    /// closes its stdin early is recorded on `Result.stdin_closed_early` so that
    /// its exit status and captures survive, rather than being displaced by the
    /// write that lost the race.
    stdin,
    /// Draining stdout/stderr, including a cap trip under `.fail`.
    capture,
    /// Stopping a child that overran its timeout or its cap. `error.Timeout`
    /// itself is reported here: the run's outcome is that the runner had to stop
    /// the child, whichever phase it was in when the deadline passed. So is
    /// `error.StopFailed`, when the signal could not be delivered at all — and
    /// that one *displaces* the timeout, since "stopped and reaped" is exactly
    /// the promise `Timeout` makes and it did not hold.
    stop,
    /// Reaping the child, or learning that something else already did. The
    /// runner reaps by polling and never calls `Child.wait`.
    wait,
};

pub const Diagnostic = struct {
    /// Caller-owned scratch for the resolved program path. When non-null the
    /// runner copies the absolute path it resolved into it and sets
    /// `program_len`; when null, the path is simply not reported.
    ///
    /// It is caller storage on purpose: the runner's own copy lives in memory
    /// that teardown frees before the diagnostic is written, so a borrowed slice
    /// here would dangle exactly when someone read it. `Diagnostic` owns nothing
    /// and has no `deinit`.
    program_buf: ?[]u8 = null,

    // --- written by the runner ---
    phase: Phase = undefined,
    err: anyerror = undefined,
    program_len: usize = 0,
    /// Set when the child had already terminated and its status was known before
    /// the failing phase (e.g. a `.wait`-phase failure after a clean drain).
    term: ?Termination = null,

    /// The resolved absolute path, if a buffer was supplied and resolution got
    /// that far. Truncated (never partial-copied past the end) if the buffer is
    /// too small.
    pub fn program(self: Diagnostic) ?[]const u8 {
        const buf = self.program_buf orelse return null;
        if (self.program_len == 0) return null;
        return buf[0..self.program_len];
    }
};

// ---------------------------------------------------------------------------
// The request
// ---------------------------------------------------------------------------

/// Field defaults here are the *only* defaults. `Runner` deliberately holds no
/// `defaults: Options` of its own: with a concrete (non-optional) struct there
/// is no way to distinguish "field omitted" from "field explicitly set back to
/// its zero value", so per-runner layering would silently mis-merge. A caller
/// who wants shared policy keeps an `Options` value and copies it:
///
///     var opts = my_policy;   // a plain struct copy
///     opts.args = &.{ "api", path };
///     var r = try runner.run(.{ .search_path = "gh" }, opts);
pub const Options = struct {
    /// Arguments after the program. The runner supplies `argv[0]` from the
    /// resolved `Program`; there is no way to spoof it.
    args: []const []const u8 = &.{},
    stdin: Stdin = .ignore,
    stdout: Output = Output.stdout_default,
    stderr: Output = Output.stderr_default,
    env: EnvSpec = .{},
    /// The *child's* working directory. Unrelated to how a relative `Program` is
    /// resolved, which happens against the parent's cwd.
    cwd: std.process.Child.Cwd = .inherit,
    /// Overall wall-clock budget. `.none` (default) means no timeout. With
    /// `.none` the runner still terminates as long as the child does.
    timeout: Io.Timeout = .none,
    /// Grace between the polite and forcible stop on abort.
    stop_grace: Io.Duration = default_stop_grace,
    /// How long to keep draining after the child is known dead, in case a
    /// grandchild inherited the write end.
    orphan_linger: Io.Duration = default_orphan_linger,
    scrub: Scrub = .always,
    /// Windows only: permit executing a `.bat`/`.cmd` script. Off by default —
    /// `cmd.exe` re-parses its own command line, so argument quoting for batch
    /// scripts is a known injection class (the BatBadBunny/CVE-2024-24576
    /// family). Refusal is `error.BatchScriptRefused`.
    allow_windows_script: bool = false,
    /// Written on the failure path when non-null, naming the phase that failed.
    diagnostic: ?*Diagnostic = null,
};

// ---------------------------------------------------------------------------
// The result
// ---------------------------------------------------------------------------

pub const Captured = struct {
    /// The full allocation the runner owns. Retained bytes are `buf[0..len]`;
    /// the rest is reserve. Stored whole because a sensitive capture is
    /// allocated at its cap, and `deinit` must scrub and free *that* block, not
    /// the shortened view of it.
    buf: []u8 = &.{},
    len: usize = 0,
    /// False for a stream set to `.inherit`/`.ignore`, so "empty" is never
    /// confused with "not collected".
    captured: bool = false,
    truncated: bool = false,
    /// Bytes discarded past the cap (`.truncate` only). Zero unless `truncated`.
    dropped: u64 = 0,
    /// Carried over from this stream's `Capture.sensitive`. Stored per stream
    /// because `Result.deinit` has to scrub stdout and not stderr (or the other
    /// way round) — the request-side flag is long gone by then.
    sensitive: bool = false,

    pub fn bytes(self: Captured) []u8 {
        return self.buf[0..self.len];
    }

    /// `bytes()` minus trailing CR/LF — the shape callers want from `gh`.
    pub fn trimmed(self: Captured) []const u8 {
        return std.mem.trimEnd(u8, self.bytes(), "\r\n");
    }
};

/// How the child stopped. Mirrors `std.process.Child.Term`'s four cases exactly,
/// so nothing the OS reported is lost in translation.
///
/// This is deliberately *not* the same type as `zcli_testing`'s `Termination`
/// (`signaled: u8`, payloadless `unknown`); that package is std-only by design
/// and its type is published API. The two coexist.
pub const Termination = union(enum) {
    exited: u8,
    signaled: posix.SIG,
    stopped: posix.SIG,
    unknown: u32,

    pub fn fromChild(term: std.process.Child.Term) Termination {
        return switch (term) {
            .exited => |c| .{ .exited = c },
            .signal => |s| .{ .signaled = s },
            .stopped => |s| .{ .stopped = s },
            .unknown => |u| .{ .unknown = u },
        };
    }

    pub fn ok(self: Termination) bool {
        return self == .exited and self.exited == 0;
    }

    /// Shell convention: the real status for `.exited`, `128 + signum` for
    /// `.signaled`, 1 otherwise.
    pub fn exitCode(self: Termination) u8 {
        return switch (self) {
            .exited => |c| c,
            .signaled => |s| blk: {
                const n: u32 = @intFromEnum(s);
                break :blk if (n > 127) 255 else @intCast(128 + n);
            },
            .stopped, .unknown => 1,
        };
    }
};

/// Does a *capture* buffer get zeroed before it is released? The sensitivity
/// table lives here, in one function both exit paths call, so the policy cannot
/// drift between the success path (`Result.deinit`) and the failure path
/// (`finish`).
///
/// | | on an **error** path | at `Result.deinit` |
/// |---|---|---|
/// | `.always`     | zeroed | zeroed |
/// | `.on_failure` | zeroed | freed without zeroing |
/// | `.never`      | not zeroed | not zeroed |
fn wipesCapture(scrub: Scrub, sensitive: bool, failed: bool) bool {
    if (!sensitive) return false;
    return switch (scrub) {
        .always => true,
        .on_failure => failed,
        .never => false,
    };
}

/// Does a *staging* buffer get zeroed? Staging — the caller's `.secret` payload
/// under `scrub_source` — is zeroed under both `.always` and `.on_failure`,
/// because nothing is ever handed back from it: there is no success case in
/// which its contents are still wanted.
fn wipesStaging(scrub: Scrub) bool {
    return scrub != .never;
}

/// Does the module-owned *overflow scratch* get zeroed? Bytes past a sensitive
/// stream's cap are read into `Stream.discard` rather than into the capture
/// buffer — so `releaseCapture`, which only ever sees the allocation, cannot
/// reach them, and a sensitive truncating capture would otherwise leave the
/// discarded tail sitting in the runner's own frame.
///
/// It follows the staging column, not the capture column: nothing is ever handed
/// back from the scratch, so there is no success case in which its contents are
/// still wanted, and `.on_failure` has nothing to opt out of. Only `.never` does.
fn wipesDiscard(scrub: Scrub, sensitive: bool) bool {
    return sensitive and wipesStaging(scrub);
}

/// Release one capture buffer: wipe-then-free, in that order, decided in one
/// place. Both exit paths call this so the ordering cannot drift between them —
/// freeing before wiping would hand the allocator a live secret, and the two
/// call sites used to spell the sequence out separately.
fn releaseCapture(
    allocator: Allocator,
    buf: []u8,
    scrub: Scrub,
    sensitive: bool,
    failed: bool,
) void {
    if (buf.len == 0) return;
    if (wipesCapture(scrub, sensitive, failed)) std.crypto.secureZero(u8, buf);
    allocator.free(buf);
}

pub const Result = struct {
    term: Termination,
    stdout: Captured,
    stderr: Captured,
    allocator: Allocator,
    scrub: Scrub,
    /// An output stream never reached EOF before the child died and the orphan
    /// linger elapsed: a grandchild is still holding the write end, so the
    /// capture is complete only up to that moment.
    orphaned: bool,
    /// The child closed its stdin before the whole payload was written, so the
    /// write ended in `error.BrokenPipe`.
    ///
    /// Recorded rather than raised, and that is the contract: a child that reads
    /// part of a payload, decides it wants no more, and exits with a message on
    /// stderr has told the caller exactly what happened. Letting the broken pipe
    /// become the run's error would throw away the exit status *and* both
    /// captures in favour of the least informative half of that story — and a
    /// caller who classifies failures by exit code and stderr text (the
    /// `zcli_secrets` helpers do) would see a generic plumbing error instead.
    /// Every other stdin write failure is still a failed run, reported with
    /// `Phase.stdin`.
    stdin_closed_early: bool,

    pub fn ok(self: Result) bool {
        return self.term.ok();
    }

    pub fn exitCode(self: Result) u8 {
        return self.term.exitCode();
    }

    /// `error.CommandFailed` unless `ok()`.
    pub fn expectOk(self: Result) error{CommandFailed}!void {
        if (!self.ok()) return error.CommandFailed;
    }

    /// Frees the captured allocations, `secureZero`ing sensitive ones first
    /// where the policy says so. Idempotent.
    pub fn deinit(self: *Result) void {
        for ([_]*Captured{ &self.stdout, &self.stderr }) |c| {
            // `failed = false`: this is the successful-return column of the
            // sensitivity table. Under `.on_failure` the caller has been handed
            // live bytes on purpose and owns the wipe.
            releaseCapture(self.allocator, c.buf, self.scrub, c.sensitive, false);
            c.buf = &.{};
            c.len = 0;
        }
    }
};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Grouped for documentation — which errors each phase can produce. They are
/// *not* disjoint (`AccessDenied`, `Canceled`, `Unexpected` appear in more than
/// one), which is exactly why `Diagnostic.phase` exists.
pub const ResolveError = error{
    ProgramNotFound,
    /// A `.in_dirs` directory, or a PATH entry the caller forced, was not absolute.
    UnsafeSearchPath,
    /// A `.in_dirs`/`.search_path` name was path-shaped rather than a basename.
    UnsafeProgramName,
    /// The resolved target is a `.bat`/`.cmd` and `allow_windows_script` is off.
    BatchScriptRefused,
    /// Windows: the resolved target has a supported-extension sibling
    /// (`foo.exe` next to `foo.exe.cmd`), which the backend may fall through to.
    /// Refused rather than letting the image be chosen by that fallback.
    AmbiguousProgram,
    /// Windows: a `.path`/`.at` target with no extension, or with one the
    /// backend cannot execute. Required so the runner — not `CreateProcessW`'s
    /// PATHEXT fallback — decides which image runs.
    UnsupportedProgramExtension,
    InvalidEnvName,
    InvalidEnvValue,
};

pub const Error = ResolveError ||
    std.process.SpawnError || // spawn phase
    Io.File.Reader.Error || // capture phase
    Io.File.Writer.Error || // stdin phase
    std.process.Child.WaitError || // wait phase
    Io.ConcurrentError ||
    error{
        /// A stream observed byte `limit + 1` under `.fail`. Child stopped and reaped.
        OutputTooLarge,
        /// The run exceeded `Options.timeout`. Child stopped and reaped.
        Timeout,
        /// Something outside this runner reaped the child (a `SIGCHLD` handler,
        /// an `SA_NOCLDWAIT` disposition, a subreaper). The runner sends no
        /// further signal — the pid may already have been recycled — and its
        /// stop and no-zombie guarantees do not hold for that run. Unreachable
        /// in a process that leaves child reaping to the framework.
        ChildReapedElsewhere,
        /// A stop signal could not be delivered, so the child may still be
        /// running and will not be reaped by this runner. Reported with
        /// `Phase.stop`, and it displaces whatever prompted the stop —
        /// `error.Timeout` promises "child stopped and reaped", which would be
        /// untrue here. Distinct from `ChildReapedElsewhere`: there the identity
        /// is gone, here the runner still owns it but the OS refused. On Linux
        /// the runner deliberately does *not* retry through the raw pid, since
        /// an acquired `pidfd` is the only identity that cannot have been
        /// recycled underneath it.
        StopFailed,
    } ||
    Allocator.Error ||
    Io.Cancelable;

// ---------------------------------------------------------------------------
// The runner
// ---------------------------------------------------------------------------

pub const Runner = struct {
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,

    /// `environ` is required and borrowed — in a command, `context.environ`.
    /// Requiring it is the mechanism that keeps ambient lookups out: there is no
    /// constructor that omits it and no fallback inside.
    pub fn init(
        allocator: Allocator,
        io: Io,
        environ: *const std.process.Environ.Map,
    ) Runner {
        return .{ .allocator = allocator, .io = io, .environ = environ };
    }

    pub fn run(self: *Runner, program: Program, options: Options) Error!Result {
        return execute(self.allocator, self.io, self.environ, program, options);
    }

    /// `run` with default options and just arguments — the 90% call.
    pub fn capture(self: *Runner, program: Program, args: []const []const u8) Error!Result {
        return self.run(program, .{ .args = args });
    }
};

/// One-shot convenience for code that holds no state.
pub fn run(
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    program: Program,
    options: Options,
) Error!Result {
    return execute(allocator, io, environ, program, options);
}

// ===========================================================================
// Implementation
// ===========================================================================

/// The child's identity, taken out of the `Child` immediately after spawn.
/// Because the runner never calls `Child.wait`/`Child.kill`, nothing else ever
/// touches it — which is what makes "exactly one reaper" true by construction
/// rather than by convention.
const Identity = if (is_windows) struct {
    process: std.os.windows.HANDLE,
    thread: std.os.windows.HANDLE,
} else struct {
    pid: posix.pid_t,
    /// Linux only: a stable identity acquired right after spawn. Once held, a
    /// signal through it can never land on a recycled pid.
    pidfd: if (is_linux) ?posix.fd_t else void,
};

/// Non-blocking liveness probe. Three outcomes, and the design turns on
/// distinguishing them — collapsing the third into either of the others is what
/// produces a PID-reuse hole or a double reap.
const Probe = union(enum) {
    /// Nothing reaped; the pid/handle is still ours to signal.
    running,
    /// Reaped right here; the status is in hand. There is no follow-up wait.
    exited: Termination,
    /// Exceptional: someone else reaped it, or the OS refused. Never signal
    /// after this.
    failed: anyerror,
};

/// What a probe result licenses the runner to do next. Naming the three answers
/// is what keeps the two dangerous collapses out of the code: treating `.failed`
/// as "still mine to signal" reopens the PID-reuse hole, and treating `.exited`
/// as "now go and wait for it" double-reaps.
const Decision = enum {
    /// Nothing was reaped, so the pid/handle is still ours and signaling is
    /// permitted — until the next probe, and no longer.
    may_signal,
    /// Reaped right here; the status is already in hand, so there is no
    /// follow-up wait to make.
    reaped,
    /// Something outside this runner reaped it, or the OS refused. The pid may
    /// already have been recycled: never signal again.
    never_signal,
};

fn decide(p: Probe) Decision {
    return switch (p) {
        .running => .may_signal,
        .exited => .reaped,
        .failed => .never_signal,
    };
}

/// Widen a raw syscall return to a signed value, whatever the platform spells
/// it as (`pid_t` through libc, `usize` through the raw Linux syscalls).
fn toSigned(rc: anytype) isize {
    const T = @TypeOf(rc);
    return switch (@typeInfo(T).int.signedness) {
        .signed => @intCast(rc),
        .unsigned => @bitCast(rc),
    };
}

fn statusToTermination(status: u32) Termination {
    return if (posix.W.IFEXITED(status))
        .{ .exited = posix.W.EXITSTATUS(status) }
    else if (posix.W.IFSIGNALED(status))
        .{ .signaled = posix.W.TERMSIG(status) }
    else if (posix.W.IFSTOPPED(status))
        .{ .stopped = posix.W.STOPSIG(status) }
    else
        .{ .unknown = status };
}

/// Windows: an `NTSTATUS` exit code that does not fit `u8` is reported whole
/// rather than truncated, so `0xC0000005` cannot masquerade as `exit(5)`.
fn ntStatusToTermination(raw: u32) Termination {
    if (raw <= std.math.maxInt(u8)) return .{ .exited = @intCast(raw) };
    return .{ .unknown = raw };
}

fn probe(id: *Identity) Probe {
    if (is_windows) {
        const windows = std.os.windows;
        const immediate: windows.LARGE_INTEGER = 0;
        switch (windows.ntdll.NtWaitForSingleObject(id.process, .FALSE, &immediate)) {
            .TIMEOUT => return .running,
            windows.NTSTATUS.WAIT_0 => {
                var info: windows.PROCESS.BASIC_INFORMATION = undefined;
                return switch (windows.ntdll.NtQueryInformationProcess(
                    id.process,
                    .BasicInformation,
                    &info,
                    @sizeOf(windows.PROCESS.BASIC_INFORMATION),
                    null,
                )) {
                    .SUCCESS => .{ .exited = ntStatusToTermination(@intFromEnum(info.ExitStatus)) },
                    else => .{ .failed = error.Unexpected },
                };
            },
            else => return .{ .failed = error.Unexpected },
        }
    }
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = posix.system.waitpid(id.pid, &status, posix.W.NOHANG);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (toSigned(rc) == 0) return .running;
                return .{ .exited = statusToTermination(@bitCast(status)) };
            },
            .INTR => continue,
            .CHILD => return .{ .failed = error.ChildReapedElsewhere },
            .INVAL => return .{ .failed = error.Unexpected },
            else => return .{ .failed = error.Unexpected },
        }
    }
}

/// Block until the child is reaped. Only reachable when there is nothing left to
/// poll and no deadline to honour, where blocking beats spinning; and after a
/// `SIGKILL`, which is not ignorable.
fn blockingWait(id: *Identity) Probe {
    if (is_windows) {
        const windows = std.os.windows;
        const infinite: windows.LARGE_INTEGER = std.math.minInt(windows.LARGE_INTEGER);
        switch (windows.ntdll.NtWaitForSingleObject(id.process, .FALSE, &infinite)) {
            windows.NTSTATUS.WAIT_0 => return probe(id),
            else => return .{ .failed = error.Unexpected },
        }
    }
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = posix.system.waitpid(id.pid, &status, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (toSigned(rc) == 0) continue;
                return .{ .exited = statusToTermination(@bitCast(status)) };
            },
            .INTR => continue,
            .CHILD => return .{ .failed = error.ChildReapedElsewhere },
            else => return .{ .failed = error.Unexpected },
        }
    }
}

/// What a stop attempt actually achieved. Three cases, not two, because the
/// middle one is neither a failure nor something the runner did: the child was
/// already on its way out under its own power. Collapsing it into "delivered"
/// makes the runner claim a termination it did not cause — and on Windows that
/// claim costs a real exit status, since `forced_stop` suppresses the `Term`
/// (`NtTerminateProcess` would have overwritten it with the code we passed).
/// Collapsing it into "failed" would be worse still: `error.StopFailed` says the
/// child may still be running, which is exactly what this case rules out.
const SignalOutcome = enum {
    /// The signal reached a live child. This runner, not the child, decided how
    /// the process ends.
    delivered,
    /// There was nothing to signal — the child had already terminated, or was
    /// mid-termination. Whatever status it leaves behind is its own.
    already_terminating,
    /// The OS refused. The child may still be running, and this runner will not
    /// reap it.
    failed,
};

/// Send `sig` to the child. Only ever called between a `.running` probe and the
/// next probe, on the one task that owns the run — which is what closes the
/// PID-reuse window, given the exclusive-reaping precondition. On Linux the
/// signal goes through the `pidfd` when one was acquired, so it can never land
/// on a recycled pid even if that precondition is broken after acquisition.
/// A `.failed` outcome must be treated as a failure to stop rather than retried
/// through some other identity — see the pidfd branch for why that distinction
/// is load-bearing.
fn signalChild(id: *Identity, sig: posix.SIG) SignalOutcome {
    if (is_windows) {
        const windows = std.os.windows;
        return switch (windows.ntdll.NtTerminateProcess(id.process, @enumFromInt(1))) {
            .SUCCESS => .delivered,
            // The process was already terminating when the call arrived, so the
            // exit status it ends up with is one it chose — a natural exit that
            // merely raced this stop. Reporting delivery here would set
            // `forced_stop` and suppress that status as if we had invented it.
            .PROCESS_IS_TERMINATING => .already_terminating,
            else => .failed,
        };
    }
    if (is_linux) {
        if (id.pidfd) |fd| {
            // Once a pidfd is held it names *that* process forever, so it is the
            // only identity worth signalling through. Falling back to the raw pid
            // when it fails would reopen exactly the post-acquisition recycling
            // window the pidfd exists to close — the pid may by then belong to a
            // stranger, and `kill` would find it perfectly signalable. So a
            // failure here is reported, never retried against the pid.
            return switch (posix.errno(std.os.linux.pidfd_send_signal(fd, sig, null, 0))) {
                .SUCCESS => .delivered,
                // The child is already gone: nothing to signal, and nothing wrong.
                .SRCH => .already_terminating,
                else => .failed,
            };
        }
    }
    return switch (posix.errno(posix.system.kill(id.pid, sig))) {
        .SUCCESS => .delivered,
        .SRCH => .already_terminating,
        else => .failed,
    };
}

fn closeIdentity(id: *Identity) void {
    if (is_windows) {
        const windows = std.os.windows;
        windows.CloseHandle(id.process);
        windows.CloseHandle(id.thread);
        return;
    }
    if (is_linux) {
        if (id.pidfd) |fd| {
            // `posix.close` does not exist in 0.16; closing a raw descriptor is
            // the syscall, with `INTR` counted as success (ziglang/zig#2425).
            switch (posix.errno(posix.system.close(fd))) {
                else => {},
            }
        }
        id.pidfd = null;
    }
}

// ---------------------------------------------------------------------------
// Program resolution
// ---------------------------------------------------------------------------

/// The four extensions `std`'s Windows backend can execute. Ordered as
/// `std.process.WindowsExtension` spells them.
const windows_exts = [_][]const u8{ ".bat", ".cmd", ".com", ".exe" };

fn eqlIgnoreCaseAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// The supported extension `path` carries, if any. ASCII-case-insensitive: a
/// case-sensitive comparison would have made `.BAT` a trivial bypass of the
/// script gate.
fn supportedExtension(path: []const u8) ?std.process.WindowsExtension {
    for (windows_exts, 0..) |ext, i| {
        if (path.len > ext.len and eqlIgnoreCaseAscii(path[path.len - ext.len ..], ext)) {
            return @enumFromInt(i);
        }
    }
    return null;
}

fn isScriptExtension(e: std.process.WindowsExtension) bool {
    return e == .bat or e == .cmd;
}

/// A `.in_dirs`/`.search_path` name must be a bare basename. Without this,
/// `.in_dirs{ .name = "../../bin/sh", .dirs = &.{"/opt/trusted/bin"} }` resolves
/// *outside* every directory the caller listed — which defeats the entire point
/// of the variant. `.path` is the way to say "this exact file".
fn validBasename(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (is_windows) {
        if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;
        // A drive-relative prefix (`C:foo`) or an alternate data stream (`f:s`).
        if (std.mem.indexOfScalar(u8, name, ':') != null) return false;
    }
    return true;
}

/// PATH separator: `;` on Windows, `:` everywhere else.
const path_sep = if (is_windows) ';' else ':';

const Resolved = struct {
    /// Owned by the run's allocator.
    path: []u8,
};

/// Windows only, and applied to *every* variant. `windowsCreateProcessPathExt`
/// enumerates `app_name*` in the target directory and deliberately does not stop
/// at an exact match, so handing it `C:\d\foo.exe` still lets `C:\d\foo.exe.cmd`
/// run if the first spawn fails. Refusing the whole layout is the only way to
/// keep the runner — not the backend's fallback — in charge of which image runs.
///
/// This is a check-then-spawn, so it is TOCTOU by construction: a sibling
/// created between the check and `CreateProcessW` would not be seen. What it
/// buys is that a *pre-existing* hostile sibling cannot be reached. Winning the
/// race requires write access to the program's directory, which is already a
/// compromise of the machine.
fn checkWindowsTarget(
    io: Io,
    allocator: Allocator,
    path: []const u8,
    allow_script: bool,
) Error!void {
    if (!is_windows) return;

    var sibling_exists = false;
    for (windows_exts) |sibling_ext| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ path, sibling_ext });
        defer allocator.free(candidate);
        Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        sibling_exists = true;
        break;
    }
    return classifyWindowsTarget(path, allow_script, sibling_exists);
}

/// The decision `checkWindowsTarget` makes, separated from the four `access`
/// calls that answer `sibling_exists` — so the rules themselves are testable on
/// every platform rather than only where they fire.
///
/// The sibling refusal is unconditional, `allow_windows_script` included: a
/// `foo.exe` sitting next to a `foo.exe.cmd` has no legitimate use and is
/// exactly the shape an attacker would create to exploit the backend's PATHEXT
/// fallback. "Two candidates, refusing to guess" is more useful than silently
/// running either.
fn classifyWindowsTarget(path: []const u8, allow_script: bool, sibling_exists: bool) ResolveError!void {
    const ext = supportedExtension(path) orelse return error.UnsupportedProgramExtension;
    if (isScriptExtension(ext) and !allow_script) return error.BatchScriptRefused;
    if (sibling_exists) return error.AmbiguousProgram;
}

/// PATHEXT entries from the *child's* environment, intersected with the four
/// extensions the backend can execute, in PATHEXT order. Entries outside that
/// set are skipped rather than silently attempted.
fn windowsPathExt(env: *const std.process.Environ.Map, out: *[windows_exts.len][]const u8) []const []const u8 {
    var n: usize = 0;
    const raw = env.get("PATHEXT") orelse ".COM;.EXE;.BAT;.CMD";
    var it = std.mem.splitScalar(u8, raw, ';');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        for (windows_exts) |ext| {
            if (!eqlIgnoreCaseAscii(entry, ext)) continue;
            // De-duplicate: a PATHEXT listing the same extension twice must not
            // double the probes.
            var seen = false;
            for (out[0..n]) |already| {
                if (std.mem.eql(u8, already, ext)) seen = true;
            }
            if (!seen) {
                out[n] = ext;
                n += 1;
            }
        }
    }
    if (n == 0) {
        // A PATHEXT with nothing executable in it still has to find `gh.exe`.
        out[0] = ".exe";
        n = 1;
    }
    return out[0..n];
}

/// Search `dirs` for `name`, directory-outer / extension-inner (matching
/// `cmd.exe`). On POSIX the extension list is a single empty string, so the
/// loop degenerates to the `zcli_secrets` algorithm.
fn searchDirs(
    io: Io,
    allocator: Allocator,
    name: []const u8,
    dirs: []const []const u8,
    child_env: *const std.process.Environ.Map,
) Error![]u8 {
    if (!validBasename(name)) return error.UnsafeProgramName;

    var ext_storage: [windows_exts.len][]const u8 = undefined;
    const exts: []const []const u8 = if (is_windows)
        (if (supportedExtension(name) != null) &.{""} else windowsPathExt(child_env, &ext_storage))
    else
        &.{""};

    for (dirs) |dir| {
        if (!std.fs.path.isAbsolute(dir)) return error.UnsafeSearchPath;
        for (exts) |ext| {
            const candidate = try std.fmt.allocPrint(allocator, "{s}{c}{s}{s}", .{
                std.mem.trimEnd(u8, dir, if (is_windows) "\\/" else "/"),
                std.fs.path.sep,
                name,
                ext,
            });
            errdefer allocator.free(candidate);
            Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch {
                allocator.free(candidate);
                continue;
            };
            return candidate;
        }
    }
    return error.ProgramNotFound;
}

/// PATH entries that are relative — including the empty entry, which means `.` —
/// are skipped rather than searched. A relative entry is exactly how a hostile
/// cwd gets to choose the binary.
fn searchPath(
    io: Io,
    allocator: Allocator,
    name: []const u8,
    child_env: *const std.process.Environ.Map,
) Error![]u8 {
    if (!validBasename(name)) return error.UnsafeProgramName;
    const raw = child_env.get("PATH") orelse return error.ProgramNotFound;

    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(allocator);
    var it = std.mem.splitScalar(u8, raw, path_sep);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (!std.fs.path.isAbsolute(entry)) continue;
        try dirs.append(allocator, entry);
    }
    return searchDirs(io, allocator, name, dirs.items, child_env);
}

fn resolveProgram(
    io: Io,
    allocator: Allocator,
    program: Program,
    child_env: *const std.process.Environ.Map,
    allow_script: bool,
) Error!Resolved {
    const path: []u8 = switch (program) {
        .path => |p| blk: {
            const abs = Io.Dir.cwd().realPathFileAlloc(io, p, allocator) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.BadPathName => return error.ProgramNotFound,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ProgramNotFound,
            };
            break :blk try dupeAndFreeSentinel(allocator, abs);
        },
        .at => |a| blk: {
            const abs = a.dir.realPathFileAlloc(io, a.path, allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ProgramNotFound,
            };
            break :blk try dupeAndFreeSentinel(allocator, abs);
        },
        .in_dirs => |d| try searchDirs(io, allocator, d.name, d.dirs, child_env),
        .search_path => |name| try searchPath(io, allocator, name, child_env),
    };
    errdefer allocator.free(path);

    try checkWindowsTarget(io, allocator, path, allow_script);
    return .{ .path = path };
}

/// `realPathFileAlloc` hands back a sentinel-terminated slice; the runner keeps
/// a plain `[]u8` so every resolution path frees the same shape.
fn dupeAndFreeSentinel(allocator: Allocator, s: [:0]u8) Allocator.Error![]u8 {
    defer allocator.free(s);
    return allocator.dupe(u8, s);
}

// ---------------------------------------------------------------------------
// Environment composition
// ---------------------------------------------------------------------------

fn nameInList(name: []const u8, list: []const []const u8) bool {
    for (list) |entry| {
        if (is_windows) {
            if (std.os.windows.eqlIgnoreCaseWtf8(entry, name)) return true;
        } else if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// Validate a *caller-supplied* name. `validateKeyForPut` deliberately skips
/// index 0 on Windows so the shell's `=C:`-style drive variables survive, so a
/// leading `=` is rejected here on every platform — a caller never means to
/// define one — while inherited entries are left untouched.
fn validEnvName(name: []const u8) bool {
    if (!std.process.Environ.Map.validateKeyForPut(name)) return false;
    if (name.len > 0 and name[0] == '=') return false;
    return true;
}

/// Nothing in `std` validates values. A NUL anywhere in a value is rejected
/// (POSIX serializes `key=value` as a C string, so a NUL silently truncates the
/// value in the child), and on Windows values are WTF-8-validated up front
/// rather than surfacing as `error.InvalidWtf8` from block creation halfway
/// through a spawn.
fn validEnvValue(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return false;
    if (is_windows and !std.unicode.wtf8ValidateSlice(value)) return false;
    return true;
}

fn buildEnv(
    allocator: Allocator,
    base: *const std.process.Environ.Map,
    spec: EnvSpec,
) Error!std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(allocator);
    errdefer map.deinit();

    switch (spec.policy) {
        .inherit => {
            for (base.keys(), base.values()) |k, v| try map.put(k, v);
        },
        .allow => |list| {
            for (base.keys(), base.values()) |k, v| {
                if (nameInList(k, list)) try map.put(k, v);
            }
        },
        .deny => |list| {
            for (base.keys(), base.values()) |k, v| {
                if (!nameInList(k, list)) try map.put(k, v);
            }
        },
        .replace => |entries| {
            for (entries) |e| {
                if (!validEnvName(e.name)) return error.InvalidEnvName;
                if (!validEnvValue(e.value)) return error.InvalidEnvValue;
                try map.put(e.name, e.value);
            }
        },
    }

    for (spec.add) |e| {
        if (!validEnvName(e.name)) return error.InvalidEnvName;
        if (!validEnvValue(e.value)) return error.InvalidEnvValue;
        try map.put(e.name, e.value);
    }
    return map;
}

// ---------------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------------

/// One captured (or ignored) output stream, plus where the drained bytes land.
const Stream = struct {
    file: ?Io.File = null,
    cfg: ?Capture = null,
    buf: []u8 = &.{},
    len: usize = 0,
    truncated: bool = false,
    dropped: u64 = 0,
    eof: bool = true,
    /// An operation for this stream is currently in the batch.
    active: bool = false,
    /// The last read was aimed at `discard`, so any bytes it returned are past
    /// the cap.
    overflowing: bool = false,
    /// Backing store for the operation's `data` slice-of-slices, which must
    /// outlive submission.
    iov: [1][]u8 = .{&.{}},
    discard: [discard_buffer_len]u8 = undefined,

    fn captured(self: *const Stream, sensitive: bool) Captured {
        return .{
            .buf = self.buf,
            .len = self.len,
            .captured = self.cfg != null,
            .truncated = self.truncated,
            .dropped = self.dropped,
            .sensitive = sensitive,
        };
    }

    /// Where the next read should land. Below the cap that is the free tail of
    /// the capture buffer; at the cap it is `discard`, so the very next byte the
    /// child produces is observed as overflow without being retained.
    fn readTarget(self: *Stream, allocator: Allocator) Allocator.Error![]u8 {
        const cfg = self.cfg.?;
        if (self.len < cfg.limit) {
            if (self.len == self.buf.len) {
                // Sensitive buffers are allocated at the cap up front and never
                // reach here, so no realloc can ever strand a copy of a secret.
                const grown = @min(cfg.limit, @max(self.buf.len * 2, discard_buffer_len));
                self.buf = try allocator.realloc(self.buf, grown);
            }
            self.overflowing = false;
            const room = @min(self.buf.len, cfg.limit) - self.len;
            return self.buf[self.len..][0..room];
        }
        self.overflowing = true;
        return self.discard[0..];
    }

    /// Zero the overflow scratch. Called on both exit paths for a sensitive
    /// stream, per `wipesDiscard`: this buffer is the one place a sensitive
    /// capture's bytes land that `releaseCapture` cannot reach.
    fn wipeDiscard(self: *Stream) void {
        std.crypto.secureZero(u8, &self.discard);
    }
};

/// Windows only: the stdin write runs on its own task because the parent's
/// stdin handle is created `SYNCHRONOUS_NONALERT` and a batch write there would
/// execute inline and block. The task publishes `done` so the run loop can see
/// completion — `Io.Future` cannot be polled — and the loop joins it and closes
/// stdin the moment it does.
const WriterState = struct {
    result: Io.File.Writer.Error!void = {},
    done: std.atomic.Value(bool) = .init(false),
};

fn writeAllStreaming(io: Io, file: Io.File, bytes: []const u8) Io.File.Writer.Error!void {
    var remaining = bytes;
    while (remaining.len > 0) {
        var iov: [1][]const u8 = .{remaining};
        const result = try io.operate(.{ .file_write_streaming = .{ .file = file, .data = &iov } });
        const n = try result.file_write_streaming;
        remaining = remaining[n..];
    }
}

fn writerTask(io: Io, file: Io.File, bytes: []const u8, state: *WriterState) void {
    defer state.done.store(true, .release);
    state.result = writeAllStreaming(io, file, bytes);
}

/// Why a run is being torn down early, if it is.
const Abort = struct {
    phase: Phase,
    err: anyerror,
};

const Run = struct {
    allocator: Allocator,
    io: Io,
    opts: Options,

    identity: Identity,
    identity_open: bool = true,

    out: Stream = .{},
    err_stream: Stream = .{},

    stdin_file: ?Io.File = null,
    stdin_remaining: []const u8 = &.{},
    stdin_done: bool = true,
    stdin_active: bool = false,
    stdin_iov: [1][]const u8 = .{&.{}},
    stdin_err: ?anyerror = null,
    writer_state: if (is_windows) ?*WriterState else void = if (is_windows) null else {},
    writer_future: if (is_windows) ?Io.Future(void) else void = if (is_windows) null else {},

    storage: [3]Io.Operation.Storage = undefined,
    batch: Io.Batch = undefined,
    active_ops: usize = 0,

    term: ?Termination = null,
    orphaned: bool = false,
    /// The runner successfully signalled the child rather than letting it
    /// finish. On Windows that makes the status a subsequent probe reads back
    /// one *we* invented, so there is no honest `Term` to report for it. Set
    /// only on `SignalOutcome.delivered`: neither a refused terminate nor one
    /// that found the child already terminating produced the status it ends up
    /// with, and suppressing that would throw away a real natural-exit `Term`.
    forced_stop: bool = false,
    /// The child closed its stdin before the payload was finished, on a run that
    /// is otherwise succeeding. Carried to `Result.stdin_closed_early` instead of
    /// becoming the run's failure — see that field for why.
    stdin_closed_early: bool = false,
    /// Set when a stop signal could not be delivered. Distinguishes "we could
    /// not stop it" (phase `.stop`) from "something else reaped it" (`.wait`).
    stop_err: ?anyerror = null,

    const stdout_index: u32 = 0;
    const stderr_index: u32 = 1;
    const stdin_index: u32 = 2;

    fn streamFor(self: *Run, index: u32) *Stream {
        return switch (index) {
            stdout_index => &self.out,
            stderr_index => &self.err_stream,
            else => unreachable,
        };
    }

    fn armRead(self: *Run, index: u32) Allocator.Error!void {
        const s = self.streamFor(index);
        if (s.eof or s.active or s.file == null) return;
        s.iov[0] = try s.readTarget(self.allocator);
        self.batch.addAt(index, .{ .file_read_streaming = .{
            .file = s.file.?,
            .data = &s.iov,
        } });
        s.active = true;
        self.active_ops += 1;
    }

    fn armWrite(self: *Run) void {
        if (is_windows) return;
        if (self.stdin_done or self.stdin_active or self.stdin_file == null) return;
        self.stdin_iov[0] = self.stdin_remaining;
        self.batch.addAt(stdin_index, .{ .file_write_streaming = .{
            .file = self.stdin_file.?,
            .data = &self.stdin_iov,
        } });
        self.stdin_active = true;
        self.active_ops += 1;
    }

    fn closeStream(self: *Run, s: *Stream) void {
        if (s.file) |f| {
            f.close(self.io);
            s.file = null;
        }
    }

    fn closeStdin(self: *Run) void {
        if (self.stdin_file) |f| {
            f.close(self.io);
            self.stdin_file = null;
        }
    }

    fn streamsDone(self: *const Run) bool {
        return self.out.eof and self.err_stream.eof and self.stdin_done;
    }
};

fn execute(
    allocator: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    program: Program,
    options: Options,
) Error!Result {
    var diag_program: ?[]const u8 = null;

    // --- resolve phase -----------------------------------------------------
    var child_env = buildEnv(allocator, environ, options.env) catch |err| {
        return fail(options, .resolve, err, null, null);
    };
    var env_alive = true;
    defer if (env_alive) child_env.deinit();

    const resolved = resolveProgram(io, allocator, program, &child_env, options.allow_windows_script) catch |err| {
        return fail(options, .resolve, err, null, null);
    };
    defer allocator.free(resolved.path);
    diag_program = resolved.path;

    // --- spawn phase -------------------------------------------------------
    const payload = options.stdin.payload();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, resolved.path) catch |err| {
        return fail(options, .resolve, err, diag_program, null);
    };
    argv.appendSlice(allocator, options.args) catch |err| {
        return fail(options, .resolve, err, diag_program, null);
    };

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = options.cwd,
        .environ_map = &child_env,
        .stdin = if (payload != null) .pipe else switch (options.stdin) {
            .inherit => .inherit,
            else => .ignore,
        },
        .stdout = switch (options.stdout) {
            .capture => .pipe,
            .inherit => .inherit,
            .ignore => .ignore,
        },
        .stderr = switch (options.stderr) {
            .capture => .pipe,
            .inherit => .inherit,
            .ignore => .ignore,
        },
    }) catch |err| {
        return fail(options, .spawn, err, diag_program, null);
    };

    // The environment is re-serialized by `spawn`, so the map is dead the moment
    // it returns.
    child_env.deinit();
    env_alive = false;

    // --- take ownership ----------------------------------------------------
    //
    // `Child.wait`/`Child.kill` close these handles as part of cleanup, which
    // would pull fds out from under an in-flight read. The runner takes all
    // three plus the process identity immediately, and closes them itself.
    var run_state: Run = .{
        .allocator = allocator,
        .io = io,
        .opts = options,
        .identity = takeIdentity(&child),
    };
    run_state.stdin_file = child.stdin;
    child.stdin = null;
    run_state.out.file = child.stdout;
    child.stdout = null;
    run_state.err_stream.file = child.stderr;
    child.stderr = null;
    child.id = null;

    identityAcquired();

    return drive(&run_state, payload, diag_program);
}

/// Test-only seam: invoked on the run's own task the instant the child's
/// identity has been taken — on Linux, the instant its `pidfd` is held. Outside
/// a test build the variable does not exist at all.
///
/// It is here because the guarantee a `pidfd` actually buys — that no signal
/// sent after acquisition can land on a recycled pid — can only be exercised by
/// an external reaper acting strictly *after* acquisition, and a sleep chosen to
/// "probably" outlast the spawn is a guess rather than a handshake: too short and
/// the test asserts a guarantee the design deliberately does not make, too long
/// and it quietly stops reaching the path at all. Neither failure is visible in
/// the result.
pub var identity_acquired_hook: if (builtin.is_test) ?*const fn () void else void =
    if (builtin.is_test) null else {};

fn identityAcquired() void {
    if (builtin.is_test) {
        if (identity_acquired_hook) |hook| hook();
    }
}

fn takeIdentity(child: *std.process.Child) Identity {
    if (is_windows) {
        return .{ .process = child.id.?, .thread = child.thread_handle };
    }
    const pid = child.id.?;
    if (is_linux) {
        const rc = std.os.linux.pidfd_open(pid, 0);
        const fd: ?posix.fd_t = switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => null,
        };
        return .{ .pid = pid, .pidfd = fd };
    }
    return .{ .pid = pid, .pidfd = {} };
}

/// The one loop. It covers the drain phase, the wait phase, both
/// empty-batch-from-the-outset cases, and the transition where the last batch
/// operation completes before the reap — because it exits on the **reap**, never
/// on the pipes. A child that closes stdout/stderr early and then sleeps for a
/// minute is the ordinary case here (`ssh -f`, anything that daemonizes after
/// setup), not an exotic one.
fn drive(r: *Run, payload: ?[]const u8, diag_program: ?[]const u8) Error!Result {
    const io = r.io;
    r.batch = .init(&r.storage);

    // Configure the two output streams.
    inline for (.{ "out", "err_stream" }, .{ "stdout", "stderr" }) |field, opt_field| {
        const s = &@field(r, field);
        switch (@field(r.opts, opt_field)) {
            .capture => |c| {
                s.cfg = c;
                s.eof = false;
                if (c.sensitive and c.limit > 0) {
                    s.buf = r.allocator.alloc(u8, c.limit) catch |err| {
                        return teardownError(r, .capture, err, diag_program);
                    };
                }
            },
            .inherit, .ignore => {},
        }
    }

    // Configure stdin.
    if (payload) |bytes| {
        r.stdin_remaining = bytes;
        r.stdin_done = bytes.len == 0;
        if (r.stdin_done) r.closeStdin();
    }

    // On Windows the write cannot live in the batch (the handle is synchronous),
    // so it runs on its own task from the outset.
    if (is_windows) {
        if (payload) |bytes| {
            if (!r.stdin_done) {
                const state = r.allocator.create(WriterState) catch |err| {
                    return teardownError(r, .stdin, err, diag_program);
                };
                state.* = .{};
                r.writer_state = state;
                r.writer_future = io.concurrent(writerTask, .{ io, r.stdin_file.?, bytes, state }) catch |err| {
                    r.allocator.destroy(state);
                    r.writer_state = null;
                    return teardownError(r, .stdin, err, diag_program);
                };
            }
        }
    } else if (payload != null and !r.stdin_done) {
        // The POSIX write op in a batch is a plain blocking `writev`, and
        // `poll` reporting POLLOUT only promises that *some* write will not
        // block. Making the parent's write end nonblocking is what turns an
        // 8 MiB submission into a short write instead of a wedge. The child
        // holds the *read* end — a separate open file description — so the flag
        // does not leak into its stdin semantics.
        setNonblocking(&r.stdin_file.?) catch |err| {
            return teardownError(r, .stdin, err, diag_program);
        };
    }

    // The deadline keeps whatever clock the caller expressed it on (the module's
    // own deadlines use `.boot`, which counts time the machine spent suspended —
    // a laptop that slept for an hour did not give the child an extra hour of
    // grace). Comparisons below are always made against `now` on that same
    // clock, so no conversion is needed or attempted.
    const run_deadline: ?Io.Clock.Timestamp = r.opts.timeout.toTimestamp(io);
    var orphan_deadline: ?Io.Clock.Timestamp = null;
    var tick: Io.Duration = min_tick;

    while (true) {
        const now: Io.Clock.Timestamp = .now(io, .boot);

        if (run_deadline) |d| {
            if (Io.Clock.Timestamp.now(io, d.clock).compare(.gte, d)) {
                return abort(r, .stop, error.Timeout, diag_program);
            }
        }

        // Observing `done` closes stdin RIGHT HERE. The child cannot exit until
        // it sees EOF, and the loop cannot exit until the child does, so
        // deferring the close to teardown is a mutual wait.
        if (is_windows) {
            if (r.writer_state) |state| {
                if (state.done.load(.acquire)) {
                    _ = r.writer_future.?.await(io);
                    r.writer_future = null;
                    if (state.result) |_| {} else |e| r.stdin_err = e;
                    r.allocator.destroy(state);
                    r.writer_state = null;
                    r.stdin_done = true;
                    r.closeStdin();
                }
            }
        }

        if (orphan_deadline) |d| {
            if (now.compare(.gte, d)) {
                r.orphaned = true;
                drainStop(r);
            }
        }

        if (r.term != null and (r.streamsDone() or r.orphaned)) break;

        if (r.term == null) {
            switch (probe(&r.identity)) {
                .running => {},
                .exited => |t| {
                    r.term = t;
                    if (!r.streamsDone() and !r.orphaned) {
                        orphan_deadline = now.addDuration(.{
                            .raw = r.opts.orphan_linger,
                            .clock = .boot,
                        });
                    }
                },
                .failed => |e| return abort(r, .wait, e, diag_program),
            }
        }

        // Arm whatever is not already in flight.
        if (!r.orphaned) {
            r.armRead(Run.stdout_index) catch |e| return abort(r, .capture, e, diag_program);
            r.armRead(Run.stderr_index) catch |e| return abort(r, .capture, e, diag_program);
            r.armWrite();
        }

        var wait_ns = tick.nanoseconds;
        if (run_deadline) |d| wait_ns = @min(wait_ns, remainingNs(io, d));
        if (orphan_deadline) |d| wait_ns = @min(wait_ns, remainingNs(io, d));
        if (wait_ns < 0) wait_ns = 0;

        if (r.active_ops > 0) {
            // Never `.none`: with a single submitted operation and no timeout the
            // backend bypasses `poll` and calls `operate` directly, which turns
            // the nonblocking stdin endgame into a pegged core. Always carrying a
            // deadline makes that branch structurally unreachable.
            const deadline: Io.Timeout = .{ .deadline = now.addDuration(.{
                .raw = .{ .nanoseconds = wait_ns },
                .clock = .boot,
            }) };
            r.batch.awaitConcurrent(io, deadline) catch |e| switch (e) {
                // A tick expiry, *not* the run deadline — which is checked
                // against the clock at the top of the loop, because past its
                // deadline the backend keeps handing back ready completions
                // rather than reporting a timeout.
                error.Timeout => {},
                else => |other| return abort(r, .capture, other, diag_program),
            };
            var progressed = false;
            while (r.batch.next()) |completion| {
                progressed = true;
                handleCompletion(r, completion) catch |e| {
                    return abort(r, completionPhase(completion.index), e, diag_program);
                };
            }
            tick = if (progressed) min_tick else doubleTick(tick);
        } else if (r.term == null and r.streamsDone() and run_deadline == null) {
            // Nothing to poll and no deadline to honour: block instead of
            // spinning, so a quiet child costs zero detection latency.
            switch (blockingWait(&r.identity)) {
                .running => {},
                .exited => |t| r.term = t,
                .failed => |e| return abort(r, .wait, e, diag_program),
            }
        } else {
            io.sleep(.{ .nanoseconds = wait_ns }, .boot) catch |e| {
                return abort(r, .capture, e, diag_program);
            };
            tick = doubleTick(tick);
        }
    }

    return finish(r, null, diag_program);
}

fn doubleTick(t: Io.Duration) Io.Duration {
    const doubled = t.nanoseconds *| 2;
    return .{ .nanoseconds = @min(doubled, max_tick.nanoseconds) };
}

fn remainingNs(io: Io, deadline: Io.Clock.Timestamp) i96 {
    return deadline.durationFromNow(io).raw.nanoseconds;
}

fn completionPhase(index: u32) Phase {
    return if (index == Run.stdin_index) .stdin else .capture;
}

fn handleCompletion(r: *Run, completion: Io.Batch.Completion) Error!void {
    switch (completion.index) {
        Run.stdout_index, Run.stderr_index => {
            const s = r.streamFor(completion.index);
            s.active = false;
            r.active_ops -= 1;
            const n = completion.result.file_read_streaming catch |err| switch (err) {
                error.EndOfStream => {
                    s.eof = true;
                    r.closeStream(s);
                    return;
                },
                error.WouldBlock => return,
                else => |e| return e,
            };
            if (s.overflowing) {
                if (n == 0) return;
                // Overflow is observing byte `limit + 1`, not reaching `limit`:
                // a stream producing exactly `limit` bytes is neither truncated
                // nor a failure.
                switch (s.cfg.?.overflow) {
                    .fail => return error.OutputTooLarge,
                    .truncate => {
                        s.truncated = true;
                        s.dropped += n;
                    },
                }
                return;
            }
            s.len += n;
        },
        Run.stdin_index => {
            r.stdin_active = false;
            r.active_ops -= 1;
            const n = completion.result.file_write_streaming catch |err| switch (err) {
                error.WouldBlock => return,
                else => |e| {
                    // The child stopped reading. Stop feeding it, remember why,
                    // and let the run finish — teardown decides whether this is
                    // the story or just fallout from an abort.
                    r.stdin_err = e;
                    r.stdin_done = true;
                    r.closeStdin();
                    return;
                },
            };
            r.stdin_remaining = r.stdin_remaining[n..];
            if (r.stdin_remaining.len == 0) {
                r.stdin_done = true;
                r.closeStdin();
            }
        },
        else => unreachable,
    }
}

fn setNonblocking(file: *Io.File) Error!void {
    if (is_windows) return;
    const fd = file.handle;
    const flags = blk: {
        const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => break :blk @as(usize, @intCast(toSigned(rc))),
            else => return error.Unexpected,
        }
    };
    const with_nonblock = flags | (@as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK"));
    switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, with_nonblock))) {
        .SUCCESS => {},
        else => return error.Unexpected,
    }
    // Keep the `Io.File` copy's flags honest: the field documents the
    // descriptor, and letting them diverge is a trap for any std code that
    // branches on it.
    file.flags.nonblocking = true;
}

/// Stop draining without tearing anything down: used when the orphan linger
/// expires and the remaining EOF is never going to arrive.
fn drainStop(r: *Run) void {
    if (r.active_ops == 0) return;
    r.batch.cancel(r.io);
    while (r.batch.next()) |completion| {
        // Completions that raced the cancel still carry real bytes; take them
        // rather than dropping capture on the floor.
        handleCompletion(r, completion) catch {};
    }
    r.out.active = false;
    r.err_stream.active = false;
    r.stdin_active = false;
    r.active_ops = 0;
}

/// Stopping a child. Only ever reached with the child known running, so the
/// signal cannot land on a pid something else already reaped and the OS
/// recycled.
fn stopChild(r: *Run) Probe {
    const io = r.io;
    // Windows has no polite signal — `signalChild` is `NtTerminateProcess`
    // there, so a *delivered* call is already the forcible stop and the grace
    // loop below is only waiting for the corpse. The flag records that the stop
    // actually happened, not that it was attempted: neither a refused terminate
    // nor one that arrived at an already-terminating process invented the status
    // the child ends up with, and that status is real.
    switch (signalChild(&r.identity, .TERM)) {
        .delivered => r.forced_stop = true,
        .already_terminating => {},
        .failed => {
            r.stop_err = error.StopFailed;
            return .{ .failed = error.StopFailed };
        },
    }

    const deadline: Io.Clock.Timestamp = Io.Clock.Timestamp.now(io, .boot).addDuration(.{
        .raw = r.opts.stop_grace,
        .clock = .boot,
    });
    var tick: Io.Duration = min_tick;
    while (Io.Clock.Timestamp.now(io, .boot).compare(.lt, deadline)) {
        const p = probe(&r.identity);
        switch (decide(p)) {
            .may_signal => {},
            // Already reaped, so no follow-up blocking wait — that is the double
            // reap, and it comes back as `ECHILD`.
            .reaped, .never_signal => return p,
        }
        io.sleep(tick, .boot) catch {};
        tick = doubleTick(tick);
    }

    if (is_windows) {
        // `NtTerminateProcess` is already the forcible stop; there is no polite
        // signal to escalate from. Wait for the corpse.
        return blockingWait(&r.identity);
    }
    const before_kill = probe(&r.identity);
    switch (decide(before_kill)) {
        // Only the branch that proves nothing has been reaped escalates.
        .may_signal => {},
        .reaped, .never_signal => return before_kill,
    }
    switch (signalChild(&r.identity, .KILL)) {
        .delivered => r.forced_stop = true,
        // The child beat the escalation to it. Its own status stands.
        .already_terminating => {},
        .failed => {
            r.stop_err = error.StopFailed;
            return .{ .failed = error.StopFailed };
        },
    }
    // SIGKILL is not ignorable, so blocking for the corpse terminates.
    return blockingWait(&r.identity);
}

/// Which failure a teardown should report, given how the stop attempt ended and
/// whether a signal could be delivered. `null` means "keep the failure that
/// prompted the abort".
///
/// The asymmetry with a cancelled stdin writer is the whole point. A writer that
/// comes back `Canceled`/`BrokenPipe` is reporting noise the runner made while
/// cleaning up, so it is suppressed. A `.failed` stop is the opposite: it means
/// the runner's own guarantees have broken — the child may still be running and
/// will not be reaped by us — and `error.Timeout` explicitly promises "child
/// stopped and reaped". Reporting the timeout there would be reporting something
/// untrue, so the broken guarantee displaces it.
fn displacingReason(outcome: Probe, stop_err: ?anyerror) ?Abort {
    return switch (decide(outcome)) {
        // Either the child is still ours (nothing broke) or the stop worked.
        .may_signal, .reaped => null,
        // We still own the identity and simply could not signal through it —
        // a different broken promise from "something else reaped it", and a
        // different phase.
        .never_signal => if (stop_err) |e|
            .{ .phase = .stop, .err = e }
        else
            .{ .phase = .wait, .err = outcome.failed },
    };
}

/// Teardown for a failure that happened before the loop could start.
fn teardownError(r: *Run, phase: Phase, err: anyerror, diag_program: ?[]const u8) Error!Result {
    return abort(r, phase, err, diag_program);
}

/// Abort: stop draining, stop the child if it is still running, settle the
/// writer, reap, close, scrub, report. The order is part of the specification.
fn abort(r: *Run, phase: Phase, err: anyerror, diag_program: ?[]const u8) Error!Result {
    return finish(r, .{ .phase = phase, .err = err }, diag_program);
}

fn finish(r: *Run, abort_reason: ?Abort, diag_program: ?[]const u8) Error!Result {
    const io = r.io;
    var reason = abort_reason;

    // 1. Stop draining. `batch.cancel` leaves the batch well-defined and
    //    iterable.
    if (reason != null) drainStop(r);

    // 2. (abort only) Stop the child — never entered unless a probe says
    //    `.running`. It precedes the writer settlement because breaking the pipe
    //    usually makes that step resolve instantly; it is an ordering
    //    preference, not the thing that guarantees the writer is released.
    //
    //    A `.failed` outcome here **displaces** the primary failure rather than
    //    hiding behind it. That is the opposite of how a cancelled writer is
    //    treated (step 3), and deliberately so: a cancelled writer is noise the
    //    runner made while cleaning up, whereas `.failed` means the runner's own
    //    guarantees have broken — the child may still be running, and it will not
    //    be reaped by us. `error.Timeout` promises "child stopped and reaped",
    //    so reporting it here would be reporting something untrue.
    if (reason != null and r.term == null) {
        var outcome = probe(&r.identity);
        if (decide(outcome) == .may_signal) outcome = stopChild(r);
        if (decide(outcome) == .reaped) {
            r.term = outcome.exited;
        } else if (displacingReason(outcome, r.stop_err)) |displaced| {
            reason = displaced;
            r.term = null;
        }
    }

    // 3. Settle the stdin writer — mandatory on every path. If it published
    //    `done` it was already joined inside the loop and this is a no-op.
    //    Otherwise it is `future.cancel`, which requests cancellation *and*
    //    joins: the direct child having exited is not evidence that the write
    //    can complete, since a descendant may hold the read end.
    var writer_torn_down = false;
    if (is_windows) {
        if (r.writer_future) |*future| {
            // The direct child having exited is *not* evidence that the write can
            // complete — a descendant may hold the read end — so this is never an
            // `await`. `cancel` requests cancellation and joins, and cancellation
            // reaches the blocked `NtWriteFile` through `NtCancelSynchronousIoFile`.
            writer_torn_down = true;
            _ = future.cancel(io);
            r.writer_future = null;
        }
        if (r.writer_state) |state| {
            if (state.result) |_| {} else |e| r.stdin_err = e;
            r.allocator.destroy(state);
            r.writer_state = null;
        }
    }

    // A writer that we cancelled, or whose pipe we broke while stopping the
    // child, is reporting our own teardown back at us. Suppressing those keeps
    // the primary failure (`Timeout`, `OutputTooLarge`, the capture error) in
    // front of the caller instead of replacing it with `.stdin`/`Canceled` — and
    // keeps an orphan-linger expiry, which is a *successful* return, from being
    // turned into a failure by the cancellation it performs. A broken pipe is
    // only *ours* on the abort path, where the stop is what broke it; on a normal
    // finish it is the child's own early close, and the `Result` says so.
    const aborting = reason != null;
    if (aborting or writer_torn_down) {
        if (r.stdin_err) |e| switch (e) {
            error.Canceled => r.stdin_err = null,
            error.BrokenPipe => {
                // On a normal finish this is the child having closed its stdin
                // early, which the `Result` records rather than raises; on an
                // abort it is the pipe the runner broke itself while stopping
                // the child, and claiming the child closed it would be a lie.
                if (!aborting) r.stdin_closed_early = true;
                r.stdin_err = null;
            },
            else => {},
        };
    }

    // 4. Establish the `Term`. The child is reaped exactly once, by the probe.
    if (r.term == null and reason == null) {
        const p = blockingWait(&r.identity);
        switch (decide(p)) {
            .reaped => r.term = p.exited,
            // A blocking wait that came back without a corpse means the OS
            // refused; report it rather than asserting it cannot happen.
            .may_signal => reason = .{ .phase = .wait, .err = error.Unexpected },
            .never_signal => reason = .{ .phase = .wait, .err = p.failed },
        }
    }

    // `NtTerminateProcess` sets the exit status to the code *we* passed, so a
    // status read back after a forced Windows stop is one we invented, not one
    // the child chose. POSIX has no such problem: after `SIGKILL` the status
    // genuinely says `.signaled = .KILL`, which is real information.
    const forced_windows_kill = is_windows and r.forced_stop;

    // 5. Close everything the runner owns, after every task that could touch it
    //    has been joined.
    r.closeStream(&r.out);
    r.closeStream(&r.err_stream);
    r.closeStdin();
    if (r.identity_open) {
        closeIdentity(&r.identity);
        r.identity_open = false;
    }

    // A normal-path writer error is the story; an abort's is not. The one
    // exception is a broken pipe, which says the *child* closed its stdin first
    // — a decision the child then explains through its exit status and its
    // stderr, both of which are in hand here. Raising the write error instead
    // would discard the child's account of the run in favour of the runner's,
    // so it is recorded on the `Result` and the child's outcome stands.
    if (reason == null) {
        if (r.stdin_err) |e| {
            if (e == error.BrokenPipe) {
                r.stdin_closed_early = true;
                r.stdin_err = null;
            } else {
                reason = .{ .phase = .stdin, .err = e };
            }
        }
    }

    // 6. Scrub per policy, free, write the diagnostic, return.
    //
    // Every task that could still be reading the caller's payload has been
    // joined by now (step 3), so scrubbing it here cannot be a use-after-scrub.
    const failed = reason != null;
    if (wipesStaging(r.opts.scrub)) {
        switch (r.opts.stdin) {
            .secret => |s| if (s.scrub_source) std.crypto.secureZero(u8, s.bytes),
            else => {},
        }
    }

    const out_sensitive = if (r.out.cfg) |c| c.sensitive else false;
    const err_sensitive = if (r.err_stream.cfg) |c| c.sensitive else false;

    // The overflow scratch is module-owned and never handed back, so both exit
    // paths wipe it here. `releaseCapture` only ever sees the allocation, and a
    // sensitive *truncating* capture — `zcli_secrets`' stderr is exactly that —
    // reads everything past the cap into this scratch instead.
    if (wipesDiscard(r.opts.scrub, out_sensitive)) r.out.wipeDiscard();
    if (wipesDiscard(r.opts.scrub, err_sensitive)) r.err_stream.wipeDiscard();

    if (failed) {
        // No partial `Result` escapes: whatever both streams captured is
        // scrubbed (when the policy applies) and freed here, through the same
        // wipe-then-free helper `Result.deinit` uses.
        releaseCapture(r.allocator, r.out.buf, r.opts.scrub, out_sensitive, true);
        releaseCapture(r.allocator, r.err_stream.buf, r.opts.scrub, err_sensitive, true);

        const reported_term: ?Termination = if (forced_windows_kill) null else r.term;
        return fail(r.opts, reason.?.phase, reason.?.err, diag_program, reported_term);
    }

    return .{
        .term = r.term.?,
        .stdout = r.out.captured(out_sensitive),
        .stderr = r.err_stream.captured(err_sensitive),
        .allocator = r.allocator,
        .scrub = r.opts.scrub,
        .orphaned = r.orphaned,
        .stdin_closed_early = r.stdin_closed_early,
    };
}

/// Write the diagnostic (if the caller asked for one) and return the error.
fn fail(
    options: Options,
    phase: Phase,
    err: anyerror,
    program_path: ?[]const u8,
    term: ?Termination,
) Error {
    if (options.diagnostic) |d| {
        d.phase = phase;
        d.err = err;
        d.term = term;
        d.program_len = 0;
        if (d.program_buf) |buf| {
            if (program_path) |p| {
                const n = @min(buf.len, p.len);
                @memcpy(buf[0..n], p[0..n]);
                d.program_len = n;
            }
        }
    }
    return coerce(err);
}

/// Narrow an `anyerror` back into this module's error set. Every error the
/// runner can produce is already in `Error`; anything else is a bug in the
/// runner rather than a condition a caller can handle, and is reported as
/// `error.Unexpected` instead of widening the public set.
fn coerce(err: anyerror) Error {
    inline for (@typeInfo(Error).error_set.?) |candidate| {
        if (err == @field(Error, candidate.name)) return @field(Error, candidate.name);
    }
    return error.Unexpected;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "Termination.exitCode follows shell convention" {
    try testing.expectEqual(@as(u8, 0), (Termination{ .exited = 0 }).exitCode());
    try testing.expectEqual(@as(u8, 3), (Termination{ .exited = 3 }).exitCode());
    try testing.expectEqual(@as(u8, 1), (Termination{ .unknown = 0xC0000005 }).exitCode());
    try testing.expectEqual(@as(u8, 1), (Termination{ .stopped = @enumFromInt(19) }).exitCode());
    if (!is_windows) {
        // SIGSEGV is 11 on every POSIX platform zcli targets.
        try testing.expectEqual(@as(u8, 139), (Termination{ .signaled = @enumFromInt(11) }).exitCode());
    }
}

test "Termination.ok is true only for a clean zero exit" {
    try testing.expect((Termination{ .exited = 0 }).ok());
    try testing.expect(!(Termination{ .exited = 1 }).ok());
    try testing.expect(!(Termination{ .unknown = 0 }).ok());
}

test "ntStatusToTermination keeps a status that does not fit u8" {
    // std's `Child.wait` truncates, turning an access violation into exit code
    // 5 — indistinguishable from a deliberate `exit(5)`.
    try testing.expectEqual(Termination{ .unknown = 0xC0000005 }, ntStatusToTermination(0xC0000005));
    try testing.expectEqual(Termination{ .exited = 5 }, ntStatusToTermination(5));
}

test "Captured.trimmed drops trailing CR/LF only" {
    var buf = "hello\r\n".*;
    const c: Captured = .{ .buf = &buf, .len = buf.len, .captured = true };
    try testing.expectEqualStrings("hello", c.trimmed());
    try testing.expectEqualStrings("hello\r\n", c.bytes());
}

// What this asserts is the *idempotence* and the release of both buffers —
// calling `deinit` twice must not double-free, and both allocations must go back
// (the testing allocator's leak check is the assertion for that half). Whether a
// buffer was wiped before release is deliberately NOT checked here: it cannot be
// observed from outside the module, because `std.mem.Allocator.free` paints every
// block with `undefined` before the allocator sees it. The wipe decision is
// asserted directly against `wipesCapture`/`wipesStaging` in "the sensitivity
// table, every cell".
test "Result.deinit releases both buffers and is idempotent" {
    const a = testing.allocator;
    const secret = try a.alloc(u8, 8);
    @memset(secret, 0xAB);
    const plain = try a.alloc(u8, 8);
    @memset(plain, 0xCD);

    var result: Result = .{
        .term = .{ .exited = 0 },
        .stdout = .{ .buf = secret, .len = 8, .captured = true, .sensitive = true },
        .stderr = .{ .buf = plain, .len = 8, .captured = true, .sensitive = false },
        .allocator = a,
        .scrub = .always,
        .orphaned = false,
        .stdin_closed_early = false,
    };
    result.deinit();
    result.deinit(); // idempotent: the second call must not double-free
    try testing.expectEqual(@as(usize, 0), result.stdout.buf.len);
    try testing.expectEqual(@as(usize, 0), result.stderr.buf.len);
}

test "validBasename rejects every path-shaped name" {
    try testing.expect(validBasename("gh"));
    try testing.expect(validBasename("secret-tool"));
    try testing.expect(!validBasename(""));
    try testing.expect(!validBasename("."));
    try testing.expect(!validBasename(".."));
    try testing.expect(!validBasename("sub/tool"));
    try testing.expect(!validBasename("../../bin/sh"));
    if (is_windows) {
        try testing.expect(!validBasename("..\\x"));
        try testing.expect(!validBasename("C:tool"));
        try testing.expect(!validBasename("tool:stream"));
    }
}

test "supportedExtension classifies case-insensitively" {
    try testing.expectEqual(std.process.WindowsExtension.exe, supportedExtension("C:\\d\\gh.exe").?);
    try testing.expectEqual(std.process.WindowsExtension.bat, supportedExtension("C:\\d\\gh.BAT").?);
    try testing.expectEqual(std.process.WindowsExtension.cmd, supportedExtension("C:\\d\\gh.Cmd").?);
    try testing.expectEqual(std.process.WindowsExtension.com, supportedExtension("x.COM").?);
    try testing.expect(supportedExtension("C:\\d\\gh") == null);
    try testing.expect(supportedExtension("C:\\d\\gh.ps1") == null);
    // A bare extension with no stem is not a program named by extension.
    try testing.expect(supportedExtension(".exe") == null);
    try testing.expect(isScriptExtension(.bat));
    try testing.expect(isScriptExtension(.cmd));
    try testing.expect(!isScriptExtension(.exe));
    try testing.expect(!isScriptExtension(.com));
}

test "Windows target rules apply uniformly, whatever named the file" {
    // These run on every platform: the rules are what is under test, not the
    // four `access` calls that answer `sibling_exists`. Test 33's point is that
    // `.path` is not a bypass — std's PATHEXT fallback keys off what is in the
    // directory, not off how the runner arrived at the name.
    try classifyWindowsTarget("C:\\d\\gh.exe", false, false);
    try classifyWindowsTarget("C:\\d\\gh.COM", false, false);

    // No extension, or one the backend cannot execute: the runner refuses rather
    // than letting `CreateProcessW` pick the image.
    try testing.expectError(error.UnsupportedProgramExtension, classifyWindowsTarget("C:\\d\\gh", false, false));
    try testing.expectError(error.UnsupportedProgramExtension, classifyWindowsTarget("C:\\d\\gh.ps1", false, false));

    // Scripts are refused by default and permitted by opt-in — case-insensitively.
    try testing.expectError(error.BatchScriptRefused, classifyWindowsTarget("C:\\d\\gh.cmd", false, false));
    try testing.expectError(error.BatchScriptRefused, classifyWindowsTarget("C:\\d\\gh.BAT", false, false));
    try classifyWindowsTarget("C:\\d\\gh.cmd", true, false);

    // A sibling refuses regardless of `allow_windows_script`.
    try testing.expectError(error.AmbiguousProgram, classifyWindowsTarget("C:\\d\\gh.exe", false, true));
    try testing.expectError(error.AmbiguousProgram, classifyWindowsTarget("C:\\d\\gh.exe", true, true));

    // The script gate is checked before the sibling check, so a refused script
    // reports why it was refused rather than that it was ambiguous.
    try testing.expectError(error.BatchScriptRefused, classifyWindowsTarget("C:\\d\\gh.cmd", false, true));
}

test "windowsPathExt keeps PATHEXT order, drops what cannot be executed" {
    const a = testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("PATHEXT", ".PS1;.EXE;.CMD;.EXE");

    var storage: [windows_exts.len][]const u8 = undefined;
    const got = windowsPathExt(&env, &storage);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings(".exe", got[0]);
    try testing.expectEqualStrings(".cmd", got[1]);
}

test "windowsPathExt defaults when PATHEXT is absent or useless" {
    const a = testing.allocator;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();

    var storage: [windows_exts.len][]const u8 = undefined;
    const defaulted = windowsPathExt(&env, &storage);
    try testing.expectEqual(@as(usize, 4), defaulted.len);

    try env.put("PATHEXT", ".PS1;.VBS");
    const fallback = windowsPathExt(&env, &storage);
    try testing.expectEqual(@as(usize, 1), fallback.len);
    try testing.expectEqualStrings(".exe", fallback[0]);
}

test "env composition: inherit, allow, deny, replace, and add layering" {
    const a = testing.allocator;
    var base: std.process.Environ.Map = .init(a);
    defer base.deinit();
    try base.put("PATH", "/bin");
    try base.put("HOME", "/home/x");
    try base.put("SECRET", "s3cr3t");

    {
        var m = try buildEnv(a, &base, .{ .policy = .inherit });
        defer m.deinit();
        try testing.expectEqual(@as(usize, 3), m.count());
        try testing.expectEqualStrings("/bin", m.get("PATH").?);
    }
    {
        var m = try buildEnv(a, &base, .{ .policy = .{ .allow = &.{"PATH"} } });
        defer m.deinit();
        try testing.expectEqual(@as(usize, 1), m.count());
        try testing.expect(m.get("SECRET") == null);
    }
    {
        var m = try buildEnv(a, &base, .{ .policy = .{ .deny = &.{"SECRET"} } });
        defer m.deinit();
        try testing.expectEqual(@as(usize, 2), m.count());
        try testing.expect(m.get("SECRET") == null);
        try testing.expectEqualStrings("/home/x", m.get("HOME").?);
    }
    {
        // `.replace` inherits nothing — not even PATH.
        var m = try buildEnv(a, &base, .{ .policy = .{ .replace = &.{
            .{ .name = "ONLY", .value = "1" },
        } } });
        defer m.deinit();
        try testing.expectEqual(@as(usize, 1), m.count());
        try testing.expect(m.get("PATH") == null);
    }
    {
        // `add` is applied last, over whatever the policy produced.
        var m = try buildEnv(a, &base, .{
            .policy = .inherit,
            .add = &.{.{ .name = "PATH", .value = "/override" }},
        });
        defer m.deinit();
        try testing.expectEqualStrings("/override", m.get("PATH").?);
    }
}

test "env name matching follows the platform rule" {
    const a = testing.allocator;
    var base: std.process.Environ.Map = .init(a);
    defer base.deinit();
    try base.put("Path", "/bin");

    var m = try buildEnv(a, &base, .{ .policy = .{ .allow = &.{"PATH"} } });
    defer m.deinit();
    if (is_windows) {
        try testing.expectEqual(@as(usize, 1), m.count());
    } else {
        try testing.expectEqual(@as(usize, 0), m.count());
    }
}

test "env validation rejects bad names and values" {
    const a = testing.allocator;
    var base: std.process.Environ.Map = .init(a);
    defer base.deinit();

    try testing.expectError(error.InvalidEnvName, buildEnv(a, &base, .{
        .add = &.{.{ .name = "", .value = "x" }},
    }));
    try testing.expectError(error.InvalidEnvName, buildEnv(a, &base, .{
        .add = &.{.{ .name = "A=B", .value = "x" }},
    }));
    try testing.expectError(error.InvalidEnvName, buildEnv(a, &base, .{
        .add = &.{.{ .name = "A\x00B", .value = "x" }},
    }));
    // `validateKeyForPut` deliberately skips index 0 on Windows so `=C:` drive
    // variables survive; a caller-supplied one is rejected on every platform.
    try testing.expectError(error.InvalidEnvName, buildEnv(a, &base, .{
        .add = &.{.{ .name = "=C:", .value = "x" }},
    }));
    try testing.expectError(error.InvalidEnvValue, buildEnv(a, &base, .{
        .add = &.{.{ .name = "A", .value = "x\x00y" }},
    }));
    try testing.expectError(error.InvalidEnvName, buildEnv(a, &base, .{
        .policy = .{ .replace = &.{.{ .name = "=X", .value = "1" }} },
    }));
}

test "in_dirs rejects a relative directory and a path-shaped name" {
    const a = testing.allocator;
    const io = testing.io;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();

    try testing.expectError(error.UnsafeSearchPath, searchDirs(io, a, "sh", &.{"relative/dir"}, &env));
    try testing.expectError(error.UnsafeProgramName, searchDirs(io, a, "../../bin/sh", &.{"/usr/bin"}, &env));
    try testing.expectError(error.UnsafeProgramName, searchPath(io, a, "sub/tool", &env));
}

test "search_path skips relative and empty PATH entries" {
    const a = testing.allocator;
    const io = testing.io;
    if (is_windows) return error.SkipZigTest;

    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    // An empty entry means `.`, and a relative one is how a hostile cwd gets to
    // pick the binary. Neither is searched, so with only those two the lookup
    // fails rather than finding something in the working directory.
    try env.put("PATH", ":relative/bin:");
    try testing.expectError(error.ProgramNotFound, searchPath(io, a, "sh", &env));

    try env.put("PATH", ":relative/bin:/bin");
    const found = searchPath(io, a, "sh", &env) catch return error.SkipZigTest;
    defer a.free(found);
    try testing.expect(std.fs.path.isAbsolute(found));
    try testing.expectEqualStrings("/bin/sh", found);
}

test "resolution yields an absolute path for every variant" {
    if (is_windows) return error.SkipZigTest;
    const a = testing.allocator;
    const io = testing.io;

    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("PATH", "/bin:/usr/bin");

    for ([_]Program{
        .{ .path = "/bin/sh" },
        .{ .in_dirs = .{ .name = "sh", .dirs = &.{"/bin"} } },
        .{ .search_path = "sh" },
    }) |program| {
        const r = resolveProgram(io, a, program, &env, false) catch continue;
        defer a.free(r.path);
        try testing.expect(std.fs.path.isAbsolute(r.path));
    }
}

test "a missing program is ProgramNotFound, not a spawn failure" {
    const a = testing.allocator;
    const io = testing.io;
    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();
    try env.put("PATH", if (is_windows) "C:\\Windows\\System32" else "/bin:/usr/bin");

    try testing.expectError(error.ProgramNotFound, resolveProgram(
        io,
        a,
        .{ .search_path = "zcli-no-such-program-anywhere" },
        &env,
        false,
    ));
    try testing.expectError(error.ProgramNotFound, resolveProgram(
        io,
        a,
        .{ .path = "/nonexistent/zcli-no-such-program" },
        &env,
        false,
    ));
}

test "Diagnostic reports the resolved path only when given a buffer" {
    const a = testing.allocator;
    const io = testing.io;
    if (is_windows) return error.SkipZigTest;

    var env: std.process.Environ.Map = .init(a);
    defer env.deinit();

    var program_buf: [512]u8 = undefined;
    var diag: Diagnostic = .{ .program_buf = &program_buf };
    try testing.expect(diag.program() == null);

    // A resolve-phase failure has no program to report even with a buffer.
    var runner = Runner.init(a, io, &env);
    try testing.expectError(error.ProgramNotFound, runner.run(
        .{ .path = "/nonexistent/zcli-no-such-program" },
        .{ .diagnostic = &diag },
    ));
    try testing.expectEqual(Phase.resolve, diag.phase);
    try testing.expect(diag.program() == null);

    var no_buf: Diagnostic = .{};
    try testing.expectError(error.ProgramNotFound, runner.run(
        .{ .path = "/nonexistent/zcli-no-such-program" },
        .{ .diagnostic = &no_buf },
    ));
    try testing.expect(no_buf.program() == null);
}

test "Diagnostic.program truncates rather than overrunning a small buffer" {
    var small: [4]u8 = undefined;
    var diag: Diagnostic = .{ .program_buf = &small };
    try testing.expectEqual(
        Error.ProgramNotFound,
        fail(.{ .diagnostic = &diag }, .resolve, error.ProgramNotFound, "/a/very/long/path", null),
    );
    try testing.expectEqualStrings("/a/v", diag.program().?);
}

test "coerce keeps a known error and folds an unknown one" {
    try testing.expectEqual(Error.Timeout, coerce(error.Timeout));
    try testing.expectEqual(Error.ProgramNotFound, coerce(error.ProgramNotFound));
    try testing.expectEqual(Error.Unexpected, coerce(error.SomethingNobodyDeclared));
}

test "the sensitivity table, every cell" {
    // Asserted here rather than end to end because it cannot be observed from
    // outside: `std.mem.Allocator.free` paints every released block with
    // `undefined` before the allocator ever sees it, so a test watching frees
    // cannot tell a scrubbed buffer from an unscrubbed one. This is the function
    // both exit paths actually call.
    for ([_]bool{ false, true }) |failed| {
        // A non-sensitive stream is never wiped, whatever the policy.
        try testing.expect(!wipesCapture(.always, false, failed));
        try testing.expect(!wipesCapture(.on_failure, false, failed));
        try testing.expect(!wipesCapture(.never, false, failed));
        // `.never` is never wiped either. It exists so the choice is visible in
        // source, not so it is convenient.
        try testing.expect(!wipesCapture(.never, true, failed));
        // `.always` wipes on both paths.
        try testing.expect(wipesCapture(.always, true, failed));
    }

    // `.on_failure` is the whole point of the distinction: live bytes on the way
    // out, wiped when the run failed.
    try testing.expect(!wipesCapture(.on_failure, true, false));
    try testing.expect(wipesCapture(.on_failure, true, true));

    // Staging has no success case in which its contents are still wanted, so it
    // is wiped under both scrubbing policies.
    try testing.expect(wipesStaging(.always));
    try testing.expect(wipesStaging(.on_failure));
    try testing.expect(!wipesStaging(.never));
}

test "a broken stop displaces the failure that prompted it" {
    // The abort path's rule, asserted directly because the race that produces it
    // cannot be staged on demand. A timeout is only reported when the promise
    // attached to it — "child stopped and reaped" — actually held.
    try testing.expect(displacingReason(.running, null) == null);
    try testing.expect(displacingReason(.{ .exited = .{ .exited = 0 } }, null) == null);

    // Something else reaped it: the identity is gone, so the runner never signals
    // again and says which promise broke.
    const reaped_elsewhere = displacingReason(.{ .failed = error.ChildReapedElsewhere }, null).?;
    try testing.expectEqual(Phase.wait, reaped_elsewhere.phase);
    try testing.expectEqual(@as(anyerror, error.ChildReapedElsewhere), reaped_elsewhere.err);

    // We still own the identity but could not signal through it — a different
    // broken promise, and a different phase.
    const unsignalable = displacingReason(.{ .failed = error.StopFailed }, error.StopFailed).?;
    try testing.expectEqual(Phase.stop, unsignalable.phase);
    try testing.expectEqual(@as(anyerror, error.StopFailed), unsignalable.err);

    // A delivered signal never displaces, whatever else went wrong first.
    try testing.expect(displacingReason(.{ .exited = .{ .signaled = @enumFromInt(9) } }, null) == null);
}

test "the three probe outcomes stay three" {
    // The deterministic half of the exit-during-abort test. A race cannot be
    // made to hit both orderings on demand, so the branch logic is asserted
    // directly and the stress run below only asserts that whichever orderings
    // occur are clean.
    try testing.expectEqual(Decision.may_signal, decide(.running));
    try testing.expectEqual(Decision.reaped, decide(.{ .exited = .{ .exited = 0 } }));
    try testing.expectEqual(Decision.never_signal, decide(.{ .failed = error.ChildReapedElsewhere }));

    // `.exited` already carries the status, which is what makes the follow-up
    // blocking wait — and its `ECHILD` — unnecessary rather than merely avoided.
    const p: Probe = .{ .exited = .{ .exited = 7 } };
    try testing.expectEqual(@as(u8, 7), p.exited.exitCode());
}

test "Stream.readTarget switches to the discard buffer at the cap" {
    const a = testing.allocator;
    var s: Stream = .{ .cfg = .{ .limit = 4, .overflow = .truncate }, .eof = false };
    defer if (s.buf.len > 0) a.free(s.buf);

    const first = try s.readTarget(a);
    try testing.expect(!s.overflowing);
    try testing.expectEqual(@as(usize, 4), first.len);

    s.len = 4;
    const at_cap = try s.readTarget(a);
    try testing.expect(s.overflowing);
    try testing.expectEqual(@as(usize, discard_buffer_len), at_cap.len);
}

test "the overflow scratch follows the staging column, not the capture column" {
    // Nothing is ever handed back from the scratch, so there is no success case
    // in which its contents are still wanted: `.on_failure` has nothing to opt
    // out of, and only `.never` does.
    try testing.expect(wipesDiscard(.always, true));
    try testing.expect(wipesDiscard(.on_failure, true));
    try testing.expect(!wipesDiscard(.never, true));

    // A non-sensitive stream is never wiped, whatever the policy.
    try testing.expect(!wipesDiscard(.always, false));
    try testing.expect(!wipesDiscard(.on_failure, false));
    try testing.expect(!wipesDiscard(.never, false));
}

test "wipeDiscard zeroes the tail a sensitive truncating capture threw away" {
    // The reachable shape: `zcli_secrets` captures stderr `sensitive` with
    // `.truncate`, so every byte past its cap is read into this scratch — the one
    // place a sensitive stream's bytes land that `releaseCapture` never sees,
    // because it is not part of any allocation.
    const a = testing.allocator;
    var s: Stream = .{
        .cfg = .{ .limit = 4, .overflow = .truncate, .sensitive = true },
        .eof = false,
    };
    s.buf = try a.alloc(u8, 4);
    defer a.free(s.buf);

    s.len = 4;
    const scratch = try s.readTarget(a);
    try testing.expect(s.overflowing);
    // Filled whole, not just the six interesting bytes: the scratch starts
    // `undefined`, and a release build's `undefined` may be zero already.
    @memset(scratch, 0x5a);
    @memcpy(scratch[0..6], "secret");
    try testing.expect(!std.mem.allEqual(u8, &s.discard, 0));

    s.wipeDiscard();
    try testing.expect(std.mem.allEqual(u8, &s.discard, 0));
}

test "a sensitive stream is allocated at its cap and never grows" {
    const a = testing.allocator;
    var s: Stream = .{ .cfg = .{ .limit = 32, .overflow = .fail, .sensitive = true }, .eof = false };
    s.buf = try a.alloc(u8, 32);
    defer a.free(s.buf);
    const original = s.buf.ptr;

    s.len = 16;
    _ = try s.readTarget(a);
    try testing.expectEqual(original, s.buf.ptr);
    try testing.expectEqual(@as(usize, 32), s.buf.len);
}
