const std = @import("std");
const builtin = @import("builtin");
const zcli = @import("zcli");
const minisign = @import("minisign.zig");

/// All network traffic goes through zcli's safe-defaults HTTP client, which
/// enforces TLS, bounded (decompressed) bodies, bounded redirects with
/// credential stripping, and a per-request timeout.
const http = zcli.http;

// Security limits for HTTP responses
const MAX_RELEASES_RESPONSE_SIZE = 20 * 1024 * 1024; // 20MB for the releases JSON
const MAX_BINARY_SIZE = 100 * 1024 * 1024; // 100MB for binary downloads
const MAX_CHECKSUMS_SIZE = 1024 * 1024; // 1MB for checksums file
const MAX_SIGNATURE_SIZE = 4 * 1024; // 4KB — a minisign signature is ~300 bytes

// Per-request deadlines. std.http.Client has no timeout of its own — an
// unreachable or stalled peer would otherwise hang forever.
/// Interactive API calls made by the upgrade command itself.
const api_timeout: std.Io.Duration = .fromSeconds(30);
/// The passive update check at startup: it must never make the CLI feel hung,
/// so it gets seconds, not minutes.
const startup_check_timeout: std.Io.Duration = .fromSeconds(3);
/// Minimum interval between passive startup checks. The time of the last
/// attempt is recorded in the platform cache dir (see lastCheckFilePath), so
/// enabling inform_out_of_date probes the network at most once per day —
/// not on every invocation.
const startup_check_interval_s: i64 = 24 * 60 * 60;
/// The binary download — generous (binaries can be ~100MB on slow
/// connections), but still bounded so a dead peer cannot hang the command.
const download_timeout: std.Io.Duration = .fromSeconds(15 * 60);

// Base URLs for GitHub. Kept as named constants so URL construction is a pure,
// testable step and so a test/mirror host could be substituted in one place.
const github_api_base = "https://api.github.com";
const github_download_base = "https://github.com";

/// Build the releases-list API URL: `{base}/repos/{repo}/releases`.
fn buildReleasesUrl(allocator: std.mem.Allocator, base: []const u8, repo: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/repos/{s}/releases", .{ base, repo });
}

/// Build a release-asset download URL. Releases are tagged `{cli_name}-v{version}`.
fn buildDownloadUrl(allocator: std.mem.Allocator, base: []const u8, repo: []const u8, cli_name: []const u8, version: []const u8, asset_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/releases/download/{s}-v{s}/{s}", .{ base, repo, cli_name, version, asset_name });
}

/// True when `v` is safe to interpolate as the version segment of a release
/// download URL: nonempty and every byte is `[A-Za-z0-9._-]`. This is the
/// character set every real version tag (semver, or otherwise) actually
/// needs; anything else — most importantly `/`, which lets a value like
/// `../../owner/repo/releases/download/other-vX/asset` path-traverse within
/// github.com to a different release or repo — is rejected outright rather
/// than escaped, since the value is user-supplied (`upgrade <version>`) and
/// there is no legitimate reason for a version tag to need it.
fn isValidVersionArg(v: []const u8) bool {
    if (v.len == 0) return false;
    for (v) |c| {
        const allowed = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
        if (!allowed) return false;
    }
    return true;
}

/// Platform-standard per-user cache file recording the last passive update
/// check (unix seconds, decimal). Resolved from the threaded environ — no
/// ambient getenv:
///
///   Linux/BSD: $XDG_CACHE_HOME/<app>/last-update-check, else ~/.cache/<app>/…
///   macOS:     ~/Library/Caches/<app>/last-update-check
///   Windows:   %LOCALAPPDATA%\<app>\last-update-check
///
/// Returns null when the environment variable it needs is absent — rate
/// limiting then degrades to checking every run, never to failing.
fn lastCheckFilePath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, app_name: []const u8) !?[]u8 {
    const file_name = "last-update-check";
    switch (builtin.os.tag) {
        .windows => {
            const base = environ.get("LOCALAPPDATA") orelse return null;
            return try std.fs.path.join(allocator, &.{ base, app_name, file_name });
        },
        .macos => {
            const home = environ.get("HOME") orelse return null;
            return try std.fs.path.join(allocator, &.{ home, "Library", "Caches", app_name, file_name });
        },
        else => {
            if (environ.get("XDG_CACHE_HOME")) |xdg| {
                return try std.fs.path.join(allocator, &.{ xdg, app_name, file_name });
            }
            const home = environ.get("HOME") orelse return null;
            return try std.fs.path.join(allocator, &.{ home, ".cache", app_name, file_name });
        },
    }
}

/// Read the last-check timestamp from `path` (within `dir`). Any failure —
/// missing file, unreadable, garbage contents — reads as "never checked".
fn readLastCheck(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ?i64 {
    const contents = dir.readFileAlloc(io, path, allocator, .limited(64)) catch return null;
    defer allocator.free(contents);
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

/// Record a check attempt at `now_s`. Creates missing parent directories.
/// Callers treat failure as best-effort (a read-only home dir must never
/// break startup).
fn writeLastCheck(io: std.Io, dir: std.Io.Dir, path: []const u8, now_s: i64) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}\n", .{now_s});
    try dir.writeFile(io, .{ .sub_path = path, .data = text });
}

/// True when the recorded last check is recent enough to skip the probe.
/// A timestamp in the future (clock skew, corrupt cache) never skips — the
/// probe runs and rewrites a sane value.
fn checkedRecently(last: ?i64, now_s: i64, interval_s: i64) bool {
    const l = last orelse return false;
    return now_s >= l and now_s - l < interval_s;
}

/// Render the unsigned warning shown when a real upgrade runs on a build that
/// explicitly opted out of signatures (`.verification = .checksum_only`).
/// Factored out of `executeUpgrade` so the exact wording is unit-testable
/// without a live command context or network.
fn writeUnsignedWarning(w: *std.Io.Writer) !void {
    try w.print(
        \\warning: signature verification is disabled for this build (checksum_only) —
        \\         only the SHA-256 checksum will be verified. checksums.txt ships in
        \\         the same GitHub release as the binaries, so a compromised release
        \\         publisher can replace both and this upgrade will trust the result.
        \\         To close this gap, pin a minisign public key via the plugin's
        \\         `verification = .{{ .minisign = "..." }}` config (see ADR-0023).
        \\
    , .{});
}

/// zcli-github-upgrade Plugin
///
/// Provides self-upgrade functionality for CLI applications that release via GitHub.
/// Downloads new versions from GitHub releases and atomically replaces the current binary.
///
/// SECURITY: `verification` is the load-bearing integrity control, and it has no
/// default — every consuming app must pick one explicitly. `.checksum_only`
/// authenticates a downloaded binary only against `checksums.txt`, a file that
/// ships in the same release as the binary it describes: a compromised release
/// publisher can swap both the binary and its checksum and the upgrade will
/// trust the swap. `.minisign = "<pinned key>"` (ADR-0023) authenticates the
/// checksums under a key held off the release pipeline and makes verification
/// fail closed. `.checksum_only` builds emit a runtime warning on every real
/// upgrade so the gap can never be silently in effect.
/// Plugin configuration
pub const Config = struct {
    /// GitHub repository in format "owner/repo" (required)
    repo: []const u8,

    /// Command name for the upgrade command (default: "upgrade")
    command_name: []const u8 = "upgrade",

    /// Whether to check for updates on startup and inform the user (default: false)
    ///
    /// When enabled, startup makes an outbound HTTPS request to
    /// api.github.com (the repo's releases list) — but at most once per 24
    /// hours: the time of the last attempt is recorded in the platform's
    /// per-user cache directory ($XDG_CACHE_HOME or ~/.cache on Linux,
    /// ~/Library/Caches on macOS, %LOCALAPPDATA% on Windows) and the probe
    /// is skipped while the interval hasn't elapsed. The check is
    /// time-boxed to seconds, and every failure — cache or network — is
    /// silent: this feature can slow startup briefly, but never break it.
    inform_out_of_date: bool = false,

    /// Message to show when a newer version is available
    /// Use {current} and {latest} as placeholders
    out_of_date_message: []const u8 = "A new version of {app} is available: {latest} (current: {current})\nRun '{app} upgrade' to update.",

    /// How `upgrade` authenticates a downloaded release. Required — there is
    /// deliberately no default, because a silent default here is exactly the
    /// bug this type replaces: an app that never thought about signing used to
    /// get checksum-only trust for free. Now the consuming app's build.zig must
    /// name its choice:
    ///
    ///   .verification = .{ .minisign = "<base64 public key>" }
    ///   .verification = .checksum_only
    ///
    /// `.minisign` takes the base64 blob — the second line of a `.pub` file, or
    /// the argument to `minisign -P`. When set, `upgrade` fetches
    /// `checksums.txt.minisig` alongside `checksums.txt` and verifies the
    /// signature under this pinned key **before** trusting any checksum — and
    /// fails closed if the signature is missing, malformed, or invalid. This
    /// closes the gap that `checksums.txt` alone cannot: it ships in the same
    /// release as the binaries, so a compromised publisher can swap both,
    /// whereas the signing key lives off the release pipeline entirely (see
    /// ADR-0023).
    ///
    /// `.checksum_only` is an explicit opt-out: the upgrade verifies only the
    /// SHA-256 checksum, appropriate for apps that do not sign their releases.
    /// It still emits a loud runtime warning on every real upgrade.
    verification: Verification,
};

/// See `Config.verification`.
pub const Verification = union(enum) {
    /// Pinned minisign public key (base64 blob) — signatures verified, fail closed.
    minisign: []const u8,
    /// Explicit opt-out of signature verification: checksum-only trust.
    checksum_only,
};

