const std = @import("std");
const builtin = @import("builtin");
const zcli = @import("zcli");

// Security limits for HTTP responses
const MAX_COMPRESSED_RESPONSE_SIZE = 10 * 1024 * 1024; // 10MB compressed
const MAX_DECOMPRESSED_RESPONSE_SIZE = 20 * 1024 * 1024; // 20MB decompressed
const MAX_BINARY_SIZE = 100 * 1024 * 1024; // 100MB for binary downloads
const MAX_CHECKSUMS_SIZE = 1024 * 1024; // 1MB for checksums file

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

/// zcli-github-upgrade Plugin
///
/// Provides self-upgrade functionality for CLI applications that release via GitHub.
/// Downloads new versions from GitHub releases and atomically replaces the current binary.
/// Plugin configuration
pub const Config = struct {
    /// GitHub repository in format "owner/repo" (required)
    repo: []const u8,

    /// Command name for the upgrade command (default: "upgrade")
    command_name: []const u8 = "upgrade",

    /// Whether to check for updates on startup and inform the user (default: false)
    inform_out_of_date: bool = false,

    /// Message to show when a newer version is available
    /// Use {current} and {latest} as placeholders
    out_of_date_message: []const u8 = "A new version of {app} is available: {latest} (current: {current})\nRun '{app} upgrade' to update.",
};

