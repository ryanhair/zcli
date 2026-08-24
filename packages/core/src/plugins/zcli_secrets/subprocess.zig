//! Helper-binary invocation for the Linux `zcli_secrets` backends.
//!
//! Both Linux stores are reached by *executing a helper binary* (`secret-tool`
//! or `pass`) rather than linking a library — that is what keeps a zcli binary
//! static and musl-clean (see `docs/adr/0010-linux-secrets-shell-out-and-pass.md`).
//!
//! The plumbing itself is `zcli.process` (ADR-0034); this file is now just the
//! secrets-specific *policy* on top of it: which directories a helper may come
//! from, that the payload is a secret, and that the captured output is too. That
//! is deliberate — this module was where the framework's third and strongest
//! hand-rolled subprocess runner lived, and the general one exists precisely so
//! there is only one implementation of "feed a child on stdin without
//! deadlocking, cap what it says back, and don't let PATH pick the binary".
//!
//! What the shared runner now provides that this file used to spell out itself:
//! the stdin write overlaps both output drains (a base64'd secret larger than a
//! pipe buffer used to deadlock here), captured output is bounded, the child is
//! reaped exactly once, and the environment is the threaded `environ` rather
//! than anything ambient.
//!
//! ## Which binary gets executed
//!
//! `std.process.spawn` documents that an `argv[0]` which is not already a file
//! path "is resolved into a file path based on PATH from the **parent**
//! environment". Spawning the bare names `pass` / `secret-tool` would therefore
//! let any PATH entry that sorts ahead of the real install decide who receives
//! the secret on stdin. `Program.in_dirs` closes that: the runner picks the
//! binary itself, from the fixed absolute list below, and spawns the absolute
//! path it resolved.
//!
//! Note what that does *not* cover, so the guarantee is not overstated: `pass`
//! is a shell script. Once running it resolves its own `gpg`, `tree`, `base64`,
//! `getopt` — and its `#!/usr/bin/env bash` interpreter — through PATH, and
//! nothing here can change that. It is inherent to shelling out to a script, and
//! it is why the ambient environment is still forwarded whole (`.env = .inherit`)
//! rather than trimmed to an allowlist: a trimmed environment would have to carry
//! PATH anyway for `pass` to function, so trimming buys little while risking a
//! broken pinentry, session bus, GnuPG home or locale. Passing a curated PATH was
//! considered and rejected for the same reason in reverse — it breaks Nix,
//! Homebrew and other non-standard toolchain layouts far more often than it helps.

const std = @import("std");
// Through the framework module, not a relative path: this file is compiled both
// as part of a consuming app's plugin module and as the repo's own standalone
// secrets test modules, and only the named import resolves in all of them.
const process = @import("zcli").process;

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

/// Cap on captured helper stdout. This is where a decrypted secret comes back
/// (`pass show`, `secret-tool lookup`), so the capture is marked sensitive and
/// the buffer is therefore allocated at this size up front and wiped on release.
/// 1 MiB matches the cap the hand-rolled drain used, so no value that stored
/// before still fails to read back.
const stdout_limit = 1024 * 1024;

/// Cap on captured helper stderr. Only ever substring-matched for known failure
/// signatures, so a smaller cap costs nothing — and `.truncate` means a chatty
/// helper can never turn a working operation into an error. Still marked
/// sensitive: it is not *supposed* to carry secret material, and wiping it is
/// cheap enough that the guarantee should not depend on that staying true.
const stderr_limit = 64 * 1024;

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

/// The absolute directories a helper may be executed from, in search order:
/// `trusted_dirs` then `$HOME`-relative entries. Caller owns the returned slice
/// and the joined `$HOME` paths within it; `deinitDirs` releases both.
///
/// A relative (or absent) `HOME` contributes nothing — joining onto it would
/// produce a relative candidate, which `Program.in_dirs` rejects outright as
/// `error.UnsafeSearchPath`, and which is meaningless here anyway.
fn trustedDirList(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) std.mem.Allocator.Error![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (dirs.items[trusted_dirs.len..]) |d| allocator.free(d);
        dirs.deinit(allocator);
    }

    try dirs.appendSlice(allocator, &trusted_dirs);

    if (environ.get("HOME")) |home| {
        if (std.fs.path.isAbsolute(home)) {
            for (trusted_home_dirs) |sub| {
                const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, sub });
                errdefer allocator.free(joined);
                try dirs.append(allocator, joined);
            }
        }
    }
    return dirs.toOwnedSlice(allocator);
}