/// Initialize the plugin with configuration
pub fn init(config: Config) type {
    return struct {
        const Self = @This();
        const plugin_config = config;

        /// The pinned minisign key, or null under `.checksum_only`. The rest of
        /// this plugin's implementation (downloadAndVerify and below) predates
        /// `Verification` and still speaks `?[]const u8`, which is also the
        /// natural shape for "is a key pinned" checks — so the union is
        /// unwrapped once, here, rather than threading `Verification` through
        /// every internal helper.
        const pinned_public_key: ?[]const u8 = switch (plugin_config.verification) {
            .minisign => |key| key,
            .checksum_only => null,
        };

        /// Test-only accessor for the resolved comptime config, so tests can
        /// assert which security branch a given instantiation takes.
        fn pluginConfigForTest() Config {
            return plugin_config;
        }

        /// Commands provided by this plugin
        pub const commands = struct {
            /// The upgrade command module
            pub const upgrade = struct {
                pub const meta = .{
                    .description = "Upgrade to a specific version or the latest version",
                    .examples = &.{
                        plugin_config.command_name,
                        plugin_config.command_name ++ " 1.2.3",
                        plugin_config.command_name ++ " --check",
                    },
                };

                pub const Args = struct {
                    version: ?[]const u8 = null,
                };

                pub const Options = struct {
                    check: bool = false,
                    force: bool = false,
                };

                pub fn execute(args: Args, options: Options, context: anytype) !void {
                    return executeUpgrade(args, options, context);
                }
            };
        };

        /// Execute the upgrade command
        fn executeUpgrade(args: commands.upgrade.Args, options: commands.upgrade.Options, context: anytype) !void {
            const allocator = context.allocator;
            const stdout = context.stdout();

            // Determine target version (explicit or latest)
            const current_version = context.app_version;
            const target_version = if (args.version) |v| blk: {
                // `v` is interpolated verbatim into the release-download URL
                // (buildDownloadUrl: ".../releases/download/{cli}-v{version}/...")
                // — an unsanitized value containing "/" or ".." path-traverses
                // within github.com to a different release, or a different repo
                // entirely. Reject anything outside the character set every real
                // version tag actually uses before it ever reaches URL
                // construction.
                if (!isValidVersionArg(v)) {
                    return context.fail(
                        "Error: invalid version '{s}' — versions may contain only letters, digits, '.', '_', and '-'\n",
                        .{v},
                    );
                }
                break :blk try allocator.dupe(u8, v);
            } else fetchLatestVersion(allocator, context.io, stdout, plugin_config.repo, context.app_name, api_timeout) catch |err| switch (err) {
                // Render the two "GitHub answered, but unusably" cases here,
                // where we have a context — selectVersion is a pure helper
                // and must not print (its old debug-print bypassed stream
                // overrides and violated invariant #3).
                error.NoMatchingRelease => return context.fail("Error: No releases found with tag prefix '{s}-v'\nExpected tag format: {s}-v<version> (e.g., {s}-v1.0.0)", .{ context.app_name, context.app_name, context.app_name }),
                error.InvalidVersionTag => return context.fail("Error: the latest release tag carries an invalid version (only letters, digits, '.', '_', and '-' are allowed) — refusing to build a download URL from it", .{}),
                error.UnexpectedResponse => return context.fail("Error: Unexpected response from the GitHub releases API (expected a JSON array of releases)", .{}),
                error.RateLimitExceeded => return context.fail("Error: GitHub API rate limit exceeded. Try again later.", .{}),
                error.FailedToFetchVersion => return context.fail("Error: Could not fetch the latest version from GitHub (repo '{s}').", .{plugin_config.repo}),
                else => return err,
            };
            defer allocator.free(target_version);

            if (options.check) {
                try writeCheckResult(stdout, current_version, target_version, args.version != null);
                // Flush and exit cleanly via the context. Exiting the process
                // directly would discard everything we just wrote to the
                // buffered stdout — context.exit flushes first.
                context.exit(0);
            }

            // Unsigned notice, only under the explicit `.checksum_only` opt-out.
            // With no pinned key the upgrade authenticates only against
            // `checksums.txt`, which ships in the same release as the binaries
            // — a compromised release publisher can swap both and this command
            // will trust the swap. The signing key (ADR-0023) lives off the
            // release pipeline, so pinning it is the only defense against that
            // class of attack. Zig has no non-fatal comptime print
            // (`@compileLog` halts the build), so the warning is emitted at
            // runtime, once, gated on the comptime config — it costs nothing
            // when a key is pinned and cannot be missed by an operator running
            // an actual upgrade.
            if (comptime plugin_config.verification == .checksum_only) {
                try writeUnsignedWarning(context.stderr());
            }

            // Perform upgrade
            const is_downgrade = args.version != null and isNewerVersion(target_version, current_version);
            const is_same_version = std.mem.eql(u8, current_version, target_version);
            const needs_upgrade = args.version != null or isNewerVersion(current_version, target_version);

            // Downgrade guard for the no-arg path: `upgrade` (no version) must
            // NEVER install a version older than or equal to the current one,
            // even with --force. The latest tag comes from the releases feed,
            // which a stale or malicious mirror could point at an old but
            // validly-signed release; refusing here keeps that from silently
            // rolling a user back. Explicit `upgrade <version>` is still allowed
            // to downgrade (it warns below).
            if (args.version == null and !isNewerVersion(current_version, target_version)) {
                try stdout.print("You are already on the latest version: {s}\n", .{current_version});
                return;
            }

            if (is_same_version and !options.force) {
                try stdout.print("You are already on version: {s}\n", .{current_version});
                return;
            }

            if (!needs_upgrade and !options.force) {
                try stdout.print("You are already on the latest version: {s}\n", .{current_version});
                return;
            }

            if (is_downgrade) {
                try stdout.print("Downgrading from {s} to {s}...\n", .{ current_version, target_version });
            } else {
                try stdout.print("Upgrading from {s} to {s}...\n", .{ current_version, target_version });
            }

            // Detect platform
            const platform = try detectPlatform(allocator);
            defer allocator.free(platform);
            // Windows release assets carry the .exe extension
            // (e.g. zcli-x86_64-windows.exe). The download URL, checksum
            // lookup, smoke test, and install all key off this one name.
            const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
            const binary_name = try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ context.app_name, platform, exe_suffix });
            defer allocator.free(binary_name);

            // Resolve the executable's location up front: the download goes
            // into a private, randomly-named scratch directory next to it —
            // never a predictable path in the CWD, which a local attacker
            // could pre-plant (e.g. a symlink redirecting the write). This
            // also keeps the download on the filesystem the final swap
            // happens on, and fails fast when the install dir isn't writable.
            var exe_path_buf: [4096]u8 = undefined;
            const exe_len = try std.process.executablePath(context.io, &exe_path_buf);
            const exe_path = exe_path_buf[0..exe_len];
            const exe_dir_path = std.fs.path.dirname(exe_path) orelse return error.InvalidExecutablePath;

            var exe_dir = try std.Io.Dir.cwd().openDir(context.io, exe_dir_path, .{});
            defer exe_dir.close(context.io);

            var scratch_name_buf: [scratch_name_len]u8 = undefined;
            const scratch_name = randomScratchName(context.io, &scratch_name_buf);
            try exe_dir.createDir(context.io, scratch_name, scratch_dir_permissions);
            defer exe_dir.deleteTree(context.io, scratch_name) catch {};
            var scratch_dir = try exe_dir.openDir(context.io, scratch_name, .{});
            defer scratch_dir.close(context.io);

            // Download binary
            try stdout.print("Downloading {s}...\n", .{binary_name});
            if (pinned_public_key != null) {
                try stdout.print("Verifying signature...\n", .{});
            } else {
                try stdout.print("Verifying checksum...\n", .{});
            }
            // Fetch the asset, then verify its integrity into scratch_dir. When a
            // signing key is pinned, checksums.txt is authenticated under it
            // (fail closed) before any digest is trusted.
            try downloadAndVerify(allocator, context.io, context.stderr(), github_download_base, scratch_dir, plugin_config.repo, context.app_name, target_version, binary_name, pinned_public_key);

            // Make binary executable before testing (Unix only - Windows uses .exe extension)
            if (builtin.os.tag != .windows) {
                const temp_file = try scratch_dir.openFile(context.io, binary_name, .{});
                defer temp_file.close(context.io);
                try temp_file.setPermissions(context.io, .executable_file);
            }

            // Test new binary
            try stdout.print("Testing new binary...\n", .{});
            try testBinary(allocator, context.io, scratch_dir, binary_name);

            // Replace current binary
            try stdout.print("Installing new version...\n", .{});
            try replaceBinaryAt(allocator, context.io, scratch_dir, binary_name, exe_path);

            const action = if (is_downgrade) "downgraded" else "upgraded";
            try stdout.print("✓ Successfully {s} to {s}\n", .{ action, target_version });
            try stdout.print("\nThe {s} is complete. Run '{s} --version' to verify.\n", .{ action, context.app_name });
        }

        /// Startup hook to check for updates if configured
        pub fn onStartup(context: anytype) !void {
            if (!plugin_config.inform_out_of_date) {
                return;
            }

            const allocator = context.allocator;
            const io = context.io;
            const stderr = context.stderr();

            // Rate limit: at most one probe per startup_check_interval_s,
            // tracked in the platform cache dir. The attempt is recorded
            // before the network call so an offline machine isn't re-probed
            // on every invocation, and every cache failure degrades toward
            // checking — never toward breaking startup.
            const now_s: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
            const cache_path: ?[]u8 = lastCheckFilePath(allocator, context.environ, context.app_name) catch null;
            defer if (cache_path) |p| allocator.free(p);
            if (cache_path) |p| {
                const cwd = std.Io.Dir.cwd();
                if (checkedRecently(readLastCheck(allocator, io, cwd, p), now_s, startup_check_interval_s)) {
                    return;
                }
                writeLastCheck(io, cwd, p, now_s) catch {};
            }

            // Passive check: short deadline (startup_check_timeout) so a slow
            // or black-holed network can never make the CLI feel hung. Any
            // diagnostic fetchLatestVersion would emit is discarded here — a
            // passive probe must be silent on failure, not nag about a 404.
            var discard = std.Io.Writer.Discarding.init(&.{});
            const latest_version = fetchLatestVersion(allocator, io, &discard.writer, plugin_config.repo, context.app_name, startup_check_timeout) catch {
                // Silently fail - don't interrupt the user's workflow
                return;
            };
            defer allocator.free(latest_version);

            const current_version = context.app_version;
            if (isNewerVersion(current_version, latest_version)) {
                // Format and show the out-of-date message
                var message = std.ArrayList(u8).empty;
                defer message.deinit(allocator);

                var iter = std.mem.splitScalar(u8, plugin_config.out_of_date_message, '{');
                var first = true;
                while (iter.next()) |part| {
                    if (first) {
                        try message.appendSlice(allocator, part);
                        first = false;
                        continue;
                    }

                    if (std.mem.startsWith(u8, part, "app}")) {
                        try message.appendSlice(allocator, context.app_name);
                        try message.appendSlice(allocator, part[4..]);
                    } else if (std.mem.startsWith(u8, part, "current}")) {
                        try message.appendSlice(allocator, current_version);
                        try message.appendSlice(allocator, part[8..]);
                    } else if (std.mem.startsWith(u8, part, "latest}")) {
                        try message.appendSlice(allocator, latest_version);
                        try message.appendSlice(allocator, part[7..]);
                    } else {
                        try message.append(allocator, '{');
                        try message.appendSlice(allocator, part);
                    }
                }

                try stderr.print("\n{s}\n\n", .{message.items});
            }
        }
    };
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Fetch the latest version from GitHub releases API filtered by CLI name
/// prefix. `timeout` bounds the whole request: the upgrade command passes
/// `api_timeout`, while `onStartup` passes `startup_check_timeout` so a
/// stalled network can never hang CLI startup.
fn fetchLatestVersion(allocator: std.mem.Allocator, io: std.Io, err_out: *std.Io.Writer, repo: []const u8, cli_name: []const u8, timeout: std.Io.Duration) ![]const u8 {
    // Fetch all releases and filter by tag prefix
    const url = try buildReleasesUrl(allocator, github_api_base, repo);
    defer allocator.free(url);

    var client = http.Client.init(allocator, io, .{
        .max_response_bytes = MAX_RELEASES_RESPONSE_SIZE,
        .timeout = timeout,
    });
    defer client.deinit();

    var response = try client.get(url);
    defer response.deinit();

    // Check for rate limiting
    if (response.status == .too_many_requests) {
        err_out.print("GitHub API rate limit exceeded.\n", .{}) catch {};
        return error.RateLimitExceeded;
    }

    if (response.status != .ok) {
        // Provide specific error messages based on status code
        switch (response.status) {
            .not_found => err_out.print("GitHub repository not found: {s}\n", .{repo}) catch {},
            .unauthorized => err_out.print("GitHub API authentication failed (unauthorized)\n", .{}) catch {},
            .forbidden => err_out.print("GitHub API access forbidden (check permissions)\n", .{}) catch {},
            else => err_out.print("GitHub API request failed with status: {}\n", .{response.status}) catch {},
        }
        return error.FailedToFetchVersion;
    }

    return selectVersion(allocator, response.body, cli_name);
}