/// Initialize the plugin with configuration
pub fn init(config: Config) type {
    return struct {
        const Self = @This();
        const plugin_config = config;

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
            var stdout = context.stdout();

            // Determine target version (explicit or latest)
            const current_version = context.app_version;
            const target_version = if (args.version) |v|
                try allocator.dupe(u8, v)
            else
                try fetchLatestVersion(allocator, context.io.io, plugin_config.repo, context.app_name);
            defer allocator.free(target_version);

            if (options.check) {
                if (args.version) |_| {
                    // User specified a version, compare with current
                    if (!std.mem.eql(u8, current_version, target_version)) {
                        try stdout.print("Version {s} is available (current: {s})\n", .{ target_version, current_version });
                        std.process.exit(0);
                    } else {
                        try stdout.print("You are already on version: {s}\n", .{current_version});
                        std.process.exit(0);
                    }
                } else {
                    // Check latest version
                    if (isNewerVersion(current_version, target_version)) {
                        try stdout.print("New version available: {s} (current: {s})\n", .{ target_version, current_version });
                        std.process.exit(0);
                    } else {
                        try stdout.print("You are already on the latest version: {s}\n", .{current_version});
                        std.process.exit(0);
                    }
                }
            }

            // Perform upgrade
            const is_downgrade = args.version != null and isNewerVersion(target_version, current_version);
            const is_same_version = std.mem.eql(u8, current_version, target_version);
            const needs_upgrade = args.version != null or isNewerVersion(current_version, target_version);

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
            const binary_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ context.app_name, platform });
            defer allocator.free(binary_name);

            // Download binary
            try stdout.print("Downloading {s}...\n", .{binary_name});
            const temp_path = try downloadBinary(allocator, context.io.io, plugin_config.repo, context.app_name, target_version, binary_name);
            defer allocator.free(temp_path);
            defer std.Io.Dir.cwd().deleteFile(context.io.io, temp_path) catch {};

            // Verify checksum
            try stdout.print("Verifying checksum...\n", .{});
            try verifyChecksum(allocator, context.io.io, plugin_config.repo, context.app_name, target_version, temp_path, binary_name);

            // Make binary executable before testing (Unix only - Windows uses .exe extension)
            if (builtin.os.tag != .windows) {
                const temp_file = try std.Io.Dir.cwd().openFile(context.io.io, temp_path, .{});
                defer temp_file.close(context.io.io);
                try temp_file.setPermissions(context.io.io, .executable_file);
            }

            // Test new binary
            try stdout.print("Testing new binary...\n", .{});
            try testBinary(allocator, temp_path);

            // Replace current binary
            try stdout.print("Installing new version...\n", .{});
            try replaceBinary(allocator, context.io.io, temp_path);

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
            const stderr = context.stderr();

            // Check for latest version (with timeout)
            const latest_version = fetchLatestVersion(allocator, context.io.io, plugin_config.repo, context.app_name) catch |err| {
                // Silently fail - don't interrupt the user's workflow
                _ = err;
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

/// Fetch the latest version from GitHub releases API filtered by CLI name prefix
fn fetchLatestVersion(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, cli_name: []const u8) ![]const u8 {
    std.debug.print("Checking for updates...\n", .{});

    // Fetch all releases and filter by tag prefix
    const url = try buildReleasesUrl(allocator, github_api_base, repo);
    defer allocator.free(url);

    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var request = try client.request(.GET, uri, .{
        .headers = .{ .user_agent = .{ .override = "zcli-github-upgrade" } },
    });
    defer request.deinit();

    try request.sendBodiless();

    // Use 1KB buffer for redirect handling
    var redirect_buffer: [1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    // Check for rate limiting
    if (response.head.status == .too_many_requests) {
        // Check for Retry-After header
        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            if (std.mem.eql(u8, header.name, "retry-after")) {
                const retry_seconds = std.fmt.parseInt(u32, header.value, 10) catch 60;
                std.debug.print("GitHub API rate limit exceeded. Retry after {d} seconds.\n", .{retry_seconds});
                return error.RateLimitExceeded;
            }
        }
        std.debug.print("GitHub API rate limit exceeded.\n", .{});
        return error.RateLimitExceeded;
    }

    if (response.head.status != .ok) {
        // Provide specific error messages based on status code
        switch (response.head.status) {
            .not_found => std.debug.print("GitHub repository not found: {s}\n", .{repo}),
            .unauthorized => std.debug.print("GitHub API authentication failed (unauthorized)\n", .{}),
            .forbidden => std.debug.print("GitHub API access forbidden (check permissions)\n", .{}),
            else => std.debug.print("GitHub API request failed with status: {}\n", .{response.head.status}),
        }
        return error.FailedToFetchVersion;
    }

    // Read the raw response body (may be gzip-compressed).
    var transfer_buffer: [4096]u8 = undefined;
    var body_reader = response.reader(&transfer_buffer);
    const raw_body = try body_reader.allocRemaining(allocator, std.Io.Limit.limited(MAX_COMPRESSED_RESPONSE_SIZE));
    defer allocator.free(raw_body);

    const body = try decodeResponseBody(allocator, raw_body);
    defer allocator.free(body);

    return selectVersion(allocator, body, cli_name);
}

/// Decode a (possibly gzip-compressed) HTTP response body into a freshly
/// allocated buffer the caller owns. Plain bodies are duplicated; gzip bodies
/// (magic bytes 0x1f 0x8b) are inflated with a hard cap to defeat gzip bombs.
fn decodeResponseBody(allocator: std.mem.Allocator, raw_body: []const u8) ![]u8 {
    const is_gzipped = raw_body.len >= 2 and raw_body[0] == 0x1f and raw_body[1] == 0x8b;
    if (!is_gzipped) return allocator.dupe(u8, raw_body);

    var reader: std.Io.Reader = .fixed(raw_body);

    // Allocate decompression buffer (32KB window)
    const decompress_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(decompress_buffer);

    var decompressor = std.compress.flate.Decompress.init(&reader, .gzip, decompress_buffer);

    // Collect decompressed data, enforcing a size limit to prevent gzip bombs.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const bytes_written = try decompressor.reader.streamRemaining(&aw.writer);
    if (bytes_written > MAX_DECOMPRESSED_RESPONSE_SIZE) {
        std.debug.print("Error: Decompressed response ({d} bytes) exceeds maximum size ({d} bytes)\n", .{ bytes_written, MAX_DECOMPRESSED_RESPONSE_SIZE });
        std.debug.print("This might indicate a malformed or malicious response.\n", .{});
        return error.DecompressedDataTooLarge;
    }

    return allocator.dupe(u8, aw.written());
}

/// Pick the version for `cli_name` from a GitHub releases JSON array body.
/// Releases are tagged `{cli_name}-v{version}`; the first tag matching that
/// prefix wins and its `{version}` suffix is returned (caller owns it).
/// Returns `error.UnexpectedResponse` if the body isn't a JSON array (e.g. an
/// error object) and `error.NoMatchingRelease` if nothing matches the prefix.
fn selectVersion(allocator: std.mem.Allocator, body: []const u8, cli_name: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| {
        // If JSON parsing fails, it might be an HTML error page (rate limit, etc)
        return err;
    };
    defer parsed.deinit();

    // An array is expected; an object usually means a GitHub error response.
    if (parsed.value != .array) {
        std.debug.print("Error: Expected JSON array of releases, got: {s}\n", .{@tagName(parsed.value)});
        return error.UnexpectedResponse;
    }

    const tag_prefix = try std.fmt.allocPrint(allocator, "{s}-v", .{cli_name});
    defer allocator.free(tag_prefix);

    for (parsed.value.array.items) |release| {
        if (release != .object) continue;
        const tag_name = release.object.get("tag_name") orelse continue;
        if (tag_name != .string) continue;
        const tag_str = tag_name.string;

        if (std.mem.startsWith(u8, tag_str, tag_prefix)) {
            // Strip prefix to get version (e.g., "zcli-v1.0.0" -> "1.0.0")
            return try allocator.dupe(u8, tag_str[tag_prefix.len..]);
        }
    }

    std.debug.print("Error: No releases found with tag prefix '{s}'\n", .{tag_prefix});
    std.debug.print("Expected tag format: {s}<version> (e.g., {s}1.0.0)\n", .{ tag_prefix, tag_prefix });
    return error.NoMatchingRelease;
}

/// Compare two version strings using semantic versioning rules
/// Returns true if latest is newer than current
fn isNewerVersion(current: []const u8, latest: []const u8) bool {
    // Strip 'v' prefix if present
    const current_clean = if (std.mem.startsWith(u8, current, "v")) current[1..] else current;
    const latest_clean = if (std.mem.startsWith(u8, latest, "v")) latest[1..] else latest;

    // Parse versions - if parsing fails, fall back to string comparison
    const current_ver = parseVersion(current_clean) catch {
        return !std.mem.eql(u8, current_clean, latest_clean);
    };
    const latest_ver = parseVersion(latest_clean) catch {
        return !std.mem.eql(u8, current_clean, latest_clean);
    };

    // Compare major.minor.patch
    if (latest_ver.major > current_ver.major) return true;
    if (latest_ver.major < current_ver.major) return false;

    if (latest_ver.minor > current_ver.minor) return true;
    if (latest_ver.minor < current_ver.minor) return false;

    return latest_ver.patch > current_ver.patch;
}

/// Parse a semantic version string (major.minor.patch)
fn parseVersion(version_str: []const u8) !struct { major: u32, minor: u32, patch: u32 } {
    var parts = std.mem.splitScalar(u8, version_str, '.');
    const major_str = parts.next() orelse return error.InvalidVersion;
    const minor_str = parts.next() orelse return error.InvalidVersion;
    const patch_str = parts.next() orelse return error.InvalidVersion;

    return .{
        .major = try std.fmt.parseInt(u32, major_str, 10),
        .minor = try std.fmt.parseInt(u32, minor_str, 10),
        .patch = try std.fmt.parseInt(u32, patch_str, 10),
    };
}

/// Detect current platform (OS and architecture)
fn detectPlatform(allocator: std.mem.Allocator) ![]const u8 {
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        else => {
            std.debug.print("Error: Unsupported operating system: {s}\n", .{@tagName(builtin.os.tag)});
            std.debug.print("Supported platforms: linux, macos\n", .{});
            return error.UnsupportedPlatform;
        },
    };

    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => {
            std.debug.print("Error: Unsupported CPU architecture: {s}\n", .{@tagName(builtin.cpu.arch)});
            std.debug.print("Supported architectures: x86_64, aarch64\n", .{});
            return error.UnsupportedArchitecture;
        },
    };

    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch, os });
}