fn deinitDirs(allocator: std.mem.Allocator, dirs: []const []const u8) void {
    // The first `trusted_dirs.len` entries are static string literals; only the
    // `$HOME`-joined tail was allocated.
    for (dirs[trusted_dirs.len..]) |d| allocator.free(d);
    allocator.free(dirs);
}

/// Is `helper` present and executable in one of the trusted directories?
///
/// Advisory, and deliberately so: the authoritative resolution happens inside
/// `run`, at spawn, over this same directory list. This exists because the
/// backend-selection path needs a cheap "could we use this store at all" answer
/// without spawning anything. It used to *launch* the tool (`secret-tool
/// --version`, `pass version`) to prove it could be launched; two `faccessat`
/// calls answer the question that actually matters — is there a candidate in a
/// directory we trust — at a fraction of the cost.
/// Allocation-free on purpose: the backend-selection seam that calls this has no
/// allocator in its signature, and the search is a handful of `bufPrint`s.
pub fn helperAvailable(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    helper: []const u8,
) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (trusted_dirs) |dir| {
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, helper }) catch continue;
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch continue;
        return true;
    }
    if (environ.get("HOME")) |home| {
        // A relative HOME would make the joined candidate relative to the working
        // directory — precisely the class of path this refuses to touch, and one
        // `Program.in_dirs` would reject at spawn anyway.
        if (std.fs.path.isAbsolute(home)) {
            for (trusted_home_dirs) |sub| {
                const path = std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ home, sub, helper }) catch continue;
                std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch continue;
                return true;
            }
        }
    }
    return false;
}

/// What a helper invocation produced. `stdout`/`stderr` borrow the captured
/// buffers inside `result`, so they are valid until `deinit`.
pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    result: process.Result,

    /// Frees the captured allocations, wiping them first (both captures are
    /// marked sensitive and the run's scrub policy is the default `.always`).
    pub fn deinit(self: *Output) void {
        self.result.deinit();
        self.stdout = &.{};
        self.stderr = &.{};
    }

    /// The helper ran to completion with a zero exit code.
    pub fn ok(self: Output) bool {
        return self.result.ok();
    }
};

