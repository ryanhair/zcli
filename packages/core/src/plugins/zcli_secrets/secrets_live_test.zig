//! Live round-trip test for the host OS's native `zcli_secrets` backend.
//!
//! This actually writes to, reads from, and deletes from the real OS keychain,
//! so it is **not** part of the default `test` step (it would mutate a
//! developer's login keychain and, on Linux, needs a running Secret Service).
//! It is wired into the dedicated `test-secrets-live` build step, which CI runs
//! on each platform after preparing the environment (see `.github/workflows`).
//!
//! It deliberately drives the plugin's **public API** (`ContextData` +
//! `context.plugins.zcli_secrets.<op>(...)`) through a mock context —
//! `initContextData` captures references off it once, exactly as the framework
//! does — not the backend module directly, so this is the one place the generic
//! API surface is actually instantiated and compiled, on every platform in CI.
//!
//! Run locally with, from `packages/core`: `zig build test-secrets-live`.

const std = @import("std");
const builtin = @import("builtin");
const plugin = @import("plugin.zig");

/// Minimal stand-in for the framework Context — the plugin's storage methods
/// read `allocator`, `app_name`, and (for the Linux shell-out backend) `io` and
/// `environ` off it.
const MockContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    app_name: []const u8,
    err_writer: *std.Io.Writer,

    /// The plugin surfaces backend diagnostics via `context.stderr()`; the
    /// live test discards them (they only fire on error paths).
    pub fn stderr(self: *const MockContext) *std.Io.Writer {
        return self.err_writer;
    }
};

// A throwaway service name that will not collide with real credentials, cleaned
// up at both ends of the test.
const service = "zcli-secrets-ci-roundtrip";
const name = "token";

// A distinct key for the concurrency test so it can never collide with the
// round-trip test's `token` (the two tests can run back to back in one process).
const race_name = "race-token";

/// True when the active Linux backend is the Secret Service — either forced by
/// CI via `ZCLI_SECRETS_BACKEND=secret-service` (how the two Linux live steps are
/// made deterministic) or autodetected. The large-value assertion branches on
/// this because the Secret Service caps a stored value at ~6 KiB while `pass` and
/// the macOS Keychain do not. On non-Linux this is always false (Windows is
/// handled by its own branch; macOS has no cap).
fn isSecretServiceBackend(env: *const std.process.Environ.Map) bool {
    if (builtin.os.tag != .linux) return false;
    // CI forces the backend per step, so the override is the reliable signal.
    if (env.get("ZCLI_SECRETS_BACKEND")) |choice|
        return std.mem.eql(u8, choice, "secret-service");
    // No override: a live session bus means the Secret Service is the autodetected
    // choice. (Local ad-hoc runs; CI always sets the override.)
    return env.get("DBUS_SESSION_BUS_ADDRESS") != null;
}

/// Populate `env` from the real process environment.
///
/// The Linux backend shells out to secret-tool / pass / gpg, which need the real
/// process environment (session bus, HOME, gpg-agent) that CI set up. 0.16
/// exposes the environment only via `std.process.Init` (unavailable in a test) or
/// the libc `std.c.environ`, so this CI-only test links libc to read it (see
/// build.zig). On macOS/Windows the keychain backends ignore `environ`, so an
/// empty map on Windows is fine.
fn loadEnviron(env: *std.process.Environ.Map) !void {
    if (builtin.os.tag == .windows) return;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const pair = std.mem.span(entry); // "KEY=VALUE"
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (eq == 0) continue;
        try env.put(pair[0..eq], pair[eq + 1 ..]);
    }
}

/// Look up a single environment variable via libc's `getenv` (this test links
/// libc on every target). Used only to read the concurrency-test's own role
/// control variable in the parent and each re-exec'd child — a spot where there is
/// no context to thread `environ` through yet. `getenv` (unlike iterating
/// `std.c.environ`) links uniformly across OSes, including Windows where the POSIX
/// `environ` symbol is absent.
fn envValue(key: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(key) orelse return null;
    return std.mem.span(v);
}