/// The single field of a GitHub release we care about. `ignore_unknown_fields`
/// lets us model just this and skip the rest of the (large) release objects.
const Release = struct { tag_name: []const u8 };

/// Pick the version for `cli_name` from a GitHub releases JSON array body.
/// Releases are tagged `{cli_name}-v{version}`; the first tag matching that
/// prefix wins and its `{version}` suffix is returned (caller owns it).
///
/// The body is parsed straight into `[]Release` (unknown fields ignored)
/// rather than into a full `std.json.Value` tree — the releases feed can be
/// megabytes, and we only ever read `tag_name`. A body that is not a JSON
/// array of release objects (a `{"message":"Not Found"}` error object, an
/// HTML error page, garbage) fails the typed parse and surfaces as
/// `error.UnexpectedResponse`; `error.NoMatchingRelease` means the body was a
/// well-formed release array but nothing matched the prefix.
fn selectVersion(allocator: std.mem.Allocator, body: []const u8, cli_name: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice([]Release, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        // Not a JSON array of release objects: a GitHub error object, an HTML
        // error page, or otherwise unusable. The caller renders a diagnostic.
        return error.UnexpectedResponse;
    };
    defer parsed.deinit();

    const tag_prefix = try std.fmt.allocPrint(allocator, "{s}-v", .{cli_name});
    defer allocator.free(tag_prefix);

    for (parsed.value) |release| {
        if (std.mem.startsWith(u8, release.tag_name, tag_prefix)) {
            // Strip prefix to get version (e.g., "zcli-v1.0.0" -> "1.0.0").
            // The result is interpolated into the download URL exactly like an
            // explicit `upgrade <version>` argument, so it passes the same
            // validation — a crafted tag ("zcli-v../../…") must not
            // path-traverse the URL (#395). Fail closed rather than skipping
            // to an older release: an invalid tag at the top is an anomaly
            // worth surfacing.
            const version = release.tag_name[tag_prefix.len..];
            if (!isValidVersionArg(version)) return error.InvalidVersionTag;
            return try allocator.dupe(u8, version);
        }
    }

    return error.NoMatchingRelease;
}

/// Render the `--check` result line to `out`. When `explicit` is true the user
/// named a version (compare for equality); otherwise `target` is the latest tag
/// (compare for "newer"). Pure and writer-based so it is unit-testable without a
/// live command context — and so the message actually reaches the user: the old
/// code printed then exited the process directly, discarding the buffered line.
fn writeCheckResult(out: *std.Io.Writer, current: []const u8, target: []const u8, explicit: bool) !void {
    if (explicit) {
        if (!std.mem.eql(u8, current, target)) {
            try out.print("Version {s} is available (current: {s})\n", .{ target, current });
        } else {
            try out.print("You are already on version: {s}\n", .{current});
        }
    } else {
        if (isNewerVersion(current, target)) {
            try out.print("New version available: {s} (current: {s})\n", .{ target, current });
        } else {
            try out.print("You are already on the latest version: {s}\n", .{current});
        }
    }
}

/// Compare two version strings using full SemVer 2.0 precedence.
/// Returns true if `latest` is strictly newer than `current`.
///
/// Backed by `std.SemanticVersion`, so pre-release versions order correctly:
/// a pre-release is lower than its release (1.0.0-rc1 < 1.0.0), pre-release
/// identifiers compare per SemVer 2.0 (numeric < alphanumeric, dot-separated),
/// and build metadata is ignored. When either string is not valid SemVer
/// (`std.SemanticVersion.parse` fails — e.g. a two-component "1.2" or a
/// non-numeric core), we fall back to a plain string inequality: unknown vs
/// unknown is the safest conservative answer, and the old parseInt-based
/// parser mishandled every pre-release tag.
fn isNewerVersion(current: []const u8, latest: []const u8) bool {
    // Strip a leading 'v' if present (tags like v1.2.3).
    const current_clean = if (std.mem.startsWith(u8, current, "v")) current[1..] else current;
    const latest_clean = if (std.mem.startsWith(u8, latest, "v")) latest[1..] else latest;

    const current_ver = std.SemanticVersion.parse(current_clean) catch {
        return !std.mem.eql(u8, current_clean, latest_clean);
    };
    const latest_ver = std.SemanticVersion.parse(latest_clean) catch {
        return !std.mem.eql(u8, current_clean, latest_clean);
    };

    return latest_ver.order(current_ver) == .gt;
}

/// Detect current platform (OS and architecture). OS and CPU arch are
/// comptime-known, so an unsupported target is a build-time error for the
/// consuming app rather than a runtime failure — you can never ship an
/// upgrade command whose asset name it cannot construct.
fn detectPlatform(allocator: std.mem.Allocator) ![]const u8 {
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => @compileError("zcli_github_upgrade: unsupported OS '" ++ @tagName(builtin.os.tag) ++ "' (supported: linux, macos, windows)"),
    };

    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => @compileError("zcli_github_upgrade: unsupported CPU arch '" ++ @tagName(builtin.cpu.arch) ++ "' (supported: x86_64, aarch64)"),
    };

    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch, os });
}

/// Permissions for the scratch directory: private to the owner — it holds a
/// soon-to-be-executed binary while it is downloaded and verified.
const scratch_dir_permissions: std.Io.Dir.Permissions = @enumFromInt(0o700);

/// Length of a scratch directory name: the ".upgrade-" prefix plus 16 hex chars.
const scratch_name_len = ".upgrade-".len + 16;

/// A random, unpredictable name for the scratch directory, so a local attacker
/// cannot pre-plant anything (e.g. a symlink) at the download path.
fn randomScratchName(io: std.Io, buf: *[scratch_name_len]u8) []const u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const hex = std.fmt.bytesToHex(&random_bytes, .lower);
    return std.fmt.bufPrint(buf, ".upgrade-{s}", .{hex}) catch unreachable;
}

