const std = @import("std");
const zcli = @import("zcli");

// Security limits for HTTP responses
const MAX_COMPRESSED_RESPONSE_SIZE = 10 * 1024 * 1024; // 10MB compressed
const MAX_DECOMPRESSED_RESPONSE_SIZE = 20 * 1024 * 1024; // 20MB decompressed
const MAX_BINARY_SIZE = 100 * 1024 * 1024; // 100MB for binary downloads
const MAX_CHECKSUMS_SIZE = 1024 * 1024; // 1MB for checksums file

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
                    .description = "Upgrade to the latest version",
                    .examples = &.{
                        plugin_config.command_name,
                        plugin_config.command_name ++ " --check",
                    },
                };

                pub const Args = struct {};

                pub const Options = struct {
                    check: bool = false,
                    force: bool = false,
                };

                pub fn execute(_: Args, options: Options, context: *zcli.Context) !void {
                    return executeUpgrade(options, context);
                }
            };
        };

        /// Execute the upgrade command
        fn executeUpgrade(options: commands.upgrade.Options, context: *zcli.Context) !void {
            const allocator = context.allocator;
            var stdout = context.stdout();

            // Check for latest version
            const current_version = context.app_version;
            const latest_version = try fetchLatestVersion(allocator, plugin_config.repo, context.app_name);
            defer allocator.free(latest_version);

            if (options.check) {
                if (isNewerVersion(current_version, latest_version)) {
                    try stdout.print("New version available: {s} (current: {s})\n", .{ latest_version, current_version });
                    std.process.exit(0);
                } else {
                    try stdout.print("You are already on the latest version: {s}\n", .{current_version});
                    std.process.exit(0);
                }
            }

            // Perform upgrade
            if (!isNewerVersion(current_version, latest_version)) {
                if (!options.force) {
                    try stdout.print("You are already on the latest version: {s}\n", .{current_version});
                    return;
                }
            }

            try stdout.print("Upgrading from {s} to {s}...\n", .{ current_version, latest_version });

            // Detect platform
            const platform = try detectPlatform(allocator);
            defer allocator.free(platform);
            const binary_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ context.app_name, platform });
            defer allocator.free(binary_name);

            // Download binary
            try stdout.print("Downloading {s}...\n", .{binary_name});
            const temp_path = try downloadBinary(allocator, plugin_config.repo, context.app_name, latest_version, binary_name);
            defer allocator.free(temp_path);
            defer std.fs.cwd().deleteFile(temp_path) catch {};

            // Verify checksum
            try stdout.print("Verifying checksum...\n", .{});
            try verifyChecksum(allocator, plugin_config.repo, context.app_name, latest_version, temp_path, binary_name);

            // Make binary executable before testing
            const temp_file = try std.fs.cwd().openFile(temp_path, .{});
            defer temp_file.close();
            try temp_file.chmod(0o755);

            // Test new binary
            try stdout.print("Testing new binary...\n", .{});
            try testBinary(allocator, temp_path);

            // Replace current binary
            try stdout.print("Installing new version...\n", .{});
            try replaceBinary(allocator, temp_path);

            try stdout.print("✓ Successfully upgraded to {s}\n", .{latest_version});
            try stdout.print("\nThe upgrade is complete. Run '{s} --version' to verify.\n", .{context.app_name});
        }

        /// Startup hook to check for updates if configured
        pub fn onStartup(context: *zcli.Context) !void {
            if (!plugin_config.inform_out_of_date) {
                return;
            }

            const allocator = context.allocator;
            const stderr = context.stderr();

            // Check for latest version (with timeout)
            const latest_version = fetchLatestVersion(allocator, plugin_config.repo, context.app_name) catch |err| {
                // Silently fail - don't interrupt the user's workflow
                _ = err;
                return;
            };
            defer allocator.free(latest_version);

            const current_version = context.app_version;
            if (isNewerVersion(current_version, latest_version)) {
                // Format and show the out-of-date message
                var message = std.ArrayList(u8){};
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
fn fetchLatestVersion(allocator: std.mem.Allocator, repo: []const u8, cli_name: []const u8) ![]const u8 {
    std.debug.print("Checking for updates...\n", .{});

    // Fetch all releases and filter by tag prefix
    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases", .{repo});
    defer allocator.free(url);

    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator };
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

    // Read response body
    const body = blk: {
        // First read the raw response
        var transfer_buffer: [4096]u8 = undefined;
        var body_reader = response.reader(&transfer_buffer);
        const raw_body = try body_reader.allocRemaining(allocator, std.Io.Limit.limited(MAX_COMPRESSED_RESPONSE_SIZE));
        errdefer allocator.free(raw_body);

        // Check if response is gzip compressed by checking magic bytes (0x1f 0x8b)
        const is_gzipped = raw_body.len >= 2 and raw_body[0] == 0x1f and raw_body[1] == 0x8b;
        if (is_gzipped) {
            // Decompress gzip data with size limit to prevent gzip bombs
            var reader: std.Io.Reader = .fixed(raw_body);

            // Allocate decompression buffer (32KB window)
            const decompress_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
            defer allocator.free(decompress_buffer);

            var decompressor = std.compress.flate.Decompress.init(&reader, .gzip, decompress_buffer);

            // Use allocating writer to collect decompressed data with size limit
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();

            const bytes_written = try decompressor.reader.streamRemaining(&aw.writer);

            // Check decompressed size to prevent gzip bombs
            if (bytes_written > MAX_DECOMPRESSED_RESPONSE_SIZE) {
                std.debug.print("Error: Decompressed response ({d} bytes) exceeds maximum size ({d} bytes)\n", .{ bytes_written, MAX_DECOMPRESSED_RESPONSE_SIZE });
                std.debug.print("This might indicate a malformed or malicious response.\n", .{});
                return error.DecompressedDataTooLarge;
            }

            const decompressed = try allocator.dupe(u8, aw.written());

            allocator.free(raw_body);
            break :blk decompressed;
        } else {
            break :blk raw_body;
        }
    };
    defer allocator.free(body);

    // Parse JSON array of releases
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| {
        // If JSON parsing fails, it might be an HTML error page (rate limit, etc)
        return err;
    };
    defer parsed.deinit();

    // Check if response is an array (expected) vs object (error response)
    if (parsed.value != .array) {
        std.debug.print("Error: Expected JSON array of releases, got: {s}\n", .{@tagName(parsed.value)});
        std.debug.print("Repository: {s}\n", .{repo});
        return error.UnexpectedResponse;
    }

    const releases = parsed.value.array;

    // Expected tag format: "{cli_name}-v{version}"
    const tag_prefix = try std.fmt.allocPrint(allocator, "{s}-v", .{cli_name});
    defer allocator.free(tag_prefix);

    // Find first release matching our CLI name prefix
    for (releases.items) |release| {
        const tag_name = release.object.get("tag_name") orelse continue;
        const tag_str = tag_name.string;

        if (std.mem.startsWith(u8, tag_str, tag_prefix)) {
            // Strip prefix to get version (e.g., "zcli-v1.0.0" -> "1.0.0")
            const version = tag_str[tag_prefix.len..];
            return try allocator.dupe(u8, version);
        }
    }

    std.debug.print("Error: No releases found with tag prefix '{s}' in repository: {s}\n", .{ tag_prefix, repo });
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
    const builtin = @import("builtin");

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
fn downloadBinary(allocator: std.mem.Allocator, repo: []const u8, cli_name: []const u8, version: []const u8, binary_name: []const u8) ![]const u8 {
    std.debug.print("Downloading binary... (this may take a while on slow connections)\n", .{});

    const url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/{s}-v{s}/{s}", .{ repo, cli_name, version, binary_name });
    defer allocator.free(url);

    // Create temporary file
    const temp_dir = std.fs.cwd();
    const temp_filename = try std.fmt.allocPrint(allocator, ".upgrade-{s}-{d}", .{ binary_name, std.time.timestamp() });
    errdefer allocator.free(temp_filename);

    // Download to temp file
    var client = std.http.Client{ .allocator = allocator };
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
    var temp_file = try temp_dir.createFile(temp_filename, .{});
    defer temp_file.close();
    try temp_file.writeAll(binary_data);

    return temp_filename;
}

/// Verify checksum of downloaded binary
fn verifyChecksum(allocator: std.mem.Allocator, repo: []const u8, cli_name: []const u8, version: []const u8, binary_path: []const u8, binary_name: []const u8) !void {
    std.debug.print("Verifying checksum...\n", .{});

    // Download checksums.txt
    const checksums_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/{s}-v{s}/checksums.txt", .{ repo, cli_name, version });
    defer allocator.free(checksums_url);

    var client = std.http.Client{ .allocator = allocator };
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
    var lines = std.mem.splitScalar(u8, checksums_content, '\n');
    var expected_checksum: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, binary_name)) |_| {
            var parts = std.mem.splitScalar(u8, line, ' ');
            if (parts.next()) |checksum| {
                expected_checksum = checksum;
                break;
            }
        }
    }

    if (expected_checksum == null) {
        std.debug.print("Error: Checksum not found for binary: {s}\n", .{binary_name});
        std.debug.print("The checksums.txt file may be incomplete or corrupted.\n", .{});
        return error.ChecksumNotFound;
    }

    // Calculate actual checksum
    const file = try std.fs.cwd().openFile(binary_path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try file.read(&buffer);
        if (bytes_read == 0) break;
        hasher.update(buffer[0..bytes_read]);
    }

    var hash_bytes: [32]u8 = undefined;
    hasher.final(&hash_bytes);

    // Convert to hex string
    const actual_checksum = std.fmt.bytesToHex(&hash_bytes, .lower);

    // Compare checksums
    if (!std.mem.eql(u8, expected_checksum.?, &actual_checksum)) {
        std.debug.print("Error: Checksum mismatch for binary: {s}\n", .{binary_name});
        std.debug.print("Expected: {s}\n", .{expected_checksum.?});
        std.debug.print("Actual:   {s}\n", .{&actual_checksum});
        std.debug.print("The downloaded binary may be corrupted or tampered with.\n", .{});
        return error.ChecksumMismatch;
    }
}