/// Run `helper` with `args` (which must NOT include `argv[0]` — the runner
/// supplies the absolute path it resolved), optionally writing `stdin_bytes`
/// then EOF, and capture stdout+stderr. The caller owns the returned `Output`
/// (call `deinit`).
///
/// `stdin_bytes` is passed as `.secret` but with `scrub_source` left off: the
/// caller still owns that buffer, wipes it itself, and — for `set` — re-sends it
/// on a retry, so zeroing it here would silently store zeros on the second
/// attempt.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    helper: []const u8,
    args: []const []const u8,
    stdin_bytes: ?[]u8,
) !Output {
    const dirs = try trustedDirList(allocator, environ);
    defer deinitDirs(allocator, dirs);

    var runner = process.Runner.init(allocator, io, environ);
    const result = runner.run(.{ .in_dirs = .{ .name = helper, .dirs = dirs } }, .{
        .args = args,
        .stdin = if (stdin_bytes) |b|
            .{ .secret = .{ .bytes = b, .scrub_source = false } }
        else
            .ignore,
        .stdout = .{ .capture = .{
            .limit = stdout_limit,
            .overflow = .fail,
            .sensitive = true,
        } },
        .stderr = .{ .capture = .{
            .limit = stderr_limit,
            .overflow = .truncate,
            .sensitive = true,
        } },
        // ADR-0010: the ambient environment is forwarded whole. See the module
        // header for why trimming it would cost more than it buys here.
        .env = .{ .policy = .inherit },
    }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.ProgramNotFound => Error.HelperNotFound,
        else => Error.SpawnFailed,
    };

    return .{
        .stdout = result.stdout.bytes(),
        .stderr = result.stderr.bytes(),
        .result = result,
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
    // whose meaning depends on the working directory. `Program.in_dirs` enforces
    // this too (`error.UnsafeSearchPath`), but the list is the thing that must be
    // right; the runner's check is the backstop.
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

test "the search list is every trusted dir, system first, with HOME entries last" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", "/home/someone");

    const dirs = try trustedDirList(a, &env);
    defer deinitDirs(a, dirs);

    try std.testing.expectEqual(trusted_dirs.len + trusted_home_dirs.len, dirs.len);
    for (dirs) |d| try std.testing.expect(std.fs.path.isAbsolute(d));
    try std.testing.expectEqualStrings("/usr/bin", dirs[0]);
    try std.testing.expectEqualStrings("/home/someone/.nix-profile/bin", dirs[trusted_dirs.len]);
    try std.testing.expectEqualStrings("/home/someone/.local/bin", dirs[trusted_dirs.len + 1]);
}

test "a relative or absent HOME contributes no search directory" {
    const a = std.testing.allocator;

    {
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        // A relative HOME would make the joined candidate relative to the working
        // directory — precisely the class of path this resolution refuses to touch.
        try env.put("HOME", "relative/home");
        const dirs = try trustedDirList(a, &env);
        defer deinitDirs(a, dirs);
        try std.testing.expectEqual(trusted_dirs.len, dirs.len);
    }
    {
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        const dirs = try trustedDirList(a, &env);
        defer deinitDirs(a, dirs);
        try std.testing.expectEqual(trusted_dirs.len, dirs.len);
    }
}

test "helperAvailable does not consult PATH" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    // A PATH (and a HOME) that a bare-name spawn would happily search are simply
    // not part of the search.
    try env.put("PATH", "/bin:/usr/bin");
    try env.put("HOME", "/nonexistent-home-for-zcli-secrets-test");

    try std.testing.expect(!helperAvailable(std.testing.io, &env, "zcli-secrets-no-such-helper"));
}

// The end-to-end claim of the pinning: a decoy that a bare-name spawn *would*
// have run is not the process that runs. `Program.in_dirs` is what decides, and
// this is the assertion that the composition never hands the runner a bare name
// for `std.process.spawn` to resolve against the inherited PATH.
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

    // `sh` is required at `/bin/sh` by POSIX, and `/bin` is on the trusted list.
    var out = run(a, io, &env, "sh", &.{ "-c", "printf real" }, null) catch |e| switch (e) {
        Error.SpawnFailed, Error.HelperNotFound => return error.SkipZigTest,
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
// (defect: a pre-`zcli.process` `run` deadlocked once the base64 stdin exceeded
// the pipe buffer). It shells out to a POSIX filter; skipped where unavailable.
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

    var out = run(a, std.testing.io, &env, "cat", &.{}, payload) catch |e| switch (e) {
        // `cat` not in a trusted directory here — nothing to prove.
        Error.SpawnFailed, Error.HelperNotFound => return error.SkipZigTest,
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

    var empty: [0]u8 = .{};
    var out = run(a, std.testing.io, &env, "cat", &.{}, &empty) catch |e| switch (e) {
        Error.SpawnFailed, Error.HelperNotFound => return error.SkipZigTest,
        else => return e,
    };
    defer out.deinit();

    try std.testing.expect(out.ok());
    try std.testing.expectEqualStrings("", out.stdout);
}

test "the caller's secret payload is left intact for a retry" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    // `set` re-sends the same encoded buffer on a retry, so the runner must not
    // scrub it out from under the caller — `scrub_source` is deliberately off.
    const payload = try a.dupe(u8, "c2VjcmV0");
    defer a.free(payload);

    var out = run(a, std.testing.io, &env, "cat", &.{}, payload) catch |e| switch (e) {
        Error.SpawnFailed, Error.HelperNotFound => return error.SkipZigTest,
        else => return e,
    };
    defer out.deinit();

    try std.testing.expect(out.ok());
    try std.testing.expectEqualStrings("c2VjcmV0", payload);
}