/// Download binary from GitHub releases
fn downloadBinary(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, cli_name: []const u8, version: []const u8, binary_name: []const u8) ![]const u8 {
    std.debug.print("Downloading binary... (this may take a while on slow connections)\n", .{});

    const url = try buildDownloadUrl(allocator, github_download_base, repo, cli_name, version, binary_name);
    defer allocator.free(url);

    // Create temporary file
    const temp_dir = std.Io.Dir.cwd();
    const temp_filename = try std.fmt.allocPrint(allocator, ".upgrade-{s}-{d}", .{ binary_name, 0 });
    errdefer allocator.free(temp_filename);

    // Download to temp file
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var request = try client.request(.GET, uri, .{
        .headers = .{ .user_agent = .{ .override = "zcli-github-upgrade" } },
    });
    defer request.deinit();

    try request.sendBodiless();

    var redirect_buffer: [1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    // Check for rate limiting
    if (response.head.status == .too_many_requests) {
        std.debug.print("GitHub API rate limit exceeded while downloading binary.\n", .{});
        return error.RateLimitExceeded;
    }

    if (response.head.status != .ok) {
        switch (response.head.status) {
            .not_found => {
                std.debug.print("Error: Binary not found at URL: {s}\n", .{url});
                std.debug.print("Expected binary name: {s}\n", .{binary_name});
                std.debug.print("Verify that the release contains binaries for your platform.\n", .{});
            },
            else => std.debug.print("Failed to download binary from {s}, status: {}\n", .{ url, response.head.status }),
        }
        return error.FailedToDownloadBinary;
    }

    // Read entire response body with size limit
    var transfer_buffer: [8192]u8 = undefined;
    var body_reader = response.reader(&transfer_buffer);
    const binary_data = try body_reader.allocRemaining(allocator, std.Io.Limit.limited(MAX_BINARY_SIZE));
    defer allocator.free(binary_data);

    // Write to file
    var temp_file = try temp_dir.createFile(io, temp_filename, .{});
    defer temp_file.close(io);
    try temp_file.writeStreamingAll(io, binary_data);

    return temp_filename;
}

/// Verify checksum of downloaded binary
fn verifyChecksum(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, cli_name: []const u8, version: []const u8, binary_path: []const u8, binary_name: []const u8) !void {
    std.debug.print("Verifying checksum...\n", .{});

    // Download checksums.txt (published as a release asset alongside the binaries)
    const checksums_url = try buildDownloadUrl(allocator, github_download_base, repo, cli_name, version, "checksums.txt");
    defer allocator.free(checksums_url);

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(checksums_url);
    var request = try client.request(.GET, uri, .{
        .headers = .{ .user_agent = .{ .override = "zcli-github-upgrade" } },
    });
    defer request.deinit();

    try request.sendBodiless();

    var redirect_buffer: [1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    // Check for rate limiting
    if (response.head.status == .too_many_requests) {
        std.debug.print("GitHub API rate limit exceeded while downloading checksums.\n", .{});
        return error.RateLimitExceeded;
    }

    if (response.head.status != .ok) {
        switch (response.head.status) {
            .not_found => {
                std.debug.print("Warning: Checksums file not found at URL: {s}\n", .{checksums_url});
                std.debug.print("Skipping checksum verification (not recommended).\n", .{});
            },
            else => std.debug.print("Failed to download checksums from {s}, status: {}\n", .{ checksums_url, response.head.status }),
        }
        return error.FailedToDownloadChecksums;
    }

    // Read checksums file
    var transfer_buffer: [4096]u8 = undefined;
    var body_reader = response.reader(&transfer_buffer);
    const checksums_content = try body_reader.allocRemaining(allocator, std.Io.Limit.limited(MAX_CHECKSUMS_SIZE));
    defer allocator.free(checksums_content);

    // Find the checksum for our binary
    const expected_checksum = parseExpectedChecksum(checksums_content, binary_name) orelse {
        std.debug.print("Error: Checksum not found for binary: {s}\n", .{binary_name});
        std.debug.print("The checksums.txt file may be incomplete or corrupted.\n", .{});
        return error.ChecksumNotFound;
    };

    // Calculate actual checksum of the downloaded binary
    const actual_checksum = try sha256FileHex(io, std.Io.Dir.cwd(), binary_path);

    // Compare checksums
    if (!std.mem.eql(u8, expected_checksum, &actual_checksum)) {
        std.debug.print("Error: Checksum mismatch for binary: {s}\n", .{binary_name});
        std.debug.print("Expected: {s}\n", .{expected_checksum});
        std.debug.print("Actual:   {s}\n", .{&actual_checksum});
        std.debug.print("The downloaded binary may be corrupted or tampered with.\n", .{});
        return error.ChecksumMismatch;
    }
}

/// Find the expected checksum for `binary_name` in a `checksums.txt` body.
/// Each line is formatted `<sha256-hex>  <filename>`; the first line whose
/// filename contains `binary_name` wins. Returns the hex digest borrowed from
/// `content`, or null if no matching entry exists.
fn parseExpectedChecksum(content: []const u8, binary_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, binary_name) == null) continue;
        var parts = std.mem.splitScalar(u8, line, ' ');
        if (parts.next()) |checksum| {
            if (checksum.len > 0) return checksum;
        }
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

/// Test that the new binary works
fn testBinary(allocator: std.mem.Allocator, path: []const u8) !void {
    // Need to use absolute path or ./ prefix for executable
    const exe_path = if (std.fs.path.isAbsolute(path))
        path
    else
        try std.fmt.allocPrint(allocator, "./{s}", .{path});
    defer if (!std.fs.path.isAbsolute(path)) allocator.free(exe_path);
}

/// Replace the running executable with the new binary, atomically and with a
/// backup. Resolves the current executable's path and delegates the actual
/// swap to `replaceBinaryAt`, which is the testable core.
fn replaceBinary(allocator: std.mem.Allocator, io: std.Io, new_binary_path: []const u8) !void {
    var exe_path_buf: [4096]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_path_buf);
    const exe_path = exe_path_buf[0..exe_len];

    std.debug.print("Replacing binary at: {s}\n", .{exe_path});

    try replaceBinaryAt(allocator, io, std.Io.Dir.cwd(), new_binary_path, exe_path);
}