/// Fetch and integrity-check the release asset into `dir` (the private scratch
/// directory), leaving a verified `binary_name` behind on success. This is the
/// security-load-bearing pipeline: download the asset, then `verifyChecksum`
/// (which — when `public_key` is set — first authenticates checksums.txt under
/// the pinned minisign key, fail closed). Every failure aborts before the file
/// is trusted; the caller's atomic swap runs only if this returns cleanly.
///
/// `download_base` is the release-download host (`github_download_base` in
/// production; a loopback base in tests). Factored out of `executeUpgrade` so
/// the whole fetch→download→verify path can be driven against a fake GitHub in
/// an integration test without a live command context.
pub fn downloadAndVerify(
    allocator: std.mem.Allocator,
    io: std.Io,
    err_out: *std.Io.Writer,
    download_base: []const u8,
    dir: std.Io.Dir,
    repo: []const u8,
    cli_name: []const u8,
    version: []const u8,
    binary_name: []const u8,
    public_key: ?[]const u8,
) !void {
    try downloadBinary(allocator, io, err_out, download_base, dir, repo, cli_name, version, binary_name);
    try verifyChecksum(allocator, io, err_out, download_base, dir, repo, cli_name, version, binary_name, public_key);
}

/// Download the release binary into `dir` (the private scratch directory) as a
/// file named `binary_name`. `download_base` is the release-download host
/// (`github_download_base` in production; a loopback base in tests).
fn downloadBinary(allocator: std.mem.Allocator, io: std.Io, err_out: *std.Io.Writer, download_base: []const u8, dir: std.Io.Dir, repo: []const u8, cli_name: []const u8, version: []const u8, binary_name: []const u8) !void {
    const url = try buildDownloadUrl(allocator, download_base, repo, cli_name, version, binary_name);
    defer allocator.free(url);

    var client = http.Client.init(allocator, io, .{
        .max_response_bytes = MAX_BINARY_SIZE,
        .timeout = download_timeout,
    });
    defer client.deinit();

    var response = try client.get(url);
    defer response.deinit();

    // Check for rate limiting
    if (response.status == .too_many_requests) {
        err_out.print("GitHub API rate limit exceeded while downloading binary.\n", .{}) catch {};
        return error.RateLimitExceeded;
    }

    if (response.status != .ok) {
        switch (response.status) {
            .not_found => {
                err_out.print("Error: Binary not found at URL: {s}\n", .{url}) catch {};
                err_out.print("Expected binary name: {s}\n", .{binary_name}) catch {};
                err_out.print("Verify that the release contains binaries for your platform.\n", .{}) catch {};
            },
            else => err_out.print("Failed to download binary from {s}, status: {}\n", .{ url, response.status }) catch {},
        }
        return error.FailedToDownloadBinary;
    }

    // Write to file. Exclusive: the scratch dir was freshly created and is
    // private, so anything already sitting at this name is an attack or a bug.
    var temp_file = try dir.createFile(io, binary_name, .{ .exclusive = true });
    defer temp_file.close(io);
    try temp_file.writeStreamingAll(io, response.body);
}

/// Verify the integrity of the downloaded binary at `binary_name` within `dir`.
///
/// When `public_key` is non-null, `checksums.txt` is first authenticated against
/// its `checksums.txt.minisig` signature under the pinned key — fail closed —
/// so the digest we compare the binary against is one we've cryptographically
/// trusted, not merely one that happened to ship in the same release.
fn verifyChecksum(allocator: std.mem.Allocator, io: std.Io, err_out: *std.Io.Writer, download_base: []const u8, dir: std.Io.Dir, repo: []const u8, cli_name: []const u8, version: []const u8, binary_name: []const u8, public_key: ?[]const u8) !void {
    // Download checksums.txt (published as a release asset alongside the binaries)
    const checksums_url = try buildDownloadUrl(allocator, download_base, repo, cli_name, version, "checksums.txt");
    defer allocator.free(checksums_url);

    var client = http.Client.init(allocator, io, .{
        .max_response_bytes = MAX_CHECKSUMS_SIZE,
        .timeout = api_timeout,
    });
    defer client.deinit();

    var response = try client.get(checksums_url);
    defer response.deinit();

    // Check for rate limiting
    if (response.status == .too_many_requests) {
        err_out.print("GitHub API rate limit exceeded while downloading checksums.\n", .{}) catch {};
        return error.RateLimitExceeded;
    }

    if (response.status != .ok) {
        switch (response.status) {
            .not_found => {
                err_out.print("Error: Checksums file not found at URL: {s}\n", .{checksums_url}) catch {};
                err_out.print("Refusing to install an unverifiable binary.\n", .{}) catch {};
            },
            else => err_out.print("Failed to download checksums from {s}, status: {}\n", .{ checksums_url, response.status }) catch {},
        }
        return error.FailedToDownloadChecksums;
    }

    // Authenticate checksums.txt under the pinned signing key before trusting a
    // single byte of it. This is the check that a compromised publisher — who
    // can rewrite checksums.txt to match a swapped binary — cannot defeat.
    if (public_key) |pinned_key| {
        try verifyChecksumsSignature(allocator, io, err_out, download_base, repo, cli_name, version, response.body, pinned_key);
    }

    // Find the checksum for our binary
    const expected_checksum = parseExpectedChecksum(response.body, binary_name) orelse {
        err_out.print("Error: Checksum not found for binary: {s}\n", .{binary_name}) catch {};
        err_out.print("The checksums.txt file may be incomplete or corrupted.\n", .{}) catch {};
        return error.ChecksumNotFound;
    };

    // Calculate actual checksum of the downloaded binary
    const actual_checksum = try sha256FileHex(io, dir, binary_name);

    // Compare checksums
    if (!std.mem.eql(u8, expected_checksum, &actual_checksum)) {
        err_out.print("Error: Checksum mismatch for binary: {s}\n", .{binary_name}) catch {};
        err_out.print("Expected: {s}\n", .{expected_checksum}) catch {};
        err_out.print("Actual:   {s}\n", .{&actual_checksum}) catch {};
        err_out.print("The downloaded binary may be corrupted or tampered with.\n", .{}) catch {};
        return error.ChecksumMismatch;
    }
}

/// Download `checksums.txt.minisig` and verify it against `checksums_body` under
/// the pinned minisign `public_key_b64`. Fails closed on every unhappy path — a
/// missing signature asset, a malformed pinned key, or an invalid signature all
/// abort the upgrade rather than fall back to unverified checksums.
fn verifyChecksumsSignature(
    allocator: std.mem.Allocator,
    io: std.Io,
    err_out: *std.Io.Writer,
    download_base: []const u8,
    repo: []const u8,
    cli_name: []const u8,
    version: []const u8,
    checksums_body: []const u8,
    public_key_b64: []const u8,
) !void {
    // A malformed pinned key is a build-time misconfiguration of the consuming
    // app, not an attack — but it must still fail closed, never silently skip.
    const pinned = minisign.PublicKey.parse(public_key_b64) catch {
        err_out.print("Error: the pinned minisign public key is malformed.\n", .{}) catch {};
        err_out.print("This is a configuration error in the application's build.\n", .{}) catch {};
        return error.InvalidPinnedPublicKey;
    };

    const sig_url = try buildDownloadUrl(allocator, download_base, repo, cli_name, version, "checksums.txt.minisig");
    defer allocator.free(sig_url);

    var client = http.Client.init(allocator, io, .{
        .max_response_bytes = MAX_SIGNATURE_SIZE,
        .timeout = api_timeout,
    });
    defer client.deinit();

    var response = try client.get(sig_url);
    defer response.deinit();

    if (response.status == .too_many_requests) {
        err_out.print("GitHub API rate limit exceeded while downloading signature.\n", .{}) catch {};
        return error.RateLimitExceeded;
    }

    if (response.status != .ok) {
        switch (response.status) {
            .not_found => {
                err_out.print("Error: Signature file not found at URL: {s}\n", .{sig_url}) catch {};
                err_out.print("This release is unsigned; refusing to install an unverifiable binary.\n", .{}) catch {};
            },
            else => err_out.print("Failed to download signature from {s}, status: {}\n", .{ sig_url, response.status }) catch {},
        }
        return error.FailedToDownloadSignature;
    }

    minisign.verify(pinned, response.body, checksums_body) catch |err| {
        err_out.print("Error: signature verification failed for checksums.txt ({s}).\n", .{@errorName(err)}) catch {};
        err_out.print("The release may have been tampered with. Refusing to install.\n", .{}) catch {};
        return error.SignatureVerificationFailed;
    };

    // Bind the signature to THIS release. The primary signature above only
    // authenticates checksums.txt, which names artifacts but carries no version
    // — so a compromised publisher could drop an older release's binary,
    // checksums.txt, and its genuine .minisig into the latest tag and pass every
    // check above, silently rolling the user back to a previously-signed
    // (possibly vulnerable) build (CWE-294 downgrade). minisign's global
    // signature covers the trusted comment, into which the signing ceremony
    // embeds the release tag; verifying that comment binds the artifact to the
    // exact tag we are installing and defeats the replay.
    const expected_tag = try std.fmt.allocPrint(allocator, "{s}-v{s}", .{ cli_name, version });
    defer allocator.free(expected_tag);
    minisign.verifyTrustedComment(pinned, response.body, expected_tag) catch |err| {
        err_out.print("Error: release version verification failed for {s} ({s}).\n", .{ expected_tag, @errorName(err) }) catch {};
        err_out.print("The signed release does not match the version being installed — refusing a possible downgrade/replay.\n", .{}) catch {};
        return error.VersionVerificationFailed;
    };
}

/// Find the expected checksum for `binary_name` in a `checksums.txt` body.
/// Each line is formatted `<sha256-hex>  <filename>`; the first line whose
/// filename contains `binary_name` wins. Returns the hex digest borrowed from
/// `content`, or null if no matching entry exists.
/// Find the digest for exactly `binary_name` in a checksums.txt. Lines are
/// `<hex digest>  <filename>` (shasum/sha256sum format; the filename may carry
/// a leading `*` binary-mode marker). The filename column is compared exactly
/// — the previous whole-line substring match could pick the line for
/// `myapp-x86_64-linux-debug` when looking for `myapp-x86_64-linux` and fail
/// the upgrade with a bogus checksum mismatch.
fn parseExpectedChecksum(content: []const u8, binary_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const digest = parts.next() orelse continue;
        var name = parts.next() orelse continue;
        if (std.mem.startsWith(u8, name, "*")) name = name[1..];
        if (std.mem.eql(u8, name, binary_name)) return digest;
    }
    return null;
}