test "public API round-trips set / get / overwrite / delete via ContextData" {
    // In a re-exec'd child of the concurrency test below, this process is only
    // meant to run one racing loop — skip the (unrelated) round-trip so the child
    // does no extra keychain work and does not race its own sentinel.
    if (envValue(race_role_env) != null) return error.SkipZigTest;

    const a = std.testing.allocator;

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try loadEnviron(&env);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var ctx = MockContext{ .allocator = a, .io = std.testing.io, .environ = &env, .app_name = service, .err_writer = &discard.writer };
    var data: plugin.ContextData = .{};
    try plugin.initContextData(&data, &ctx);

    // Start from a clean slate even if a prior aborted run left an entry.
    try data.delete(name);
    try std.testing.expect((try data.get(name)) == null);

    // Store and read back.
    try data.set(name, "first-value");
    {
        const v = (try data.get(name)).?;
        defer a.free(v);
        try std.testing.expectEqualStrings("first-value", v);
    }

    // Overwrite an existing entry.
    try data.set(name, "second-value");
    {
        const v = (try data.get(name)).?;
        defer a.free(v);
        try std.testing.expectEqualStrings("second-value", v);
    }

    // A value with an embedded NUL and a high byte — the reason the shell-out
    // backends base64-wrap values; must round-trip byte-for-byte everywhere.
    const binary = [_]u8{ 'a', 0x00, 'b', 0xff, 0x0a };
    try data.set(name, &binary);
    {
        const v = (try data.get(name)).?;
        defer a.free(v);
        try std.testing.expectEqualSlices(u8, &binary, v);
    }

    // An empty value must round-trip (a distinct edge from "key absent" → null).
    try data.set(name, "");
    {
        const v = (try data.get(name)).?;
        defer a.free(v);
        try std.testing.expectEqualStrings("", v);
    }

    // Large-value behavior is backend-specific, so assert per backend:
    //
    //  - Windows Credential Manager caps a blob at 2560 bytes → SecretTooLarge.
    //  - The Linux Secret Service backend caps a stored value at ~6 KiB
    //    (`secret-tool` reads the secret into a fixed 8192-byte stdin buffer and
    //    silently truncates the rest); we reject/verify that as SecretTooLarge
    //    rather than store a corrupt value. A value comfortably under the cap must
    //    still round-trip exactly.
    //  - macOS Keychain and the Linux `pass` backend have no such cap, so a large
    //    value must round-trip intact — this also exercises the shell-out
    //    subprocess past the ~64 KiB OS pipe buffer (the size that used to
    //    deadlock the stdin write against an undrained stdout).
    {
        const big = try a.alloc(u8, 200 * 1024);
        defer a.free(big);
        for (big, 0..) |*b, i| b.* = @intCast('A' + (i % 26));

        if (builtin.os.tag == .windows) {
            try std.testing.expectError(plugin.Error.SecretTooLarge, data.set(name, big));
        } else if (isSecretServiceBackend(&env)) {
            // 200 KiB is far past the ~6 KiB cap → must fail cleanly, never store
            // a truncated secret.
            try std.testing.expectError(plugin.Error.SecretTooLarge, data.set(name, big));

            // A value comfortably under the cap (4 KiB raw → ~5.5 KiB base64,
            // within the 8192 stdin buffer) must round-trip exactly.
            const under = try a.alloc(u8, 4 * 1024);
            defer a.free(under);
            for (under, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
            try data.set(name, under);
            const v = (try data.get(name)).?;
            defer a.free(v);
            try std.testing.expectEqualSlices(u8, under, v);
        } else {
            // macOS Keychain / Linux `pass`: no cap, round-trips the large value.
            try data.set(name, big);
            const v = (try data.get(name)).?;
            defer a.free(v);
            try std.testing.expectEqualSlices(u8, big, v);
        }
    }

    // Delete, confirm gone, and confirm a second delete is a no-op.
    try data.delete(name);
    try std.testing.expect((try data.get(name)) == null);
    try data.delete(name);

    // A NUL in the *name* is rejected before any backend call.
    try std.testing.expectError(plugin.Error.InvalidSecretName, data.get("bad\x00name"));
}

// ---------------------------------------------------------------------------
// Concurrent-access race
// ---------------------------------------------------------------------------
//
// This exercises the macOS Keychain `set` retry (PR #234): its store path is
// Add → (on duplicate) Find → Modify, which has *two* TOCTOU windows — a
// concurrent `delete` landing between our Add and our Find, or between our Find
// and our Modify, makes the later call return `errSecItemNotFound`; the bounded
// retry re-Adds rather than surfacing an opaque `KeychainFailure`. Nothing raced
// `set` against `delete` before, so that retry had never actually run. This drives
// it live: one worker hammers `set` with distinct values while two others hammer
// `delete`, all against the same key.
//
// ## Why the racers are separate *processes*, not threads
//
// The realistic scenario the retry defends against is two CLI *invocations*
// racing (a `login` writing a token while a `logout` deletes it) — separate
// processes contending on the shared OS store, which is exactly what a keychain /
// Secret Service is built to serialize. It is NOT two threads in one process:
// macOS's legacy `SecKeychain*GenericPassword` API (what `keychain_macos.zig`
// uses) is not safe for concurrent same-process mutation of one item — two threads
// doing Add/Modify vs Delete deadlock inside Security.framework's own
// `securityd`-side mutex (observed via `sample`: both threads blocked in
// `_pthread_mutex_firstfit_lock_wait` under `SecKeychainItemDelete` /
// `SecKeychainItemModifyAttributesAndData`). That deadlock is an Apple-API
// limitation, not a zcli bug, and a CLI is single-threaded anyway — so racing with
// threads would only manufacture a hang that no product code path can hit. Racing
// with processes models the real contention and lets the OS store arbitrate it.
//
// The test re-exec's *itself*: `std.process.executablePath` gives this test
// binary's path, and each child is spawned with `ZCLI_SECRETS_RACE_ROLE` set to
// `set` or `delete`, which the `main`-level guard below turns into a single racing
// loop. (This also naturally covers Linux — its backends already fork a helper per
// op — and Windows.)
//
// ## Acceptable outcomes
//
// The store is inherently concurrent, so the *only* acceptable per-op outcomes are
// success or benign key-not-found semantics (`get` → null, `delete` of an absent
// key → ok) — both `void`/`ok` through this public API (a missing key is never an
// error; see plugin.zig). A child that hit anything else (notably `BackendFailure`,
// the pre-#234 symptom) exits nonzero, which the parent asserts against. What is
// NOT acceptable: an opaque backend failure, a hang (bounded loops + the parent
// `wait`s), or a final state that is neither "present and readable" nor "absent".

/// Env var naming the child's racing role: `set` or `delete`. Absent in the parent.
const race_role_env = "ZCLI_SECRETS_RACE_ROLE";

/// Iterations per racing child. Each `set`/`delete` is a full store round-trip
/// (an FFI pair on macOS/Windows, a spawned helper on Linux), so this is kept
/// modest to keep wall time to a couple of seconds while still giving many chances
/// for a `delete` to land in a `set`'s window (and for the deleters to race each
/// other). The Linux per-op subprocess is heavier, so it runs fewer passes.
const race_iterations: usize = if (builtin.os.tag == .linux) 40 else 150;

/// The race is deliberately **one setter vs two deleters** — the realistic shape of
/// the contention this hardening defends against (one `login` writing a token while
/// `logout`/expiry race it), with a second deleter for two reasons: it widens the
/// odds a `delete` lands inside the setter's tiny cross-process Add→Find→Modify
/// window (which `securityd`'s per-op serialization otherwise makes rare), and the
/// two deleters also race *each other* — exercising `delete`'s own Find→Delete
/// TOCTOU (a concurrent delete between our Find and our Delete → `errSecItemNotFound`,
/// which must read as success, not a failure).
///
/// It is intentionally **not** multiple concurrent *setters*: two setters racing
/// each other surface a *different* keychain outcome (`SecKeychainItemModify` →
/// `errSecDuplicateItem` when a second writer's Add lands mid-modify), a distinct
/// multi-writer conflict rather than the delete-under-set TOCTOU in scope here.
const race_deleters: usize = 2;

/// One racing child's body: loop the given op against the shared key. The child
/// builds its own context from the inherited real environment. Returns a nonzero
/// exit code on any *unacceptable* error — success and benign key-not-found are
/// both `void` here, so reaching the end means every op was acceptable.
fn runRaceChild(role: []const u8) u8 {
    const a = std.heap.smp_allocator;

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    loadEnviron(&env) catch return 2;

    // A racing child's error path is exactly what we want to see when this test
    // regresses, so route the plugin's backend diagnostics to the child's real
    // stderr (which the parent captures and echoes) rather than discarding them.
    var err_buf: [4096]u8 = undefined;
    var child_stderr = std.Io.File.stderr().writerStreaming(std.testing.io, &err_buf);
    var ctx = MockContext{
        .allocator = a,
        .io = std.testing.io,
        .environ = &env,
        .app_name = service,
        .err_writer = &child_stderr.interface,
    };
    var data: plugin.ContextData = .{};
    plugin.initContextData(&data, &ctx) catch return 2;

    const is_setter = std.mem.eql(u8, role, "set");
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < race_iterations) : (i += 1) {
        if (is_setter) {
            const value = std.fmt.bufPrint(&buf, "v-{d}", .{i}) catch unreachable;
            // Only success is acceptable: even when a concurrent `delete` removes
            // the item mid-`set`, the retry must re-Add (or Modify) and succeed —
            // never surface a backend failure.
            data.set(race_name, value) catch |e| {
                childFail(&child_stderr.interface, role, i, e);
                return 1;
            };
        } else {
            // A delete of an absent key is a documented no-op (success), so every
            // iteration must succeed regardless of what the setter is doing.
            data.delete(race_name) catch |e| {
                childFail(&child_stderr.interface, role, i, e);
                return 1;
            };
        }
    }
    return 0;
}