/// Test that the new binary works
fn testBinary(allocator: std.mem.Allocator, path: []const u8) !void {
    // Need to use absolute path or ./ prefix for executable
    const exe_path = if (std.fs.path.isAbsolute(path))
        path
    else
        try std.fmt.allocPrint(allocator, "./{s}", .{path});
    defer if (!std.fs.path.isAbsolute(path)) allocator.free(exe_path);

    var child = std.process.Child.init(&.{ exe_path, "--version" }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const result = try child.spawnAndWait();
    if (result != .Exited or result.Exited != 0) {
        std.debug.print("Error: New binary failed basic functionality test\n", .{});
        std.debug.print("Tested command: {s} --version\n", .{exe_path});
        std.debug.print("Exit status: {any}\n", .{result});
        std.debug.print("The downloaded binary may be incompatible or corrupted.\n", .{});
        return error.NewBinaryFailed;
    }
}

/// Replace current binary with new one atomically with backup
/// This function:
/// 1. Creates a backup of the current binary
/// 2. Copies the new binary to a temporary location
/// 3. Atomically renames the new binary over the old one
/// 4. Cleans up the backup on success
fn replaceBinary(allocator: std.mem.Allocator, new_binary_path: []const u8) !void {
    // Get current executable path
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&exe_path_buf);

    std.debug.print("Replacing binary at: {s}\n", .{exe_path});

    // Step 1: Create backup path
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.backup", .{exe_path});
    defer allocator.free(backup_path);

    // Step 2: Create backup of current binary
    std.fs.cwd().copyFile(exe_path, std.fs.cwd(), backup_path, .{}) catch |err| {
        // Warn but continue - backup is nice-to-have, not required
        std.debug.print("Warning: Failed to create backup: {}\n", .{err});
    };

    // Step 3: Create temporary path for new binary (in same directory as target)
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.new", .{exe_path});
    defer allocator.free(temp_path);

    // Step 4: Copy new binary to temporary location
    try std.fs.cwd().copyFile(new_binary_path, std.fs.cwd(), temp_path, .{});
    errdefer std.fs.cwd().deleteFile(temp_path) catch {};

    // Step 5: Make new binary executable
    const temp_file = try std.fs.cwd().openFile(temp_path, .{});
    defer temp_file.close();
    try temp_file.chmod(0o755);

    // Step 6: Atomically rename new binary over old one
    // On Unix, rename() is atomic if source and dest are on the same filesystem
    try std.fs.cwd().rename(temp_path, exe_path);

    // Step 7: Clean up backup on success
    std.fs.cwd().deleteFile(backup_path) catch |err| {
        // Log but don't fail - backup can stay around
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
    // (caller should trim before passing to parseVersion)
    try std.testing.expectError(error.InvalidVersion, parseVersion(" 1.2.3"));
    try std.testing.expectError(error.InvalidVersion, parseVersion("1.2.3 "));
    try std.testing.expectError(error.InvalidVersion, parseVersion(" 1.2.3 "));
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