/// Compute the lowercase hex SHA-256 digest of `sub_path` within `dir`.
fn sha256FileHex(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) ![64]u8 {
    const file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = file_reader.interface.readSliceShort(&buffer) catch break;
        if (n == 0) break;
        hasher.update(buffer[0..n]);
    }

    var hash_bytes: [32]u8 = undefined;
    hasher.final(&hash_bytes);
    return std.fmt.bytesToHex(&hash_bytes, .lower);
}

/// Smoke-test the downloaded binary before it replaces the live one: run
/// `<binary> --version` from `dir` and require the process to exec and
/// terminate normally. The checksum already proves the bytes match the
/// release; this catches assets that are unrunnable anyway — e.g. a release
/// published with the wrong architecture's binary under this platform's
/// asset name, which exec rejects. The exit code is deliberately ignored:
/// the version plugin is optional, so `--version` may legitimately exit
/// nonzero in apps without it.
fn testBinary(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, binary_name: []const u8) !void {
    // "./" so the spawn resolves against `dir`, never PATH.
    const argv0 = try std.fmt.allocPrint(allocator, "./{s}", .{binary_name});
    defer allocator.free(argv0);

    var child = std.process.spawn(io, .{
        .argv = &.{ argv0, "--version" },
        .cwd = .{ .dir = dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.NewBinaryFailedToRun;
    const term = child.wait(io) catch return error.NewBinaryFailedToRun;
    if (term != .exited) return error.NewBinaryFailedToRun;
}

/// Replace `target_path` (an absolute path, or a path within `dir`) with the
/// binary at `new_binary_path` (within `dir`), keeping the old binary safe at
/// every step. The strategy differs by platform because Windows will not let
/// you overwrite the image of a *running* executable — only rename it aside:
///
/// Common prologue: copy the new binary to `{target}.new` and (on Unix) mark it
/// executable, so a failure before the swap never touches the live binary.
///
/// Unix: a single atomic rename of `{target}.new` over the target does the swap.
/// rename() is atomic on the same filesystem, so at every instant the target is
/// either the whole old binary or the whole new one — a crash mid-swap leaves
/// the original intact. That property already IS the crash-recovery guarantee,
/// so no separate `{target}.backup` copy is made: it only doubled disk usage
/// and was the weakest link (a best-effort copy that could silently fail).
///
/// Windows: the running .exe can't be overwritten or deleted, but it CAN be
/// renamed. So rename the target to `{target}.backup` (moving the live image
/// out of the way), then rename `{target}.new` into its place. The backup is
/// the still-mapped old image — the OS won't let us delete it until this
/// process exits, so cleanup is best-effort and the next upgrade's rename
/// simply replaces it.
///
/// The move-aside of the live image must go through Win32 `MoveFileExW`, NOT
/// std's `dir.rename`: std opens the source with GENERIC_WRITE-class access to
/// perform a FileRenameInformation set, and the OS refuses that on the image
/// file of a running process (`error.FileBusy`). `MoveFileExW` opens the source
/// with DELETE access only, which the OS *does* permit on a running image — the
/// one Win32 detail this function turns on. See `moveFileReplaceWindows`.
///
/// Takes the directory and paths as parameters so the swap can be exercised
/// against temp files instead of the live executable.
pub fn replaceBinaryAt(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, new_binary_path: []const u8, target_path: []const u8) !void {
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.new", .{target_path});
    defer allocator.free(temp_path);

    // Prologue: stage the new binary alongside the target, executable (Unix).
    try dir.copyFile(new_binary_path, dir, temp_path, io, .{});
    errdefer dir.deleteFile(io, temp_path) catch {};
    if (builtin.os.tag != .windows) {
        const temp_file = try dir.openFile(io, temp_path, .{});
        defer temp_file.close(io);
        try temp_file.setPermissions(io, .executable_file);
    }

    if (builtin.os.tag == .windows) {
        const backup_path = try std.fmt.allocPrint(allocator, "{s}.backup", .{target_path});
        defer allocator.free(backup_path);

        // Move the live image aside (DELETE-access rename via MoveFileExW, which
        // is legal on a running image where std's rename is not). REPLACE flag
        // overwrites any unlocked stale backup left by a prior upgrade whose
        // process has since exited.
        try moveFileReplaceWindows(allocator, io, dir, target_path, backup_path);
        errdefer moveFileReplaceWindows(allocator, io, dir, backup_path, target_path) catch {};
        // The new binary is not a running image, so a plain rename into place is
        // fine (and target no longer exists after the move-aside).
        try dir.rename(temp_path, dir, target_path, io);

        // The old image stays mapped until this process exits, so it can't be
        // deleted now — leave it; the next upgrade's move-aside overwrites it.
        dir.deleteFile(io, backup_path) catch {};
    } else {
        // Atomically swap the new binary over the old one. On a crash mid-swap
        // the target is still the untouched original (rename is atomic).
        try dir.rename(temp_path, dir, target_path, io);
    }
}

/// `MoveFileExW` (kernel32). We call it only to rename the image of a *running*
/// process aside — the one operation std's `dir.rename` cannot do, because it
/// opens the source with GENERIC_WRITE-class access, which the OS denies on a
/// running image. `MoveFileExW` opens the source with DELETE access only, which
/// is permitted. `BOOL` return / `callconv(.winapi)` mirror the other win32
/// declarations in this repo (see zcli_secrets/credential_manager_windows.zig).
const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
extern "kernel32" fn MoveFileExW(
    lpExistingFileName: [*:0]const u16,
    lpNewFileName: ?[*:0]const u16,
    dwFlags: u32,
) callconv(.winapi) std.os.windows.BOOL;

/// Rename `src_sub` → `dst_sub` (both within `dir`) via `MoveFileExW` with
/// REPLACE_EXISTING. `MoveFileExW` takes absolute paths, not dir-relative
/// handles, so we resolve `dir`'s own real path and join each sub-path onto it.
/// Resolving the *directory* (not the files) is deliberate: it avoids opening
/// the running image itself just to canonicalize its path. Used for the
/// live-image move-aside — see `replaceBinaryAt`.
fn moveFileReplaceWindows(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    src_sub: []const u8,
    dst_sub: []const u8,
) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try dir.realPath(io, &buf);
    const dir_abs = buf[0..dir_len];

    // The sub-paths may already be absolute (production passes the exe's full
    // path) or relative (the tests pass a bare name within `dir`). Anchor a
    // relative one to `dir`; use an absolute one as-is (path.join concatenates
    // naively and would double the root of an absolute component).
    const src_abs = try absWithin(allocator, dir_abs, src_sub);
    defer allocator.free(src_abs);
    const dst_abs = try absWithin(allocator, dir_abs, dst_sub);
    defer allocator.free(dst_abs);

    const src_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, src_abs);
    defer allocator.free(src_w);
    const dst_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, dst_abs);
    defer allocator.free(dst_w);

    if (!MoveFileExW(src_w.ptr, dst_w.ptr, MOVEFILE_REPLACE_EXISTING).toBool()) {
        return error.FileBusy;
    }
}

/// Return `sub` as an absolute path: unchanged (duped) if already absolute,
/// otherwise joined onto `dir_abs`. Caller owns the result.
fn absWithin(allocator: std.mem.Allocator, dir_abs: []const u8, sub: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(sub)) return allocator.dupe(u8, sub);
    return std.fs.path.join(allocator, &.{ dir_abs, sub });
}

// ============================================================================
// Tests
// ============================================================================

test "writeCheckResult - --check output reaches stdout (was silently dropped)" {
    const a = std.testing.allocator;

    // Helper: render into an Allocating writer and return the captured bytes.
    const render = struct {
        fn go(alloc: std.mem.Allocator, current: []const u8, target: []const u8, explicit: bool) ![]u8 {
            var aw = std.Io.Writer.Allocating.init(alloc);
            errdefer aw.deinit();
            try writeCheckResult(&aw.writer, current, target, explicit);
            return aw.toOwnedSlice();
        }
    }.go;

    // No-arg check, a newer version is available.
    {
        const out = try render(a, "1.0.0", "1.2.0", false);
        defer a.free(out);
        try std.testing.expectEqualStrings("New version available: 1.2.0 (current: 1.0.0)\n", out);
    }
    // No-arg check, already on the latest (equal, and a stale older "latest").
    {
        const out = try render(a, "1.2.0", "1.2.0", false);
        defer a.free(out);
        try std.testing.expectEqualStrings("You are already on the latest version: 1.2.0\n", out);
    }
    {
        const out = try render(a, "2.0.0", "1.9.0", false); // feed points at an older tag
        defer a.free(out);
        try std.testing.expectEqualStrings("You are already on the latest version: 2.0.0\n", out);
    }
    // Explicit version that differs from current.
    {
        const out = try render(a, "1.0.0", "1.5.0", true);
        defer a.free(out);
        try std.testing.expectEqualStrings("Version 1.5.0 is available (current: 1.0.0)\n", out);
    }
    // Explicit version equal to current.
    {
        const out = try render(a, "1.5.0", "1.5.0", true);
        defer a.free(out);
        try std.testing.expectEqualStrings("You are already on version: 1.5.0\n", out);
    }
}

