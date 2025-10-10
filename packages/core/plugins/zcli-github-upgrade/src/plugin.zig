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
            const stdout = context.stdout();

            // Check for latest version
            const current_version = context.app_version;
            const latest_version = try fetchLatestVersion(allocator, plugin_config.repo);
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
            const temp_path = try downloadBinary(allocator, plugin_config.repo, latest_version, binary_name);
            defer allocator.free(temp_path);
            defer std.fs.cwd().deleteFile(temp_path) catch {};

            // Verify checksum
            try stdout.print("Verifying checksum...\n", .{});
            try verifyChecksum(allocator, plugin_config.repo, latest_version, temp_path, binary_name);

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
            const latest_version = fetchLatestVersion(allocator, plugin_config.repo) catch |err| {
                // Silently fail - don't interrupt the user's workflow
                _ = err;
                return;
            };
            defer allocator.free(latest_version);

            const current_version = context.app_version;
            if (isNewerVersion(current_version, latest_version)) {
                // Format and show the out-of-date message
                var message = std.ArrayList(u8).init(allocator);
                defer message.deinit();

                var iter = std.mem.splitScalar(u8, plugin_config.out_of_date_message, '{');
                var first = true;
                while (iter.next()) |part| {
                    if (first) {
                        try message.appendSlice(part);
                        first = false;
                        continue;
                    }

                    if (std.mem.startsWith(u8, part, "app}")) {
                        try message.appendSlice(context.app_name);
                        try message.appendSlice(part[4..]);
                    } else if (std.mem.startsWith(u8, part, "current}")) {
                        try message.appendSlice(current_version);
                        try message.appendSlice(part[8..]);
                    } else if (std.mem.startsWith(u8, part, "latest}")) {
                        try message.appendSlice(latest_version);
                        try message.appendSlice(part[7..]);
                    } else {
                        try message.append('{');
                        try message.appendSlice(part);
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

/// Fetch the latest version from GitHub releases API
fn fetchLatestVersion(allocator: std.mem.Allocator, repo: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases/latest", .{repo});
    defer allocator.free(url);

    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var header_buffer: [4096]u8 = undefined;
    var request = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .headers = .{ .user_agent = .{ .override = "zcli-github-upgrade" } },
    });
    defer request.deinit();

    try request.send();
    try request.finish();
    try request.wait();

    if (request.response.status != .ok) {
        return error.FailedToFetchVersion;
    }

    // Read response body
    const body = try request.reader().readAllAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(body);

    // Parse JSON to extract tag_name
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const tag_name = parsed.value.object.get("tag_name") orelse return error.MissingTagName;
    const version_str = tag_name.string;

    // Strip leading 'v' if present
    const version = if (std.mem.startsWith(u8, version_str, "v"))
        version_str[1..]
    else
        version_str;

    return try allocator.dupe(u8, version);
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
fn downloadBinary(allocator: std.mem.Allocator, repo: []const u8, version: []const u8, binary_name: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/v{s}/{s}", .{ repo, version, binary_name });
    defer allocator.free(url);

    // Create temporary file
    const temp_dir = std.fs.cwd();
    const temp_filename = try std.fmt.allocPrint(allocator, ".upgrade-{s}-{d}", .{ binary_name, std.time.timestamp() });
    errdefer allocator.free(temp_filename);

    // Download to temp file
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var header_buffer: [4096]u8 = undefined;
    var request = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .headers = .{ .user_agent = .{ .override = "zcli-github-upgrade" } },
    });
    defer request.deinit();

    try request.send();
    try request.finish();
    try request.wait();

    if (request.response.status != .ok) {
        return error.FailedToDownloadBinary;
    }

    // Write to file
    var temp_file = try temp_dir.createFile(temp_filename, .{});
    defer temp_file.close();

    var buffer: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try request.reader().read(&buffer);
        if (bytes_read == 0) break;
        try temp_file.writeAll(buffer[0..bytes_read]);
    }

    return temp_filename;
}

/// Verify checksum of downloaded binary
fn verifyChecksum(allocator: std.mem.Allocator, repo: []const u8, version: []const u8, binary_path: []const u8, binary_name: []const u8) !void {
    // Download checksums.txt
    const checksums_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/v{s}/checksums.txt", .{ repo, version });
    defer allocator.free(checksums_url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(checksums_url);
    var header_buffer: [4096]u8 = undefined;
    var request = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .headers = .{ .user_agent = .{ .override = "zcli-github-upgrade" } },
    });
    defer request.deinit();

    try request.send();
    try request.finish();
    try request.wait();

    if (request.response.status != .ok) {
        return error.FailedToDownloadChecksums;
    }

    const checksums_content = try request.reader().readAllAlloc(allocator, 1024 * 1024);
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
    var actual_checksum: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&actual_checksum, "{x}", .{std.fmt.fmtSliceHexLower(&hash_bytes)});

    // Compare checksums
    if (!std.mem.eql(u8, expected_checksum.?, &actual_checksum)) {
        return error.ChecksumMismatch;
    }
}

/// Test that the new binary works
fn testBinary(path: []const u8) !void {
    var child = std.process.Child.init(&.{ path, "--version" }, std.heap.page_allocator);
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
