//! Shared subprocess runner for the Linux `zcli_secrets` backends.
//!
//! Both Linux stores are reached by *executing a helper binary* (`secret-tool`
//! or `pass`) rather than linking a library — that is what keeps a zcli binary
//! static and musl-clean (see `docs/adr/0010-linux-secrets-shell-out-and-pass.md`).
//! This wraps the shape both backends need: spawn a command, optionally feed it
//! the secret on stdin, capture stdout/stderr, and wait.
//!
//! The child inherits `environ` — threaded from the context, never read via C
//! `getenv` — so `secret-tool` / `pass` / `gpg` see `HOME`,
//! `DBUS_SESSION_BUS_ADDRESS`, `GNUPGHOME`, `PASSWORD_STORE_DIR`, `GPG_TTY`, and
//! the rest of the ambient environment they rely on.
//!
//! ## Which binary gets executed
//!
//! `std.process.spawn` documents that an `argv[0]` which is not already a file
//! path "is resolved into a file path based on PATH from the **parent**
//! environment". Spawning the bare names `pass` / `secret-tool` therefore let any
//! PATH entry that sorts ahead of the real install decide who receives the secret
//! on stdin. `resolveHelper` closes that: it picks the binary itself, from a
//! fixed list of absolute directories, and every argv this module is handed for a
//! helper starts with that absolute path — which `spawn` then executes directly,
//! consulting no PATH at all.
//!
//! Note what that does *not* cover, so the guarantee is not overstated: `pass` is
//! a shell script. Once it is running it resolves its own `gpg`, `tree`,
//! `base64`, `getopt` — and its `#!/usr/bin/env bash` interpreter — through PATH,
//! and nothing here can change that. It is inherent to shelling out to a script,
//! and it is the reason the ambient environment is still forwarded whole rather
//! than trimmed to an allowlist: a trimmed environment would have to carry PATH
//! anyway for `pass` to function, so trimming buys little while risking a broken
//! pinentry, session bus, GnuPG home or locale. Passing a curated PATH was
//! considered and rejected for the same reason in reverse — it breaks Nix,
//! Homebrew and other non-standard toolchain layouts far more often than it
//! helps. (Trimming would not have addressed this issue in any case: `spawn`
//! resolves `argv[0]` against the *parent* environment, never `environ_map`.)

const std = @import("std");

/// The absolute directories searched, in order, for a helper binary.
///
/// Deliberately a fixed list rather than the inherited PATH — the whole point is
/// that the environment does not get to choose which binary is fed a decrypted
/// credential. The system directories come first so that a per-user prefix can
/// never shadow a system install, and no relative or `.`-like entry can appear at
/// all. Coverage is the standard layouts plus the two package managers that
/// routinely install outside them (NixOS's system profile and Homebrew on Linux).
///
/// There is intentionally no environment-variable override. One would reopen
/// exactly the environment-controlled binary selection this list exists to
/// remove, for the benefit of installs the list already covers; if a real layout
/// is missing it belongs here, as a reviewable code change. A helper installed
/// somewhere exotic is reachable by symlinking it into `/usr/local/bin`.
const trusted_dirs = [_][]const u8{
    "/usr/bin",
    "/bin",
    "/usr/local/bin",
    "/run/current-system/sw/bin",
    "/home/linuxbrew/.linuxbrew/bin",
};

/// Searched after `trusted_dirs`, relative to `$HOME`. An attacker who can write
/// to these already owns the session (they could edit the user's shell rc), so
/// they add reach for per-user installs without widening the real threat — and
/// being last, they cannot shadow a system binary.
const trusted_home_dirs = [_][]const u8{
    ".nix-profile/bin",
    ".local/bin",
};

pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Output) void {
        // stdout can hold decrypted secret material (a `pass show` / `secret-tool
        // lookup` reads the stored value back on stdout), so wipe it before the
        // allocator reclaims the pages. stderr is diagnostic text, but wiping it
        // too is cheap and avoids depending on that always being true.
        std.crypto.secureZero(u8, self.stdout);
        std.crypto.secureZero(u8, self.stderr);
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    /// The child ran to completion with a zero exit code.
    pub fn ok(self: Output) bool {
        return self.term == .exited and self.term.exited == 0;
    }
};

pub const Error = error{
    /// The helper binary could not be executed at all — typically it is not
    /// installed. Deliberately distinct from "the command ran and exited
    /// nonzero", which surfaces as a non-`ok` `Output`.
    SpawnFailed,
    /// No executable by that name exists in any trusted directory. Distinct from
    /// `SpawnFailed` at the point of failure, though both mean "this helper is
    /// not usable here" and backends collapse them the same way.
    HelperNotFound,
};