test "writeUnsignedWarning - names the control and how to fix it" {
    const a = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    try writeUnsignedWarning(&aw.writer);
    const out = aw.written();

    // It must be a warning, name checksum-only verification as the effect,
    // explain the same-release threat, and tell the operator how to pin a key.
    try std.testing.expect(std.mem.startsWith(u8, out, "warning:"));
    try std.testing.expect(std.mem.indexOf(u8, out, "SHA-256 checksum") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "checksums.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "minisign") != null);
}

test "unsigned notice is gated on the comptime verification config" {
    // The notice fires only under the explicit checksum_only opt-out. These
    // two instantiations pin the branch each build takes: with a key pinned,
    // the warning path is dead code the compiler prunes; under checksum_only,
    // it is live. Asserting on the comptime predicate the runtime `if` uses
    // keeps that contract from silently inverting.
    const Signed = init(.{ .repo = "owner/app", .verification = .{ .minisign = "KEY" } });
    const Unsigned = init(.{ .repo = "owner/app", .verification = .checksum_only });
    try std.testing.expect(comptime Signed.pluginConfigForTest().verification != .checksum_only);
    try std.testing.expect(comptime Unsigned.pluginConfigForTest().verification == .checksum_only);
}

test "Config.verification has no default — omitting it is a compile error" {
    // This is a documentation test, not an executable assertion: Zig has no
    // "expect a compile error" facility in a normal test. Config.verification
    // is a required field (no `= ...` default), so `init(.{ .repo = "x" })`
    // fails to compile with Zig's native "missing field" diagnostic — which is
    // the point. Every real instantiation in this file supplies `.verification`
    // explicitly; that absence of a bare `init(.{ .repo = ... })` anywhere in
    // this test suite is the actual coverage for this contract.
}

test "pinned_public_key derivation matches the verification variant" {
    const Signed = init(.{ .repo = "owner/app", .verification = .{ .minisign = "KEY" } });
    const Unsigned = init(.{ .repo = "owner/app", .verification = .checksum_only });
    try std.testing.expectEqualStrings("KEY", Signed.pinned_public_key.?);
    try std.testing.expectEqual(@as(?[]const u8, null), Unsigned.pinned_public_key);
}

test "isNewerVersion - semantic comparison" {
    // Major version differences
    try std.testing.expect(isNewerVersion("1.0.0", "2.0.0"));
    try std.testing.expect(!isNewerVersion("2.0.0", "1.0.0"));
    try std.testing.expect(isNewerVersion("1.9.9", "2.0.0"));

    // Minor version differences
    try std.testing.expect(isNewerVersion("1.0.0", "1.1.0"));
    try std.testing.expect(!isNewerVersion("1.1.0", "1.0.0"));
    try std.testing.expect(isNewerVersion("1.0.9", "1.1.0"));

    // Patch version differences
    try std.testing.expect(isNewerVersion("1.0.0", "1.0.1"));
    try std.testing.expect(!isNewerVersion("1.0.1", "1.0.0"));

    // Same version
    try std.testing.expect(!isNewerVersion("1.0.0", "1.0.0"));

    // Double-digit versions
    try std.testing.expect(isNewerVersion("2.0.0", "10.0.0"));
    try std.testing.expect(isNewerVersion("1.5.0", "1.20.0"));
    try std.testing.expect(isNewerVersion("1.0.5", "1.0.15"));

    // With 'v' prefix
    try std.testing.expect(isNewerVersion("v1.0.0", "v2.0.0"));
    try std.testing.expect(isNewerVersion("v1.0.0", "2.0.0"));
    try std.testing.expect(isNewerVersion("1.0.0", "v2.0.0"));
}

test "security limits - constants are reasonable" {
    // Verify security limits are set to reasonable values. These are enforced
    // by http.Client's max_response_bytes (on the decompressed body).
    try std.testing.expect(MAX_RELEASES_RESPONSE_SIZE == 20 * 1024 * 1024); // 20MB
    try std.testing.expect(MAX_BINARY_SIZE == 100 * 1024 * 1024); // 100MB
    try std.testing.expect(MAX_CHECKSUMS_SIZE == 1024 * 1024); // 1MB

    // Ensure binary size is reasonable for CLI tools
    try std.testing.expect(MAX_BINARY_SIZE >= 1024 * 1024); // At least 1MB
    try std.testing.expect(MAX_BINARY_SIZE <= 500 * 1024 * 1024); // Not more than 500MB

    // The startup check must be dramatically shorter than interactive calls —
    // it runs on every CLI invocation when inform_out_of_date is enabled.
    try std.testing.expect(startup_check_timeout.toSeconds() <= 5);
    try std.testing.expect(api_timeout.toSeconds() >= startup_check_timeout.toSeconds());
}

test "randomScratchName - hidden, fixed-length, unpredictable" {
    var buf_a: [scratch_name_len]u8 = undefined;
    var buf_b: [scratch_name_len]u8 = undefined;
    const a = randomScratchName(std.testing.io, &buf_a);
    const b = randomScratchName(std.testing.io, &buf_b);

    try std.testing.expect(std.mem.startsWith(u8, a, ".upgrade-"));
    try std.testing.expectEqual(scratch_name_len, a.len);
    // 64 bits of CSPRNG entropy per name — a collision means a broken RNG.
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "replaceBinaryAt - atomic replacement strategy" {
    // This test documents the atomic replacement strategy; the behavioral tests
    // below exercise it against temp files.

    // Unix strategy:
    // 1. Copy new binary to temp location (.new suffix), mark executable
    // 2. Single atomic rename of .new over the old binary
    //
    // Benefits:
    // - rename() is atomic on Unix if same filesystem, so the target is always
    //   either the whole old binary or the whole new one
    // - If the process crashes mid-upgrade, the old binary is still intact —
    //   that atomicity IS the crash-recovery guarantee, so no separate .backup
    //   copy is made (it only doubled disk use and could silently fail)
    // - If the rename fails, the old binary is unchanged (errdefer cleans up .new)
    //
    // Windows can't overwrite a running .exe, so there it renames the target to
    // .backup first, then renames .new into place (see the fn doc-comment).
}

test "rate limiting - handles HTTP 429 responses" {
    // This test documents the rate limiting behavior
    // Actual testing would require HTTP mocking

    // All GitHub API calls check for HTTP 429 (Too Many Requests):
    // 1. fetchLatestVersion() - checks releases endpoint
    // 2. downloadBinary() - checks binary download
    // 3. verifyChecksum() - checks checksums.txt download
    //
    // When rate limited:
    // - Returns error.RateLimitExceeded
    // - Logs retry-after time if provided in header
    // - Allows caller to decide whether to retry
    //
    // GitHub rate limits (as of 2024):
    // - Unauthenticated: 60 requests/hour
    // - Authenticated: 5000 requests/hour
}

test "isNewerVersion - pre-release precedence (SemVer 2.0)" {
    // A pre-release is LOWER than its own release: 1.0.0-rc1 < 1.0.0.
    try std.testing.expect(isNewerVersion("1.0.0-rc1", "1.0.0")); // release beats its rc
    try std.testing.expect(!isNewerVersion("1.0.0", "1.0.0-rc1")); // rc does NOT beat release

    // Pre-release identifiers ordered per SemVer: rc1 < rc2, numeric ordering.
    try std.testing.expect(isNewerVersion("1.0.0-rc1", "1.0.0-rc2"));
    try std.testing.expect(!isNewerVersion("1.0.0-rc2", "1.0.0-rc1"));
    try std.testing.expect(isNewerVersion("1.0.0-alpha", "1.0.0-beta")); // alpha < beta (ASCII)
    // Numeric identifiers rank below alphanumeric ones.
    try std.testing.expect(isNewerVersion("1.0.0-1", "1.0.0-alpha"));
    // A larger set of pre-release fields outranks a prefix of it.
    try std.testing.expect(isNewerVersion("1.0.0-alpha", "1.0.0-alpha.1"));

    // Equal pre-releases are not "newer".
    try std.testing.expect(!isNewerVersion("1.0.0-rc1", "1.0.0-rc1"));

    // The core bug this fixes: the old parseInt path could not parse these and
    // fell back to raw string inequality, so 2.0.0-a "beat" 1.0.0-b. Now the
    // numeric core wins first.
    try std.testing.expect(!isNewerVersion("2.0.0-a", "1.0.0-b"));
    try std.testing.expect(isNewerVersion("1.0.0-b", "2.0.0-a"));

    // A pre-release tag must not make a passive "newer" check misfire when the
    // core is the same and only differs by pre-release.
    try std.testing.expect(!isNewerVersion("1.2.3", "1.2.3-rc1"));
}

test "isNewerVersion - build metadata is ignored" {
    // Build metadata does not affect precedence (SemVer 2.0 §10).
    try std.testing.expect(!isNewerVersion("1.0.0+build.1", "1.0.0+build.2"));
    try std.testing.expect(!isNewerVersion("1.0.0", "1.0.0+build.9"));
    try std.testing.expect(isNewerVersion("1.0.0+x", "1.0.1+y"));
}

test "isNewerVersion - malformed tags fall back to string inequality" {
    // Non-SemVer strings (two-component, non-numeric) can't be parsed; the
    // comparison degrades to a plain inequality rather than a bogus order.
    try std.testing.expect(!isNewerVersion("abc", "abc")); // equal → not newer
    try std.testing.expect(isNewerVersion("abc", "def")); // different → "newer" (conservative)
    try std.testing.expect(!isNewerVersion("1.2", "1.2")); // two-component, equal
    try std.testing.expect(isNewerVersion("1.2", "1.3")); // two-component, different
}

test "isNewerVersion - edge cases" {
    // Same versions with different 'v' prefix combinations
    try std.testing.expect(!isNewerVersion("1.0.0", "1.0.0"));
    try std.testing.expect(!isNewerVersion("v1.0.0", "1.0.0"));
    try std.testing.expect(!isNewerVersion("1.0.0", "v1.0.0"));
    try std.testing.expect(!isNewerVersion("v1.0.0", "v1.0.0"));

    // Zero versions
    try std.testing.expect(isNewerVersion("0.0.0", "0.0.1"));
    try std.testing.expect(isNewerVersion("0.0.0", "0.1.0"));
    try std.testing.expect(isNewerVersion("0.0.0", "1.0.0"));
    try std.testing.expect(!isNewerVersion("0.0.1", "0.0.0"));

    // Comparing with malformed versions falls back to string comparison
    // Both are malformed, so it returns false (they're equal strings)
    try std.testing.expect(!isNewerVersion("abc", "abc"));
}

test "detectPlatform - allocator handling" {
    const allocator = std.testing.allocator;

    // Test that detectPlatform properly uses the allocator
    const platform = try detectPlatform(allocator);
    defer allocator.free(platform);

    // Platform should be non-empty
    try std.testing.expect(platform.len > 0);

    // Platform should contain a hyphen (arch-os format)
    try std.testing.expect(std.mem.indexOf(u8, platform, "-") != null);

    // Platform should be one of the expected formats. Windows is included now
    // that self-upgrade supports it (issue #114) — releases ship
    // zcli-{x86_64,aarch64}-windows.exe and detectPlatform maps to them.
    const valid_platforms = [_][]const u8{
        "x86_64-linux",
        "aarch64-linux",
        "x86_64-macos",
        "aarch64-macos",
        "x86_64-windows",
        "aarch64-windows",
    };

    var found = false;
    for (valid_platforms) |valid| {
        if (std.mem.eql(u8, platform, valid)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "parseExpectedChecksum - finds matching binary" {
    const content =
        "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111  myapp-x86_64-linux\n" ++
        "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222  myapp-aarch64-macos\n";

    const linux = parseExpectedChecksum(content, "myapp-x86_64-linux").?;
    try std.testing.expectEqualStrings("aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111", linux);

    const macos = parseExpectedChecksum(content, "myapp-aarch64-macos").?;
    try std.testing.expectEqualStrings("bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222", macos);
}

test "parseExpectedChecksum - missing binary returns null" {
    const content = "abc123  myapp-x86_64-linux\n";
    try std.testing.expectEqual(@as(?[]const u8, null), parseExpectedChecksum(content, "myapp-windows"));
    try std.testing.expectEqual(@as(?[]const u8, null), parseExpectedChecksum("", "myapp-x86_64-linux"));
}

test "parseExpectedChecksum - tolerates trailing newline and no final newline" {
    const with_nl = "deadbeef  bin\n";
    const without_nl = "deadbeef  bin";
    try std.testing.expectEqualStrings("deadbeef", parseExpectedChecksum(with_nl, "bin").?);
    try std.testing.expectEqualStrings("deadbeef", parseExpectedChecksum(without_nl, "bin").?);
}

test "parseExpectedChecksum - exact filename match, not substring" {
    // The -debug asset's name CONTAINS the wanted name and sorts first; a
    // substring match would return its digest and doom the verify step.
    const content =
        "dddd0000dddd0000dddd0000dddd0000dddd0000dddd0000dddd0000dddd0000  myapp-x86_64-linux-debug\n" ++
        "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111  myapp-x86_64-linux\n";

    const digest = parseExpectedChecksum(content, "myapp-x86_64-linux").?;
    try std.testing.expectEqualStrings("aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111", digest);

    // And a name that only exists as a substring of another is NOT found.
    try std.testing.expectEqual(@as(?[]const u8, null), parseExpectedChecksum(content, "x86_64-linux"));
}

test "parseExpectedChecksum - tolerates binary-mode marker and CRLF" {
    // `shasum -b` / `sha256sum -b` prefix the filename with `*`; Windows
    // tooling may emit CRLF line endings.
    const content = "cafe1234cafe1234cafe1234cafe1234cafe1234cafe1234cafe1234cafe1234 *myapp-x86_64-windows.exe\r\n";
    const digest = parseExpectedChecksum(content, "myapp-x86_64-windows.exe").?;
    try std.testing.expectEqualStrings("cafe1234cafe1234cafe1234cafe1234cafe1234cafe1234cafe1234cafe1234", digest);
}

test "sha256FileHex - matches known digest" {
    // SHA-256 of the empty input is a well-known constant.
    const empty_digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write an empty file and hash it through the real file-reading path.
    {
        const f = try tmp.dir.createFile(std.testing.io, "empty.bin", .{});
        f.close(std.testing.io);
    }

    const digest = try sha256FileHex(std.testing.io, tmp.dir, "empty.bin");
    try std.testing.expectEqualStrings(empty_digest, &digest);
}

test "sha256FileHex - hashes file contents" {
    // SHA-256 of "abc".
    const abc_digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data.bin", .data = "abc" });

    const digest = try sha256FileHex(std.testing.io, tmp.dir, "data.bin");
    try std.testing.expectEqualStrings(abc_digest, &digest);
}

test "checksum verification - end-to-end parse + hash + compare" {
    // Simulate the pure half of verifyChecksum: parse the expected digest from a
    // checksums.txt body, hash the local binary, and confirm they match/mismatch.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "myapp-x86_64-linux", .data = "abc" });

    const abc_digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const good = try std.fmt.allocPrint(std.testing.allocator, "{s}  myapp-x86_64-linux\n", .{abc_digest});
    defer std.testing.allocator.free(good);

    const expected = parseExpectedChecksum(good, "myapp-x86_64-linux").?;
    const actual = try sha256FileHex(std.testing.io, tmp.dir, "myapp-x86_64-linux");
    try std.testing.expect(std.mem.eql(u8, expected, &actual));

    // A tampered binary must NOT match the recorded checksum.
    const bad = "0000000000000000000000000000000000000000000000000000000000000000  myapp-x86_64-linux\n";
    const bad_expected = parseExpectedChecksum(bad, "myapp-x86_64-linux").?;
    try std.testing.expect(!std.mem.eql(u8, bad_expected, &actual));
}

// ----------------------------------------------------------------------------
// URL construction
// ----------------------------------------------------------------------------

test "buildReleasesUrl - exact GitHub API URL" {
    const a = std.testing.allocator;
    const url = try buildReleasesUrl(a, github_api_base, "owner/repo");
    defer a.free(url);
    try std.testing.expectEqualStrings("https://api.github.com/repos/owner/repo/releases", url);
}

test "buildDownloadUrl - binary and checksums asset URLs use the {cli}-v{ver} tag" {
    const a = std.testing.allocator;

    const bin = try buildDownloadUrl(a, github_download_base, "owner/repo", "myapp", "1.2.3", "myapp-x86_64-linux");
    defer a.free(bin);
    try std.testing.expectEqualStrings(
        "https://github.com/owner/repo/releases/download/myapp-v1.2.3/myapp-x86_64-linux",
        bin,
    );

    const sums = try buildDownloadUrl(a, github_download_base, "owner/repo", "myapp", "1.2.3", "checksums.txt");
    defer a.free(sums);
    try std.testing.expectEqualStrings(
        "https://github.com/owner/repo/releases/download/myapp-v1.2.3/checksums.txt",
        sums,
    );
}

test "selectVersion validates the latest tag like an explicit version (#395)" {
    const a = std.testing.allocator;

    // A well-formed tag passes.
    const good = try selectVersion(a, "[{\"tag_name\": \"myapp-v1.2.3\"}]", "myapp");
    defer a.free(good);
    try std.testing.expectEqualStrings("1.2.3", good);

    // A crafted tag that would path-traverse the download URL fails closed.
    try std.testing.expectError(error.InvalidVersionTag, selectVersion(
        a,
        "[{\"tag_name\": \"myapp-v../../evil/releases/download/other-v9.9.9\"}]",
        "myapp",
    ));
}

test "isValidVersionArg - accepts real version tags" {
    try std.testing.expect(isValidVersionArg("1.2.3"));
    try std.testing.expect(isValidVersionArg("v1.2.3"));
    try std.testing.expect(isValidVersionArg("1.2.3-rc1"));
    try std.testing.expect(isValidVersionArg("nightly_2026-07-14"));
}

test "isValidVersionArg - rejects SemVer build metadata ('+' is outside the allowlist)" {
    // `+build.9` is valid SemVer but not a character zcli's own release tags (or
    // any observed real-world tag) use; excluding it keeps the allowlist to
    // exactly what's needed rather than growing it to match SemVer's full grammar.
    try std.testing.expect(!isValidVersionArg("1.2.3+build.9"));
}

test "isValidVersionArg - rejects the empty string" {
    try std.testing.expect(!isValidVersionArg(""));
}

test "isValidVersionArg - rejects anything that could escape the URL path segment" {
    // The value this guards is interpolated straight into
    // ".../releases/download/{cli}-v{version}/..." (buildDownloadUrl) — a
    // path-traversal payload here reaches a different release, or repo,
    // entirely within github.com.
    try std.testing.expect(!isValidVersionArg("../../owner/repo/releases/download/other-v9.9.9/asset"));
    try std.testing.expect(!isValidVersionArg("1.2.3/../../evil"));
    try std.testing.expect(!isValidVersionArg("1.2.3/evil"));
    try std.testing.expect(!isValidVersionArg("1.2.3?query=1"));
    try std.testing.expect(!isValidVersionArg("1.2.3#frag"));
    try std.testing.expect(!isValidVersionArg("1.2.3 "));
    try std.testing.expect(!isValidVersionArg("1.2.3\n"));
    try std.testing.expect(!isValidVersionArg("1.2.3\\evil"));
}

// ----------------------------------------------------------------------------
// Release selection from the releases JSON
// ----------------------------------------------------------------------------

test "selectVersion - returns the version for the matching cli prefix" {
    const a = std.testing.allocator;
    const v = try selectVersion(a, "[{\"tag_name\":\"myapp-v1.2.3\"}]", "myapp");
    defer a.free(v);
    try std.testing.expectEqualStrings("1.2.3", v);
}

test "selectVersion - returns the FIRST matching release, ignoring other apps" {
    const a = std.testing.allocator;
    const body = "[{\"tag_name\":\"other-v9.9.9\"},{\"tag_name\":\"myapp-v2.0.0\"},{\"tag_name\":\"myapp-v1.0.0\"}]";
    const v = try selectVersion(a, body, "myapp");
    defer a.free(v);
    // Order is preserved as published; selection does not sort by semver.
    try std.testing.expectEqualStrings("2.0.0", v);
}

test "selectVersion - object (error) response is rejected" {
    const a = std.testing.allocator;
    // GitHub returns an object like {"message":"Not Found"} for errors.
    try std.testing.expectError(error.UnexpectedResponse, selectVersion(a, "{\"message\":\"Not Found\"}", "myapp"));
}

test "selectVersion - no matching prefix and empty array both error" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NoMatchingRelease, selectVersion(a, "[{\"tag_name\":\"other-v1.0.0\"}]", "myapp"));
    try std.testing.expectError(error.NoMatchingRelease, selectVersion(a, "[]", "myapp"));
}

test "selectVersion - ignores unknown fields, keeps well-formed entries" {
    const a = std.testing.allocator;
    // Extra fields on each release object are ignored (ignore_unknown_fields);
    // only tag_name is modeled. The first matching prefix wins.
    const body = "[{\"tag_name\":\"other-v9.9.9\",\"draft\":false}," ++
        "{\"tag_name\":\"myapp-v3.1.4\",\"name\":\"v3.1.4\",\"assets\":[]}]";
    const v = try selectVersion(a, body, "myapp");
    defer a.free(v);
    try std.testing.expectEqualStrings("3.1.4", v);
}

test "selectVersion - a malformed release array fails closed (UnexpectedResponse)" {
    const a = std.testing.allocator;
    // A real GitHub feed never mixes non-objects or a numeric tag_name into the
    // releases array; a body that does is not a trustworthy release list, so the
    // typed parse fails closed rather than trying to salvage entries.
    try std.testing.expectError(error.UnexpectedResponse, selectVersion(a, "[1, \"x\", {\"tag_name\":\"myapp-v3.1.4\"}]", "myapp"));
    try std.testing.expectError(error.UnexpectedResponse, selectVersion(a, "[{\"tag_name\":123}]", "myapp"));
}

test "selectVersion - non-JSON body (e.g. an HTML error page) is UnexpectedResponse" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedResponse, selectVersion(a, "<html>rate limited</html>", "myapp"));
}

// ----------------------------------------------------------------------------
// Atomic binary replacement
// ----------------------------------------------------------------------------

test "replaceBinaryAt - swaps in the new binary and removes the backup" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "current", .data = "OLD-BINARY" });
    try tmp.dir.writeFile(io, .{ .sub_path = "downloaded", .data = "NEW-BINARY-CONTENT" });

    try replaceBinaryAt(a, io, tmp.dir, "downloaded", "current");

    // The target now holds the new contents.
    const got = try tmp.dir.readFileAlloc(io, "current", a, .limited(1024));
    defer a.free(got);
    try std.testing.expectEqualStrings("NEW-BINARY-CONTENT", got);

    // Backup and temp artifacts are cleaned up on success.
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "current.backup", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "current.new", .{}));

    // The downloaded source file is left intact (the caller owns its cleanup).
    const src = try tmp.dir.readFileAlloc(io, "downloaded", a, .limited(1024));
    defer a.free(src);
    try std.testing.expectEqualStrings("NEW-BINARY-CONTENT", src);
}