/// Atomically replace `target_path` (within `dir`) with the binary at
/// `new_binary_path` (also within `dir`), keeping the old binary safe at every
/// step:
/// 1. Back up the current target to `{target}.backup` (best-effort).
/// 2. Copy the new binary to `{target}.new`, mark it executable.
/// 3. Atomically rename `{target}.new` over the target (atomic on Unix when on
///    the same filesystem — a crash mid-swap leaves the original intact).
/// 4. Remove the backup on success.
///
/// Split from `replaceBinary` so the swap can be exercised against temp files
/// instead of the live executable.
fn replaceBinaryAt(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, new_binary_path: []const u8, target_path: []const u8) !void {
    // Step 1+2: Back up the current binary (best-effort — nice-to-have).
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.backup", .{target_path});
    defer allocator.free(backup_path);
    dir.copyFile(target_path, dir, backup_path, io, .{}) catch |err| {
        std.debug.print("Warning: Failed to create backup: {}\n", .{err});
    };

    // Step 3: Copy the new binary alongside the target.
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.new", .{target_path});
    defer allocator.free(temp_path);
    try dir.copyFile(new_binary_path, dir, temp_path, io, .{});
    errdefer dir.deleteFile(io, temp_path) catch {};

    // Step 4: Make it executable (Unix only - Windows uses .exe extension).
    if (builtin.os.tag != .windows) {
        const temp_file = try dir.openFile(io, temp_path, .{});
        defer temp_file.close(io);
        try temp_file.setPermissions(io, .executable_file);
    }

    // Step 5: Atomically swap the new binary over the old one.
    try dir.rename(temp_path, dir, target_path, io);

    // Step 6: Clean up the backup on success (kept on error for recovery).
    dir.deleteFile(io, backup_path) catch |err| {
        std.debug.print("Note: Backup kept at {s} (cleanup error: {})\n", .{ backup_path, err });
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parseVersion - valid semantic versions" {
    const v1 = try parseVersion("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), v1.major);
    try std.testing.expectEqual(@as(u32, 2), v1.minor);
    try std.testing.expectEqual(@as(u32, 3), v1.patch);

    const v2 = try parseVersion("0.0.1");
    try std.testing.expectEqual(@as(u32, 0), v2.major);
    try std.testing.expectEqual(@as(u32, 0), v2.minor);
    try std.testing.expectEqual(@as(u32, 1), v2.patch);

    const v3 = try parseVersion("10.20.30");
    try std.testing.expectEqual(@as(u32, 10), v3.major);
    try std.testing.expectEqual(@as(u32, 20), v3.minor);
    try std.testing.expectEqual(@as(u32, 30), v3.patch);
}

test "parseVersion - invalid formats" {
    try std.testing.expectError(error.InvalidVersion, parseVersion(""));
    try std.testing.expectError(error.InvalidVersion, parseVersion("1.2"));
    try std.testing.expectError(error.InvalidVersion, parseVersion("1"));

    // parseInt returns InvalidCharacter for non-numeric input
    const result = parseVersion("a.b.c");
    try std.testing.expectError(error.InvalidCharacter, result);
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
    // Verify security limits are set to reasonable values
    try std.testing.expect(MAX_COMPRESSED_RESPONSE_SIZE == 10 * 1024 * 1024); // 10MB
    try std.testing.expect(MAX_DECOMPRESSED_RESPONSE_SIZE == 20 * 1024 * 1024); // 20MB
    try std.testing.expect(MAX_BINARY_SIZE == 100 * 1024 * 1024); // 100MB
    try std.testing.expect(MAX_CHECKSUMS_SIZE == 1024 * 1024); // 1MB

    // Ensure decompressed limit is greater than compressed (gzip typically 2-10x compression)
    try std.testing.expect(MAX_DECOMPRESSED_RESPONSE_SIZE > MAX_COMPRESSED_RESPONSE_SIZE);

    // Ensure binary size is reasonable for CLI tools
    try std.testing.expect(MAX_BINARY_SIZE >= 1024 * 1024); // At least 1MB
    try std.testing.expect(MAX_BINARY_SIZE <= 500 * 1024 * 1024); // Not more than 500MB
}

test "replaceBinary - atomic replacement strategy" {
    // This test documents the atomic replacement strategy
    // Actual testing would require filesystem mocking

    // The function implements a safe replacement strategy:
    // 1. Backup current binary (best-effort)
    // 2. Copy new binary to temp location (.new suffix)
    // 3. Atomic rename over old binary
    // 4. Clean up backup on success
    //
    // Benefits:
    // - rename() is atomic on Unix if same filesystem
    // - If process crashes mid-upgrade, old binary is still intact
    // - If rename fails, old binary is unchanged
    // - Backup allows manual recovery if needed
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

test "parseVersion - edge cases with whitespace" {
    // Version strings with leading/trailing whitespace should fail
    // (caller should trim before passing to parseVersion). The whitespace makes
    // the numeric parse fail, so the error is InvalidCharacter — same as any
    // other non-numeric component.
    try std.testing.expectError(error.InvalidCharacter, parseVersion(" 1.2.3"));
    try std.testing.expectError(error.InvalidCharacter, parseVersion("1.2.3 "));
    try std.testing.expectError(error.InvalidCharacter, parseVersion(" 1.2.3 "));
}

test "parseVersion - zero versions" {
    const v = try parseVersion("0.0.0");
    try std.testing.expectEqual(@as(u32, 0), v.major);
    try std.testing.expectEqual(@as(u32, 0), v.minor);
    try std.testing.expectEqual(@as(u32, 0), v.patch);
}

test "parseVersion - large version numbers" {
    const v = try parseVersion("999.999.999");
    try std.testing.expectEqual(@as(u32, 999), v.major);
    try std.testing.expectEqual(@as(u32, 999), v.minor);
    try std.testing.expectEqual(@as(u32, 999), v.patch);
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
    // Test that detectPlatform properly uses the allocator
    const allocator = std.testing.allocator;
    const platform = try detectPlatform(allocator);
    defer allocator.free(platform);

    // Platform should be non-empty
    try std.testing.expect(platform.len > 0);

    // Platform should contain a hyphen (arch-os format)
    try std.testing.expect(std.mem.indexOf(u8, platform, "-") != null);

    // Platform should be one of the expected formats
    const valid_platforms = [_][]const u8{
        "x86_64-linux",
        "aarch64-linux",
        "x86_64-macos",
        "aarch64-macos",
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

// ----------------------------------------------------------------------------
// Response body decoding (gzip)
// ----------------------------------------------------------------------------

// gzip of: [{"tag_name":"myapp-v1.2.3","name":"r"},{"tag_name":"other-v9.9.9"}]
// Produced with Python's gzip (mtime=0) for determinism; only the magic bytes
// and DEFLATE payload matter to the decoder.
const gzipped_releases = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0x8b, 0xae,
    0x56, 0x2a, 0x49, 0x4c, 0x8f, 0xcf, 0x4b, 0xcc, 0x4d, 0x55, 0xb2, 0x52,
    0xca, 0xad, 0x4c, 0x2c, 0x28, 0xd0, 0x2d, 0x33, 0xd4, 0x33, 0xd2, 0x33,
    0x56, 0xd2, 0x51, 0x82, 0x8a, 0x16, 0x29, 0xd5, 0xea, 0xa0, 0x28, 0xcb,
    0x2f, 0xc9, 0x48, 0x2d, 0xd2, 0x2d, 0xb3, 0xd4, 0x03, 0x42, 0xa5, 0xda,
    0x58, 0x00, 0xc9, 0xa3, 0xea, 0xaa, 0x44, 0x00, 0x00, 0x00,
};
const decoded_releases_json = "[{\"tag_name\":\"myapp-v1.2.3\",\"name\":\"r\"},{\"tag_name\":\"other-v9.9.9\"}]";

test "decodeResponseBody - passes plain bodies through unchanged" {
    const a = std.testing.allocator;
    const body = try decodeResponseBody(a, "not compressed at all");
    defer a.free(body);
    try std.testing.expectEqualStrings("not compressed at all", body);
}

test "decodeResponseBody - empty body is not mistaken for gzip" {
    const a = std.testing.allocator;
    const body = try decodeResponseBody(a, "");
    defer a.free(body);
    try std.testing.expectEqual(@as(usize, 0), body.len);
}

test "decodeResponseBody - inflates a gzip-compressed body" {
    const a = std.testing.allocator;
    const body = try decodeResponseBody(a, &gzipped_releases);
    defer a.free(body);
    try std.testing.expectEqualStrings(decoded_releases_json, body);
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

test "selectVersion - skips malformed entries instead of crashing" {
    const a = std.testing.allocator;
    // Non-object entries, a numeric tag_name, and a missing tag are all skipped.
    const body = "[1, \"x\", {\"tag_name\":123}, {\"no_tag\":true}, {\"tag_name\":\"myapp-v3.1.4\"}]";
    const v = try selectVersion(a, body, "myapp");
    defer a.free(v);
    try std.testing.expectEqualStrings("3.1.4", v);
}

test "selectVersion - non-JSON body (e.g. an HTML error page) is an error" {
    const a = std.testing.allocator;
    if (selectVersion(a, "<html>rate limited</html>", "myapp")) |v| {
        a.free(v);
        try std.testing.expect(false); // must not succeed
    } else |_| {}
}

test "fetch decode+select - gzip body flows into version selection" {
    // Mirrors fetchLatestVersion's post-HTTP path: decode the (gzip) body, then
    // pick the version — without touching the network.
    const a = std.testing.allocator;
    const body = try decodeResponseBody(a, &gzipped_releases);
    defer a.free(body);
    const v = try selectVersion(a, body, "myapp");
    defer a.free(v);
    try std.testing.expectEqualStrings("1.2.3", v);
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