/// Print *why* a racing child is about to exit nonzero to its real stderr (which
/// the parent captures and echoes), then let the caller return the exit code. The
/// parent otherwise sees only a bare ".{ .exited = 1 }" — the whole reason CI was
/// unexplained before. Any backend diagnostic (`context.stderr()`) already landed
/// on the same stream above this line.
fn childFail(w: *std.Io.Writer, role: []const u8, iteration: usize, e: anyerror) void {
    w.print(
        "race child [{s}] iteration {d} failed: {s}\n",
        .{ role, iteration, @errorName(e) },
    ) catch {};
    w.flush() catch {};
}

/// Read a spawned child's stderr pipe to EOF. Returns the captured bytes (caller
/// frees) or `null` if the child had no stderr pipe / the read failed — a
/// best-effort diagnostic aid, never fatal to the test. Must be called before
/// `child.wait` so the pipe is drained while the child can still be writing.
fn drainChildStderr(a: std.mem.Allocator, io: std.Io, child: *std.process.Child) ?[]u8 {
    const file = child.stderr orelse return null;
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.interface.allocRemaining(a, .limited(64 * 1024)) catch null;
}

test "concurrent set / delete race is benign and leaves the store usable" {
    const io = std.testing.io;

    // A re-exec'd child: run one racing loop and exit with its result code. This
    // returns before touching the parent-only spawn logic below. (The child skips
    // the round-trip test via the same env guard.)
    if (envValue(race_role_env)) |role| {
        std.process.exit(runRaceChild(role));
    }

    // ---- Parent: spawn the racing children and arbitrate the outcome. ----
    const a = std.testing.allocator;

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try loadEnviron(&env);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var ctx = MockContext{ .allocator = a, .io = io, .environ = &env, .app_name = service, .err_writer = &discard.writer };
    var data: plugin.ContextData = .{};
    try plugin.initContextData(&data, &ctx);

    // Start from a clean slate even if a prior aborted run left an entry.
    try data.delete(race_name);

    // This test binary's own path — what we re-exec as the racing children.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    const exe = exe_buf[0..exe_len];

    // The children inherit this process's environment (so the Linux backend still
    // sees the session bus / HOME / gpg-agent CI set up) plus the role selector.
    var setter_env = std.process.Environ.Map.init(a);
    defer setter_env.deinit();
    try loadEnviron(&setter_env);
    try setter_env.put(race_role_env, "set");

    var deleter_env = std.process.Environ.Map.init(a);
    defer deleter_env.deinit();
    try loadEnviron(&deleter_env);
    try deleter_env.put(race_role_env, "delete");

    // Spawn all children first (so the single setter and the deleters actually
    // overlap on the shared store), then reap them all. The setter occupies slot 0,
    // the deleters the rest.
    // Capture each child's stderr (`.pipe`, not `.ignore`) so a failing child's
    // diagnostic — the op, iteration, and error name it printed via `childFail`,
    // plus any backend diagnostic — is echoed here. Without this the parent sees
    // only ".{ .exited = 1 }", which is what made the original CI failure opaque.
    var children: [1 + race_deleters]std.process.Child = undefined;
    children[0] = try std.process.spawn(io, .{
        .argv = &.{exe},
        .environ_map = &setter_env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    for (1..children.len) |k| {
        children[k] = try std.process.spawn(io, .{
            .argv = &.{exe},
            .environ_map = &deleter_env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        });
    }

    // Each child exits 0 only if every op it did was acceptable (success or benign
    // key-not-found). A nonzero exit is the pre-#234 opaque `BackendFailure`
    // surfacing under the race — the exact regression this test guards. Reap all
    // children before asserting so none is left as a zombie on an early failure.
    // A racing child prints at most a few short lines to stderr and only on the
    // failure path, so draining each pipe just before that child's `wait` (rather
    // than concurrently) stays well under the OS pipe buffer and cannot deadlock.
    var all_ok = true;
    for (&children, 0..) |*child, idx| {
        const child_err = drainChildStderr(a, io, child);
        defer if (child_err) |bytes| a.free(bytes);

        const term = child.wait(io) catch |e| {
            all_ok = false;
            std.debug.print("child {d} wait failed: {s}\n", .{ idx, @errorName(e) });
            continue;
        };
        if (!(term == .exited and term.exited == 0)) {
            all_ok = false;
            std.debug.print(
                "a racing child (slot {d}) exited abnormally: {any}\n",
                .{ idx, term },
            );
            if (child_err) |bytes| if (bytes.len > 0)
                std.debug.print("  child stderr:\n{s}", .{bytes});
        }
    }
    try std.testing.expect(all_ok);

    // The final state must be one of the two acceptable outcomes: the key is
    // present and readable, or absent. Reading it back (whatever it is) must not
    // fail — anything else means the store is wedged.
    if (try data.get(race_name)) |v| a.free(v);

    // Deterministic cleanup, then a full round-trip proving the store still works
    // (not wedged/locked by the racing): set a sentinel, read it back, delete it,
    // confirm gone.
    try data.delete(race_name);
    try std.testing.expect((try data.get(race_name)) == null);

    try data.set(race_name, "post-race-sentinel");
    {
        const v = (try data.get(race_name)).?;
        defer a.free(v);
        try std.testing.expectEqualStrings("post-race-sentinel", v);
    }
    try data.delete(race_name);
    try std.testing.expect((try data.get(race_name)) == null);
}