test "replaceBinaryAt - a stale backup from a prior upgrade does not block the swap" {
    // A previous upgrade may have left a {target}.backup behind (on Windows the
    // old image can't be deleted while the replaced process is still running).
    // The next upgrade must still succeed: rename() replaces the unlocked stale
    // backup. This exercises the Windows rename-aside branch on the Windows CI
    // runner (test-core) as well as the Unix path elsewhere.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "current", .data = "OLD-BINARY" });
    try tmp.dir.writeFile(io, .{ .sub_path = "current.backup", .data = "STALE-BACKUP" });
    try tmp.dir.writeFile(io, .{ .sub_path = "downloaded", .data = "NEW-BINARY-CONTENT" });

    try replaceBinaryAt(a, io, tmp.dir, "downloaded", "current");

    const got = try tmp.dir.readFileAlloc(io, "current", a, .limited(1024));
    defer a.free(got);
    try std.testing.expectEqualStrings("NEW-BINARY-CONTENT", got);
}

test "replaceBinaryAt - a missing new binary leaves the target untouched" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "current", .data = "ORIGINAL" });

    // Copying a nonexistent new binary must fail...
    try std.testing.expectError(error.FileNotFound, replaceBinaryAt(a, io, tmp.dir, "does-not-exist", "current"));

    // ...and the original target must survive unharmed (never renamed over).
    const got = try tmp.dir.readFileAlloc(io, "current", a, .limited(1024));
    defer a.free(got);
    try std.testing.expectEqualStrings("ORIGINAL", got);
}