/// Resolve a helper binary name to an absolute path, searching only
/// `trusted_dirs` then `trusted_home_dirs` — never the inherited PATH. The
/// result is written into `buf` and the returned slice borrows it, so it stays
/// valid for as long as `buf` is in scope (no allocation, matching how
/// `passStoreInitialized` handles paths).
///
/// A candidate qualifies when it exists and is executable for this process; the
/// check follows symlinks, so the usual `/usr/bin/pass -> /nix/store/…` shape
/// resolves normally.
///
/// This is a check-then-exec, so it is a TOCTOU in the strict sense: a candidate
/// could be replaced between the `access` and the `spawn`. That race needs write
/// access to a trusted directory, which is already game over — and the property
/// being bought is not "this exact inode", it is "not whatever an inherited PATH
/// pointed at".
pub fn resolveHelper(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    helper: []const u8,
    buf: *[std.fs.max_path_bytes]u8,
) Error![]const u8 {
    for (trusted_dirs) |dir| {
        const path = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, helper }) catch continue;
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch continue;
        return path;
    }
    if (environ.get("HOME")) |home| {
        // A relative (or empty) HOME would break `accessAbsolute`'s precondition
        // and is meaningless here anyway.
        if (std.fs.path.isAbsolute(home)) {
            for (trusted_home_dirs) |sub| {
                const path = std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ home, sub, helper }) catch continue;
                std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch continue;
                return path;
            }
        }
    }
    return Error.HelperNotFound;
}

/// A single output stream to drain, plus where the drained bytes land. Passed to
/// `drain` (run concurrently) so stdout and stderr are read *while* stdin is
/// written — otherwise a large secret whose stdin write exceeds the OS pipe
/// buffer would deadlock: parent blocked in `writeAll`, child blocked writing an
/// undrained stdout.
const Drainer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    /// Result slot. Set to the captured bytes on success, left `null` on error.
    out: *?[]u8,
    err: *?anyerror,
};

/// Read `d.file` to EOF into an allocation, storing the result (or the failure)
/// through the drainer's slots. Runs as a concurrent task so the read overlaps
/// the stdin write.
fn drain(d: Drainer) void {
    var buf: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    var reader = d.file.reader(d.io, &buf);
    if (reader.interface.allocRemaining(d.allocator, .limited(1 << 20))) |bytes| {
        d.out.* = bytes;
    } else |e| {
        d.err.* = e;
    }
}

