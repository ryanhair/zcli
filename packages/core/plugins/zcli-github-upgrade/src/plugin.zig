const std = @import("std");
const zcli = @import("zcli");

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
            const platform = try detectPlatform();
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
            try testBinary(temp_path);

            // Replace current binary
            try stdout.print("Installing new version...\n", .{});
            try replaceBinary(temp_path);

            try stdout.print("✓ Successfully upgraded to {s}\n", .{latest_version});
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

    if (response.head.status != .ok) {
        // Include status in error for debugging
        return error.FailedToFetchVersion;
    }

    // Read response body
    const body = blk: {
        // First read the raw response
        var transfer_buffer: [4096]u8 = undefined;
        var body_reader = response.reader(&transfer_buffer);
        const raw_body = try body_reader.allocRemaining(allocator, std.Io.Limit.limited(10 * 1024 * 1024)); // 10MB max
        errdefer allocator.free(raw_body);

        // Check if response is gzip compressed by checking magic bytes (0x1f 0x8b)
        const is_gzipped = raw_body.len >= 2 and raw_body[0] == 0x1f and raw_body[1] == 0x8b;
        if (is_gzipped) {
            // Decompress gzip data
            var reader: std.Io.Reader = .fixed(raw_body);

            // Allocate decompression buffer (32KB window)
            const decompress_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
            defer allocator.free(decompress_buffer);

            var decompressor = std.compress.flate.Decompress.init(&reader, .gzip, decompress_buffer);

            // Use allocating writer to collect decompressed data
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();

            _ = try decompressor.reader.streamRemaining(&aw.writer);
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

    return error.NoMatchingRelease;
}

/// Compare two version strings (simple string comparison for now)
fn isNewerVersion(current: []const u8, latest: []const u8) bool {
    // Strip 'v' prefix if present
    const current_clean = if (std.mem.startsWith(u8, current, "v")) current[1..] else current;
    const latest_clean = if (std.mem.startsWith(u8, latest, "v")) latest[1..] else latest;

    return !std.mem.eql(u8, current_clean, latest_clean);
}

/// Detect current platform (OS and architecture)
fn detectPlatform() ![]const u8 {
    const os = switch (@import("builtin").os.tag) {
        .linux => "linux",
        .macos => "macos",
        else => return error.UnsupportedPlatform,
    };

    const arch = switch (@import("builtin").cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedArchitecture,
    };

    return std.fmt.allocPrint(std.heap.page_allocator, "{s}-{s}", .{ arch, os });
}

/// Download binary from GitHub releases
fn downloadBinary(allocator: std.mem.Allocator, repo: []const u8, cli_name: []const u8, version: []const u8, binary_name: []const u8) ![]const u8 {
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

    if (response.head.status != .ok) {
        return error.FailedToDownloadBinary;
    }

    // Read entire response body (binaries are typically under 50MB)
    var transfer_buffer: [8192]u8 = undefined;
    var body_reader = response.reader(&transfer_buffer);
    const binary_data = try body_reader.allocRemaining(allocator, std.Io.Limit.limited(100 * 1024 * 1024)); // 100MB max
    defer allocator.free(binary_data);

    // Write to file
    var temp_file = try temp_dir.createFile(temp_filename, .{});
    defer temp_file.close();
    try temp_file.writeAll(binary_data);

    return temp_filename;
}

/// Verify checksum of downloaded binary
fn verifyChecksum(allocator: std.mem.Allocator, repo: []const u8, cli_name: []const u8, version: []const u8, binary_path: []const u8, binary_name: []const u8) !void {
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

    if (response.head.status != .ok) {
        return error.FailedToDownloadChecksums;
    }

    var transfer_buffer: [4096]u8 = undefined;
    var body_reader = response.reader(&transfer_buffer);
    const checksums_content = try body_reader.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024));
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
        return error.ChecksumMismatch;
    }
}

/// Test that the new binary works
fn testBinary(path: []const u8) !void {
    // Need to use absolute path or ./ prefix for executable
    const exe_path = if (std.fs.path.isAbsolute(path))
        path
    else
        try std.fmt.allocPrint(std.heap.page_allocator, "./{s}", .{path});
    defer if (!std.fs.path.isAbsolute(path)) std.heap.page_allocator.free(exe_path);

    var child = std.process.Child.init(&.{ exe_path, "--version" }, std.heap.page_allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const result = try child.spawnAndWait();
    if (result != .Exited or result.Exited != 0) {
        return error.NewBinaryFailed;
    }
}

/// Replace current binary with new one
fn replaceBinary(new_binary_path: []const u8) !void {
    // Get current executable path
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&exe_path_buf);

    // Make new binary executable
    const new_file = try std.fs.cwd().openFile(new_binary_path, .{});
    defer new_file.close();
    try new_file.chmod(0o755);

    // On Unix, we can replace the running executable
    // Copy new binary over old one
    try std.fs.cwd().copyFile(new_binary_path, std.fs.cwd(), exe_path, .{});
}