/// Write an executable shell script named `name` into `dir` (POSIX only).
fn writeTestScript(io: std.Io, dir: std.Io.Dir, name: []const u8, body: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = body });
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    try file.setPermissions(io, .executable_file);
}

test "testBinary - accepts a binary that execs and exits, regardless of exit code" {
    if (builtin.os.tag == .windows) return; // shell-script fixtures are POSIX-only
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestScript(io, tmp.dir, "ok", "#!/bin/sh\nexit 0\n");
    try testBinary(a, io, tmp.dir, "ok");

    // Exit code is deliberately not checked: `--version` may exit nonzero in
    // apps without the version plugin. Only "does it exec and terminate
    // normally" matters.
    try writeTestScript(io, tmp.dir, "grumpy", "#!/bin/sh\nexit 3\n");
    try testBinary(a, io, tmp.dir, "grumpy");
}

test "testBinary - rejects a binary that cannot exec or dies on a signal" {
    if (builtin.os.tag == .windows) return; // shell-script fixtures are POSIX-only
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Garbage bytes with the executable bit: exec rejects it (the wrong-arch
    // release-asset case this check exists for).
    try writeTestScript(io, tmp.dir, "garbage", "\x7fNOT-AN-ELF-OR-MACHO\x00\x01\x02");
    try std.testing.expectError(error.NewBinaryFailedToRun, testBinary(a, io, tmp.dir, "garbage"));

    // Missing file: spawn fails outright.
    try std.testing.expectError(error.NewBinaryFailedToRun, testBinary(a, io, tmp.dir, "does-not-exist"));

    // A binary that dies on a signal did not "terminate normally".
    try writeTestScript(io, tmp.dir, "suicidal", "#!/bin/sh\nkill -9 $$\n");
    try std.testing.expectError(error.NewBinaryFailedToRun, testBinary(a, io, tmp.dir, "suicidal"));
}

test "checkedRecently - skip window semantics" {
    // Never checked → probe.
    try std.testing.expect(!checkedRecently(null, 1000, 100));
    // Checked within the window → skip.
    try std.testing.expect(checkedRecently(950, 1000, 100));
    try std.testing.expect(checkedRecently(1000, 1000, 100)); // just now
    // Window elapsed → probe.
    try std.testing.expect(!checkedRecently(900, 1000, 100));
    // Future timestamp (clock skew / corrupt cache) → probe; the caller
    // rewrites a sane value.
    try std.testing.expect(!checkedRecently(2000, 1000, 100));
}

test "lastCheckFilePath - platform-standard location from the threaded environ" {
    const a = std.testing.allocator;

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();

    switch (builtin.os.tag) {
        .windows => {
            try env.put("LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local");
            const path = (try lastCheckFilePath(a, &env, "myapp")).?;
            defer a.free(path);
            try std.testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\myapp\\last-update-check", path);
        },
        .macos => {
            try env.put("HOME", "/Users/u");
            const path = (try lastCheckFilePath(a, &env, "myapp")).?;
            defer a.free(path);
            try std.testing.expectEqualStrings("/Users/u/Library/Caches/myapp/last-update-check", path);
        },
        else => {
            try env.put("HOME", "/home/u");
            const fallback = (try lastCheckFilePath(a, &env, "myapp")).?;
            defer a.free(fallback);
            try std.testing.expectEqualStrings("/home/u/.cache/myapp/last-update-check", fallback);

            // XDG_CACHE_HOME wins over the ~/.cache fallback when set.
            try env.put("XDG_CACHE_HOME", "/home/u/.xdg-cache");
            const xdg = (try lastCheckFilePath(a, &env, "myapp")).?;
            defer a.free(xdg);
            try std.testing.expectEqualStrings("/home/u/.xdg-cache/myapp/last-update-check", xdg);
        },
    }
}

test "lastCheckFilePath - missing environment reads as no cache (null)" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), try lastCheckFilePath(a, &env, "myapp"));
}

test "last-check cache round-trips, tolerates garbage, and creates parents" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = "myapp/last-update-check";

    // Never checked: no file yet.
    try std.testing.expectEqual(@as(?i64, null), readLastCheck(a, io, tmp.dir, path));

    // Round-trip, with the parent directory created on demand.
    try writeLastCheck(io, tmp.dir, path, 1_700_000_000);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), readLastCheck(a, io, tmp.dir, path));

    // Garbage contents read as "never checked", not an error.
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "not-a-number\n" });
    try std.testing.expectEqual(@as(?i64, null), readLastCheck(a, io, tmp.dir, path));
}