/// Run `argv`, optionally writing `stdin_bytes` (then EOF) to the child's
/// stdin, and capture stdout+stderr. The caller owns the returned `Output`
/// (call `deinit`).
///
/// For any helper that will be handed a credential, `argv[0]` must be an
/// absolute path from `resolveHelper` — a bare name would be resolved by `spawn`
/// against the inherited PATH. This function does not enforce that (its unit
/// tests below drive a plain POSIX filter); the backends do, at their entry
/// points, which is where the helper is chosen.
///
/// stdout and stderr are drained *concurrently* with the stdin write, so a
/// payload larger than the OS pipe buffer (~64 KiB) cannot deadlock the parent
/// against the child.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    stdin_bytes: ?[]const u8,
) !Output {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin_bytes != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = environ,
    }) catch return Error.SpawnFailed;

    // Kick off the two readers before touching stdin, so the child can never
    // block on a full stdout/stderr pipe while we are still feeding stdin.
    var out_bytes: ?[]u8 = null;
    var out_err: ?anyerror = null;
    var out_future = try io.concurrent(drain, .{Drainer{
        .allocator = allocator,
        .io = io,
        .file = child.stdout.?,
        .out = &out_bytes,
        .err = &out_err,
    }});

    var err_bytes: ?[]u8 = null;
    var err_err: ?anyerror = null;
    var err_future = try io.concurrent(drain, .{Drainer{
        .allocator = allocator,
        .io = io,
        .file = child.stderr.?,
        .out = &err_bytes,
        .err = &err_err,
    }});

    if (stdin_bytes) |bytes| {
        var in_buf: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &in_buf);
        // Streaming (plain write(2)), never `.writer()`. This particular fd is a
        // pipe, so positional mode would only ever fail with `Unseekable` rather
        // than corrupt anything — but the framework has exactly one correct
        // idiom for writing an inherited/OS-owned fd (see `zcli.Stdio.init`), and
        // the wrong one must not sit here waiting to be copied somewhere it does
        // corrupt (#763).
        var in = child.stdin.?.writerStreaming(io, &in_buf);
        // A write failure here just means the child closed stdin early; the exit
        // status read below is the authoritative signal, so it is ignored.
        in.interface.writeAll(bytes) catch {};
        in.interface.flush() catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }

    // Join both readers before reaping the child (they hold the pipe read ends).
    out_future.await(io);
    err_future.await(io);

    // If either drainer failed, wait for the child (avoid a zombie) and surface
    // the error after freeing whatever the other one captured.
    const drain_err: ?anyerror = out_err orelse err_err;
    if (drain_err) |e| {
        child.kill(io);
        // stdout may hold a decrypted secret (a `pass show` / `secret-tool
        // lookup` reads the stored value back on stdout) even when the
        // *other* stream is what failed to drain, so wipe both before
        // freeing — mirrors `Output.deinit`.
        if (out_bytes) |b| {
            std.crypto.secureZero(u8, b);
            allocator.free(b);
        }
        if (err_bytes) |b| {
            std.crypto.secureZero(u8, b);
            allocator.free(b);
        }
        return e;
    }

    const term = try child.wait(io);
    return .{
        .term = term,
        .stdout = out_bytes.?,
        .stderr = err_bytes.?,
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// Helper resolution
// ---------------------------------------------------------------------------

/// Index of `needle` in `trusted_dirs`, or `null`.
fn trustedDirIndex(needle: []const u8) ?usize {
    for (trusted_dirs, 0..) |d, i| {
        if (std.mem.eql(u8, d, needle)) return i;
    }
    return null;
}

test "the trusted directory list is absolute and orders system paths first" {
    // Every searched directory is absolute — no relative entry, no `.`, nothing
    // whose meaning depends on the working directory.
    for (trusted_dirs) |d| try std.testing.expect(std.fs.path.isAbsolute(d));
    // The HOME-relative entries are, by construction, not absolute; they are only
    // ever joined onto an absolute HOME.
    for (trusted_home_dirs) |d| try std.testing.expect(!std.fs.path.isAbsolute(d));

    // A prefix that is user-writable on some systems must never be able to
    // shadow the system install of a helper that is about to be fed a secret.
    const usr_bin = trustedDirIndex("/usr/bin").?;
    const bin = trustedDirIndex("/bin").?;
    for ([_][]const u8{ "/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin" }) |writable| {
        const i = trustedDirIndex(writable).?;
        try std.testing.expect(i > usr_bin);
        try std.testing.expect(i > bin);
    }
}

test "resolveHelper pins an absolute path inside a trusted directory" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    // `sh` is required at `/bin/sh` by POSIX, and `/bin` is on the list.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = resolveHelper(std.testing.io, &env, "sh", &buf) catch return error.SkipZigTest;

    try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expect(std.mem.endsWith(u8, path, "/sh"));
    // Whatever matched, it came from the list — not from wherever a PATH said.
    try std.testing.expect(trustedDirIndex(std.fs.path.dirname(path).?) != null);
}

test "resolveHelper does not consult PATH, and reports a missing helper" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    // A PATH (and a HOME) that a bare-name spawn would happily search are simply
    // not part of the search. `/bin` holds `sh` on every POSIX host, so were PATH
    // consulted at all this name is exactly what it would resolve.
    try env.put("PATH", "/bin:/usr/bin");
    try env.put("HOME", "/nonexistent-home-for-zcli-secrets-test");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(
        Error.HelperNotFound,
        resolveHelper(std.testing.io, &env, "zcli-secrets-no-such-helper", &buf),
    );
}

test "resolveHelper ignores a non-absolute HOME rather than joining onto it" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    // A relative HOME would make the joined candidate relative to the working
    // directory — precisely the class of path this resolution refuses to touch.
    try env.put("HOME", "relative/home");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(
        Error.HelperNotFound,
        resolveHelper(std.testing.io, &env, "zcli-secrets-no-such-helper", &buf),
    );
}

// The end-to-end claim of the pinning: a decoy that a bare-name spawn *would*
// have run is not the process that runs. The two halves are asserted separately
// above (resolution ignores PATH; the argv builders put the resolved path in
// `argv[0]`), but only actually spawning closes the loop — `std.process.spawn`
// is what decides whether `argv[0]` is a path or a PATH lookup, and this is the
// assertion that the composition never hands it a bare name.
test "the pinned binary is the one spawned, not a decoy earlier on PATH" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A decoy named `sh`, executable, that announces itself whatever it is given.
    try tmp.dir.writeFile(io, .{
        .sub_path = "sh",
        .data = "#!/bin/sh\nprintf DECOY\n",
        .flags = .{ .permissions = .executable_file },
    });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = tmp.dir.realPath(io, &dir_buf) catch return error.SkipZigTest;
    const decoy_dir = dir_buf[0..dir_len];

    // Prove the decoy is a viable hijack *before* asserting that it loses — if it
    // were not executable this test would pass for the wrong reason.
    var decoy_buf: [std.fs.max_path_bytes]u8 = undefined;
    const decoy = std.fmt.bufPrint(&decoy_buf, "{s}/sh", .{decoy_dir}) catch return error.SkipZigTest;
    std.Io.Dir.accessAbsolute(io, decoy, .{ .execute = true }) catch return error.SkipZigTest;

    // A PATH and a HOME that point at nothing but the decoy: #768, staged.
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("PATH", decoy_dir);
    try env.put("HOME", decoy_dir);

    var bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bin = resolveHelper(io, &env, "sh", &bin_buf) catch return error.SkipZigTest;
    try std.testing.expect(!std.mem.eql(u8, bin, decoy));
    try std.testing.expect(trustedDirIndex(std.fs.path.dirname(bin).?) != null);

    // Spawn through the resolved path and let the child identify itself: the
    // decoy prints DECOY, the real shell runs the script. Anything but "real"
    // means PATH decided who ran.
    var out = run(a, io, &env, &.{ bin, "-c", "printf real" }, null) catch |e| switch (e) {
        Error.SpawnFailed => return error.SkipZigTest,
        else => return e,
    };
    defer out.deinit();

    try std.testing.expect(out.ok());
    try std.testing.expectEqualStrings("real", out.stdout);
}

// ---------------------------------------------------------------------------
// Value encoding
// ---------------------------------------------------------------------------
//
// `secret-tool` transports the secret as a stdin line and `pass` as file text,
// so neither round-trips arbitrary bytes (an embedded NUL truncates the line; a
// stray newline is ambiguous). Both backends therefore base64-encode on write
// and decode on read, preserving the plugin's opaque-bytes contract uniformly
// (ADR-0010). A value inspected via `secret-tool` / `pass show` reads as base64.

const b64 = std.base64.standard;

/// base64-encode a secret value. Caller owns the result.
pub fn encodeValue(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    const dst = try allocator.alloc(u8, b64.Encoder.calcSize(value.len));
    _ = b64.Encoder.encode(dst, value);
    return dst;
}

/// Reverse `encodeValue`. Returns `error.InvalidBase64` if the stored text is
/// not what we wrote. Caller owns the result (and must not be zeroed here — it
/// is the plaintext the caller asked for); the error path *is* wiped, since a
/// partially-decoded buffer holds secret bytes we are about to discard.
pub fn decodeValue(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const n = b64.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const dst = try allocator.alloc(u8, n);
    errdefer {
        std.crypto.secureZero(u8, dst);
        allocator.free(dst);
    }
    b64.Decoder.decode(dst, encoded) catch return error.InvalidBase64;
    return dst;
}

test "value survives base64 round-trip including NUL and high bytes" {
    const a = std.testing.allocator;
    const raw = [_]u8{ 'a', 0x00, 'b', 0xff, '\n' };
    const enc = try encodeValue(a, &raw);
    defer a.free(enc);
    const dec = try decodeValue(a, enc);
    defer a.free(dec);
    try std.testing.expectEqualSlices(u8, &raw, dec);
}

// The large-payload round-trip proves the stdin write and stdout drain overlap
// (defect: a pre-fix `run` deadlocked once the base64 stdin exceeded the pipe
// buffer). It shells out to a POSIX filter; skipped where unavailable.
test "run round-trips a payload larger than the pipe buffer without deadlock" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    // 256 KiB — comfortably past the ~64 KiB pipe buffer that triggers the
    // deadlock. `cat` echoes stdin to stdout verbatim.
    const payload = try a.alloc(u8, 256 * 1024);
    defer a.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast('A' + (i % 26));

    var out = run(a, std.testing.io, &env, &.{"cat"}, payload) catch |e| switch (e) {
        // `cat` not on PATH in this environment — nothing to prove here.
        Error.SpawnFailed => return error.SkipZigTest,
        else => return e,
    };
    defer out.deinit();

    try std.testing.expect(out.ok());
    try std.testing.expectEqualSlices(u8, payload, out.stdout);
}

test "run round-trips an empty stdin payload" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    var out = run(a, std.testing.io, &env, &.{"cat"}, "") catch |e| switch (e) {
        Error.SpawnFailed => return error.SkipZigTest,
        else => return e,
    };
    defer out.deinit();

    try std.testing.expect(out.ok());
    try std.testing.expectEqualStrings("", out.stdout);
}
