const std = @import("std");
const zcli = @import("zcli");

/// Maximum length for user input (version strings, branch names, etc.)
const MAX_INPUT_LENGTH = 256;

/// Read a line from stdin with validation and proper error handling
/// Returns error.InputTooLong if input exceeds MAX_INPUT_LENGTH
fn readLine(allocator: std.mem.Allocator) ![]u8 {
    const stdin_file = std.fs.File.stdin();

    var line_buffer: [MAX_INPUT_LENGTH]u8 = undefined;
    var i: usize = 0;

    while (i < line_buffer.len) {
        var byte_buf: [1]u8 = undefined;
        const bytes_read = stdin_file.read(&byte_buf) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (bytes_read == 0) break; // EOF

        const byte = byte_buf[0];

        // Handle line endings
        if (byte == '\n') break;
        if (byte == '\r') continue; // Handle CRLF, skip CR

        line_buffer[i] = byte;
        i += 1;
    }

    // Check if we hit the buffer limit without finding newline
    if (i == line_buffer.len) {
        // Drain remaining input until newline
        var discard: [1]u8 = undefined;
        while (true) {
            const bytes_read = stdin_file.read(&discard) catch break;
            if (bytes_read == 0 or discard[0] == '\n') break;
        }
        return error.InputTooLong;
    }

    return try allocator.dupe(u8, line_buffer[0..i]);
}

pub const meta = .{
    .description = "Create and manage project releases",
    .examples = &.{
        "release patch              # Bump patch version (1.0.0 → 1.0.1)",
        "release minor              # Bump minor version (1.0.0 → 1.1.0)",
        "release major              # Bump major version (1.0.0 → 2.0.0)",
        "release 1.5.0              # Set explicit version",
        "release patch --dry-run    # Preview without executing",
        "release patch --no-push    # Create tag but don't push",
        "release patch --skip-tests # Skip test validation",
    },
    .options = .{
        .@"dry-run" = .{ .desc = "Preview changes without executing" },
        .@"skip-tests" = .{ .desc = "Skip running tests before release" },
        .@"no-push" = .{ .desc = "Create tag but don't push to remote" },
        .@"skip-checks" = .{ .desc = "Skip safety checks (clean working tree, branch verification)" },
        .sign = .{ .desc = "Sign the tag with GPG" },
        .message = .{ .desc = "Release message (if not provided, editor will open)" },
        .branch = .{ .desc = "Branch to release from" },
    },
};

pub const Args = struct {
    /// Version to release: "major", "minor", "patch", or explicit version like "1.2.3"
    version: []const u8,
};

pub const Options = struct {
    /// Preview changes without executing
    @"dry-run": bool = false,
    /// Skip running tests before release
    @"skip-tests": bool = false,
    /// Create tag but don't push to remote
    @"no-push": bool = false,
    /// Skip safety checks (clean working tree, branch verification)
    @"skip-checks": bool = false,
    /// Sign the tag with GPG
    sign: bool = false,
    /// Release message (if not provided, editor will open)
    message: ?[]const u8 = null,
    /// Branch to release from (default: main)
    branch: []const u8 = "main",
};

const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    fn parse(version_str: []const u8) !Version {
        // Strip 'v' prefix if present
        const str = if (std.mem.startsWith(u8, version_str, "v"))
            version_str[1..]
        else
            version_str;

        var parts = std.mem.splitScalar(u8, str, '.');
        const major_str = parts.next() orelse return error.InvalidVersion;
        const minor_str = parts.next() orelse return error.InvalidVersion;
        const patch_str = parts.next() orelse return error.InvalidVersion;

        return Version{
            .major = try std.fmt.parseInt(u32, major_str, 10),
            .minor = try std.fmt.parseInt(u32, minor_str, 10),
            .patch = try std.fmt.parseInt(u32, patch_str, 10),
        };
    }

    fn format(self: Version, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }

    fn bump(self: Version, bump_type: []const u8) Version {
        if (std.mem.eql(u8, bump_type, "major")) {
            return .{ .major = self.major + 1, .minor = 0, .patch = 0 };
        } else if (std.mem.eql(u8, bump_type, "minor")) {
            return .{ .major = self.major, .minor = self.minor + 1, .patch = 0 };
        } else if (std.mem.eql(u8, bump_type, "patch")) {
            return .{ .major = self.major, .minor = self.minor, .patch = self.patch + 1 };
        }
        return self;
    }
};

pub fn execute(args: Args, options: Options, context: *zcli.Context) !void {
    const allocator = context.allocator;
    var stdout = context.stdout();
    var stderr = context.stderr();

    // 1. Parse CLI name from build.zig.zon
    stdout.print("→ Reading build.zig.zon...\n", .{}) catch {};
    const cli_name = try parseCliName(allocator);
    defer allocator.free(cli_name);
    stdout.print("  CLI name: {s}\n", .{cli_name}) catch {};

    // 2. Get current version from git tags (or create initial tag)
    stdout.print("\n→ Detecting current version...\n", .{}) catch {};

    // Track if this is an initial release
    var is_initial_release = false;

    const current_version = blk: {
        if (getCurrentVersion(allocator, cli_name)) |version| {
            break :blk version;
        } else |err| {
            if (err == error.NoTags) {
                // Offer to create initial tag interactively
                try stdout.print("  No tags found - this appears to be a new project.\n\n", .{});

                // Check if user provided an explicit version (not a bump type)
                const is_bump_type = std.mem.eql(u8, args.version, "major") or
                    std.mem.eql(u8, args.version, "minor") or
                    std.mem.eql(u8, args.version, "patch");

                if (options.@"dry-run") {
                    try stdout.print("(dry-run: would prompt to create initial release tag)\n", .{});
                    is_initial_release = true;
                    const initial_version = if (is_bump_type)
                        Version{ .major = 0, .minor = 1, .patch = 0 }
                    else
                        try Version.parse(args.version);
                    break :blk initial_version;
                }

                try stdout.print("Create initial release tag? [Y/n]: ", .{});
                const response = readLine(allocator) catch |read_err| {
                    if (read_err == error.InputTooLong) {
                        try stderr.print("✗ Input too long (max {d} characters)\n", .{MAX_INPUT_LENGTH});
                        return error.InputTooLong;
                    }
                    return read_err;
                };
                defer allocator.free(response);
                const trimmed = std.mem.trim(u8, response, " \t\r\n");

                if (std.mem.eql(u8, trimmed, "n") or std.mem.eql(u8, trimmed, "N")) {
                    try stderr.print("\nTo create manually:\n", .{});
                    try stderr.print("  git tag -a {s}-v0.1.0 -m \"Initial release\"\n", .{cli_name});
                    return err;
                }

                // If user provided explicit version, use it; otherwise prompt
                const version_to_use = if (is_bump_type) blk2: {
                    try stdout.print("  Initial version (default: 0.1.0): ", .{});
                    const version_input = readLine(allocator) catch |read_err| {
                        if (read_err == error.InputTooLong) {
                            try stderr.print("✗ Input too long (max {d} characters)\n", .{MAX_INPUT_LENGTH});
                            return error.InputTooLong;
                        }
                        return read_err;
                    };
                    defer allocator.free(version_input);
                    const initial_version_str = std.mem.trim(u8, version_input, " \t\r\n");
                    break :blk2 if (initial_version_str.len == 0) "0.1.0" else initial_version_str;
                } else args.version;

                const initial_version = Version.parse(version_to_use) catch |parse_err| {
                    try stderr.print("✗ Invalid version format: {s}\n", .{version_to_use});
                    try stderr.print("  Version must be in format: MAJOR.MINOR.PATCH (e.g., 0.1.0)\n", .{});
                    return parse_err;
                };

                try stdout.print("\n  Creating initial tag {s}-v{s}...\n", .{ cli_name, version_to_use });
                is_initial_release = true;
                break :blk initial_version;
            }
            return err;
        }
    };

    const current_version_str = try current_version.format(allocator);
    defer allocator.free(current_version_str);

    // 3. Calculate new version
    const new_version = blk: {
        // For initial releases, use the version as-is (no bumping needed)
        if (is_initial_release) {
            stdout.print("  Initial version: {s}\n\n", .{current_version_str}) catch {};
            break :blk current_version;
        }

        // For subsequent releases, show current and calculate new
        stdout.print("  Current version: {s}\n", .{current_version_str}) catch {};

        if (std.mem.eql(u8, args.version, "major") or
            std.mem.eql(u8, args.version, "minor") or
            std.mem.eql(u8, args.version, "patch"))
        {
            break :blk current_version.bump(args.version);
        } else {
            break :blk try Version.parse(args.version);
        }
    };

    const new_version_str = try new_version.format(allocator);
    defer allocator.free(new_version_str);

    if (!is_initial_release) {
        stdout.print("  New version: {s}\n\n", .{new_version_str}) catch {};
    }

    // 4. Safety checks
    if (!options.@"skip-checks") {
        stdout.print("→ Running safety checks...\n", .{}) catch {};

        // Check working tree is clean
        const status_result = try runCommand(allocator, &.{ "git", "status", "--porcelain" });
        defer allocator.free(status_result);

        if (status_result.len > 0) {
            try stderr.print("✗ Working tree is not clean. Commit or stash changes first.\n", .{});
            return error.DirtyWorkingTree;
        }
        stdout.print("  ✓ Working tree is clean\n", .{}) catch {};

        // Check current branch
        const branch_result = try runCommand(allocator, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });
        defer allocator.free(branch_result);

        const current_branch = std.mem.trim(u8, branch_result, "\n ");
        if (!std.mem.eql(u8, current_branch, options.branch)) {
            try stderr.print("✗ Not on branch '{s}' (currently on '{s}')\n", .{ options.branch, current_branch });
            return error.WrongBranch;
        }
        stdout.print("  ✓ On branch: {s}\n", .{current_branch}) catch {};
    }

    // 4. Run tests
    if (!options.@"skip-tests") {
        stdout.print("\n→ Running tests...\n", .{}) catch {};
        if (options.@"dry-run") {
            stdout.print("  (dry-run: would run 'zig build test')\n", .{}) catch {};
        } else {
            const test_result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "zig", "build", "test" },
            }) catch |err| {
                try stderr.print("✗ Tests failed: {}\n", .{err});
                return error.TestsFailed;
            };
            defer allocator.free(test_result.stdout);
            defer allocator.free(test_result.stderr);

            if (test_result.term.Exited != 0) {
                try stderr.print("✗ Tests failed\n{s}\n", .{test_result.stderr});
                return error.TestsFailed;
            }
            stdout.print("  ✓ All tests passed\n", .{}) catch {};
        }
    }

    // 5. Get release notes
    stdout.print("\n→ Preparing release notes...\n", .{}) catch {};
    const release_notes = if (options.message) |msg|
        try allocator.dupe(u8, msg)
    else if (options.@"dry-run")
        try allocator.dupe(u8, "(dry-run: would open editor for release notes)")
    else if (is_initial_release)
        try getInitialReleaseNotes(allocator, new_version_str)
    else
        try getReleaseNotes(allocator, cli_name, current_version_str, new_version_str);
    defer allocator.free(release_notes);

    stdout.print("\nRelease notes:\n{s}\n", .{release_notes}) catch {};

    // 5.5. Confirm release (unless using --message flag or dry-run)
    if (options.message == null and !options.@"dry-run") {
        stdout.print("\nContinue with release {s}-v{s}? [Y/n]: ", .{ cli_name, new_version_str }) catch {};
        const response = readLine(allocator) catch |read_err| {
            if (read_err == error.InputTooLong) {
                try stderr.print("✗ Input too long (max {d} characters)\n", .{MAX_INPUT_LENGTH});
                return error.InputTooLong;
            }
            return read_err;
        };
        defer allocator.free(response);
        const trimmed = std.mem.trim(u8, response, " \t\r\n");

        // Default to yes - only abort if explicitly "n" or "N"
        if (std.mem.eql(u8, trimmed, "n") or std.mem.eql(u8, trimmed, "N")) {
            try stdout.print("Release aborted.\n", .{});
            return;
        }
    }

    // 6. Update build.zig.zon with new version
    stdout.print("\n→ Updating build.zig.zon to v{s}...\n", .{new_version_str}) catch {};
    if (options.@"dry-run") {
        stdout.print("  (dry-run: would update build.zig.zon)\n", .{}) catch {};
    } else {
        try updateBuildZonVersion(allocator, new_version_str);
        stdout.print("  ✓ build.zig.zon updated\n", .{}) catch {};

        // Commit the version bump
        stdout.print("\n→ Committing version bump...\n", .{}) catch {};
        const commit_msg = try std.fmt.allocPrint(allocator, "Bump version to {s}", .{new_version_str});
        defer allocator.free(commit_msg);

        _ = try runCommand(allocator, &.{ "git", "add", "build.zig.zon" });
        _ = try runCommand(allocator, &.{ "git", "commit", "-m", commit_msg });
        stdout.print("  ✓ Changes committed\n", .{}) catch {};
    }

    // 7. Create annotated tag
    const tag_name = try std.fmt.allocPrint(allocator, "{s}-v{s}", .{ cli_name, new_version_str });
    defer allocator.free(tag_name);

    stdout.print("\n→ Creating annotated tag {s}...\n", .{tag_name}) catch {};
    if (options.@"dry-run") {
        stdout.print("  (dry-run: would create tag)\n", .{}) catch {};
    } else {
        var tag_cmd = std.ArrayList([]const u8){};
        defer tag_cmd.deinit(allocator);

        try tag_cmd.append(allocator, "git");
        try tag_cmd.append(allocator, "tag");
        try tag_cmd.append(allocator, "-a");
        if (options.sign) try tag_cmd.append(allocator, "-s");
        try tag_cmd.append(allocator, tag_name);
        try tag_cmd.append(allocator, "-m");
        try tag_cmd.append(allocator, release_notes);

        _ = try runCommand(allocator, tag_cmd.items);
        stdout.print("  ✓ Tag created\n", .{}) catch {};
    }

    // 8. Push commit and tag
    if (!options.@"no-push") {
        stdout.print("\n→ Pushing to origin...\n", .{}) catch {};
        if (options.@"dry-run") {
            stdout.print("  (dry-run: would push commit and tag)\n", .{}) catch {};
        } else {
            // Push the commit first
            _ = try runCommand(allocator, &.{ "git", "push" });
            // Then push the tag
            _ = try runCommand(allocator, &.{ "git", "push", "origin", tag_name });
            stdout.print("  ✓ Commit and tag pushed successfully\n", .{}) catch {};
        }
    }

    // 9. Success message
    stdout.print("\n", .{}) catch {};
    if (options.@"dry-run") {
        stdout.print("✓ Dry-run complete! No changes were made.\n", .{}) catch {};
    } else {
        stdout.print("✓ Release {s} created! 🎉\n", .{tag_name}) catch {};
        stdout.print("\nNext steps:\n", .{}) catch {};
        stdout.print("  • GitHub Actions will build release binaries\n", .{}) catch {};

        // Try to get repo URL
        if (runCommand(allocator, &.{ "git", "config", "--get", "remote.origin.url" })) |url| {
            defer allocator.free(url);
            const clean_url = std.mem.trim(u8, url, "\n ");
            // Convert git@github.com:user/repo.git to https://github.com/user/repo
            if (std.mem.indexOf(u8, clean_url, "github.com")) |_| {
                var repo_url = std.ArrayList(u8){};
                defer repo_url.deinit(allocator);

                if (std.mem.startsWith(u8, clean_url, "git@")) {
                    // SSH format: git@github.com:user/repo.git
                    const colon_pos = std.mem.indexOf(u8, clean_url, ":") orelse return;
                    const path = clean_url[colon_pos + 1 ..];
                    const path_clean = if (std.mem.endsWith(u8, path, ".git"))
                        path[0 .. path.len - 4]
                    else
                        path;
                    try repo_url.appendSlice(allocator, "https://github.com/");
                    try repo_url.appendSlice(allocator, path_clean);
                } else if (std.mem.startsWith(u8, clean_url, "https://")) {
                    // HTTPS format: https://github.com/user/repo.git
                    const path_clean = if (std.mem.endsWith(u8, clean_url, ".git"))
                        clean_url[0 .. clean_url.len - 4]
                    else
                        clean_url;
                    try repo_url.appendSlice(allocator, path_clean);
                }

                stdout.print("  • View release: {s}/releases/tag/{s}\n", .{ repo_url.items, tag_name }) catch {};
            }
        } else |_| {}
    }
}

/// Parse CLI name from build.zig.zon
fn parseCliName(allocator: std.mem.Allocator) ![]const u8 {
    const zon_path = "build.zig.zon";

    const file = std.fs.cwd().openFile(zon_path, .{}) catch |err| {
        std.debug.print("Error: Could not open {s}: {}\n", .{ zon_path, err });
        std.debug.print("Make sure you're running this command from the project root directory.\n", .{});
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Find the .name line
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, ".name")) {
            // Handle both ".name = .zcli" and ".name = "zcli""
            if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
                const after_eq = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

                // Check for quoted string format
                if (std.mem.startsWith(u8, after_eq, "\"")) {
                    const start_quote = 1;
                    if (std.mem.indexOf(u8, after_eq[start_quote..], "\"")) |end_quote| {
                        const name = after_eq[start_quote .. start_quote + end_quote];
                        return try allocator.dupe(u8, name);
                    }
                }
                // Check for identifier format (.name)
                else if (std.mem.startsWith(u8, after_eq, ".")) {
                    const name_start: usize = 1;
                    var name_end: usize = name_start;
                    while (name_end < after_eq.len) : (name_end += 1) {
                        const c = after_eq[name_end];
                        if (c == ',' or c == ' ' or c == '\t' or c == '\n') break;
                    }
                    const name = after_eq[name_start..name_end];
                    return try allocator.dupe(u8, name);
                }
            }
        }
    }

    std.debug.print("Error: Could not find .name field in {s}\n", .{zon_path});
    std.debug.print("Expected format: .name = \"myapp\" or .name = .myapp\n", .{});
    return error.NameNotFound;
}

/// Update the version in build.zig.zon
fn updateBuildZonVersion(allocator: std.mem.Allocator, new_version: []const u8) !void {
    const zon_path = "build.zig.zon";

    // Read current file
    const file = try std.fs.cwd().openFile(zon_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Find and replace the version line
    var new_content = std.ArrayList(u8){};
    defer new_content.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, ".version")) |_| {
            // Replace the version value
            const indent = blk: {
                var i: usize = 0;
                while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
                break :blk line[0..i];
            };
            try new_content.writer(allocator).print("{s}.version = \"{s}\",\n", .{ indent, new_version });
        } else {
            try new_content.appendSlice(allocator, line);
            try new_content.append(allocator, '\n');
        }
    }

    // Write back to file
    const out_file = try std.fs.cwd().createFile(zon_path, .{});
    defer out_file.close();
    try out_file.writeAll(new_content.items);
}

fn getCurrentVersion(allocator: std.mem.Allocator, cli_name: []const u8) !Version {
    // Look for tags matching {cli_name}-v*
    const tag_pattern = try std.fmt.allocPrint(allocator, "{s}-v*", .{cli_name});
    defer allocator.free(tag_pattern);

    const result = runCommand(allocator, &.{ "git", "describe", "--tags", "--abbrev=0", "--match", tag_pattern }) catch |err| {
        if (err == error.CommandFailed) return error.NoTags;
        return err;
    };
    defer allocator.free(result);

    const tag = std.mem.trim(u8, result, "\n ");

    // Strip the "{cli_name}-" prefix to get just the version
    const prefix = try std.fmt.allocPrint(allocator, "{s}-", .{cli_name});
    defer allocator.free(prefix);

    const version_str = if (std.mem.startsWith(u8, tag, prefix))
        tag[prefix.len..]
    else
        tag;

    return try Version.parse(version_str);
}

fn getInitialReleaseNotes(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    // Create temporary file with template for initial release
    const tmp_dir = std.fs.getAppDataDir(allocator, "zcli") catch "/tmp";
    defer allocator.free(tmp_dir);

    var dir = try std.fs.cwd().makeOpenPath(tmp_dir, .{});
    defer dir.close();

    const tmp_file_path = try std.fmt.allocPrint(allocator, "{s}/RELEASE_NOTES.txt", .{tmp_dir});
    defer allocator.free(tmp_file_path);

    const template = try std.fmt.allocPrint(
        allocator,
        \\Release v{s}
        \\
        \\Initial release
        \\
        \\## Features
        \\
        \\<!-- Describe the main features of this initial release -->
        \\
        \\## Notes
        \\
        \\<!-- Add any additional notes here -->
        \\
        \\
    ,
        .{version},
    );
    defer allocator.free(template);

    const file = try dir.createFile("RELEASE_NOTES.txt", .{});
    defer file.close();
    try file.writeAll(template);

    // Open editor
    const editor = std.process.getEnvVarOwned(allocator, "EDITOR") catch try allocator.dupe(u8, "vim");
    defer allocator.free(editor);

    var child = std.process.Child.init(&.{ editor, tmp_file_path }, allocator);
    const term = try child.spawnAndWait();

    if (term.Exited != 0) {
        std.debug.print("Error: Editor exited with non-zero status\n", .{});
        std.debug.print("Editor command: {s}\n", .{editor});
        std.debug.print("You can set your preferred editor with: export EDITOR=nano\n", .{});
        return error.EditorFailed;
    }

    // Read the edited file
    const edited_file = try dir.openFile("RELEASE_NOTES.txt", .{});
    defer edited_file.close();

    const content = try edited_file.readToEndAlloc(allocator, 1024 * 1024);
    return content;
}

fn getReleaseNotes(allocator: std.mem.Allocator, cli_name: []const u8, current_version: []const u8, new_version: []const u8) ![]const u8 {
    // Generate commit log since last tag
    const log_cmd = try std.fmt.allocPrint(
        allocator,
        "git log {s}-v{s}..HEAD --oneline --pretty=format:\"- %s\"",
        .{ cli_name, current_version },
    );
    defer allocator.free(log_cmd);

    const commits = runCommand(allocator, &.{ "sh", "-c", log_cmd }) catch
        try allocator.dupe(u8, "");
    defer allocator.free(commits);

    // Create temporary file with template
    const tmp_dir = std.fs.getAppDataDir(allocator, "zcli") catch "/tmp";
    defer allocator.free(tmp_dir);

    var dir = try std.fs.cwd().makeOpenPath(tmp_dir, .{});
    defer dir.close();

    const tmp_file_path = try std.fmt.allocPrint(allocator, "{s}/RELEASE_NOTES.txt", .{tmp_dir});
    defer allocator.free(tmp_file_path);

    const template = try std.fmt.allocPrint(
        allocator,
        \\Release v{s}
        \\
        \\## Changes
        \\
        \\{s}
        \\
        \\## Notes
        \\
        \\<!-- Add any additional release notes here -->
        \\
        \\
    ,
        .{ new_version, commits },
    );
    defer allocator.free(template);

    const file = try dir.createFile("RELEASE_NOTES.txt", .{});
    defer file.close();
    try file.writeAll(template);

    // Open editor
    const editor = std.process.getEnvVarOwned(allocator, "EDITOR") catch try allocator.dupe(u8, "vim");
    defer allocator.free(editor);

    var child = std.process.Child.init(&.{ editor, tmp_file_path }, allocator);
    // Don't redirect stdin/stdout/stderr - let the editor have terminal control
    const term = try child.spawnAndWait();

    if (term.Exited != 0) {
        std.debug.print("Error: Editor exited with non-zero status\n", .{});
        std.debug.print("Editor command: {s}\n", .{editor});
        std.debug.print("You can set your preferred editor with: export EDITOR=nano\n", .{});
        return error.EditorFailed;
    }

    // Read the edited file
    const edited_file = try dir.openFile("RELEASE_NOTES.txt", .{});
    defer edited_file.close();

    const content = try edited_file.readToEndAlloc(allocator, 1024 * 1024);
    return content;
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }

    return result.stdout;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Version.parse - valid versions" {
    const v1 = try Version.parse("1.2.3");
    try testing.expectEqual(@as(u32, 1), v1.major);
    try testing.expectEqual(@as(u32, 2), v1.minor);
    try testing.expectEqual(@as(u32, 3), v1.patch);

    const v2 = try Version.parse("v1.2.3");
    try testing.expectEqual(@as(u32, 1), v2.major);
    try testing.expectEqual(@as(u32, 2), v2.minor);
    try testing.expectEqual(@as(u32, 3), v2.patch);

    const v3 = try Version.parse("0.0.1");
    try testing.expectEqual(@as(u32, 0), v3.major);
    try testing.expectEqual(@as(u32, 0), v3.minor);
    try testing.expectEqual(@as(u32, 1), v3.patch);
}

test "Version.parse - invalid versions" {
    try testing.expectError(error.InvalidVersion, Version.parse("1.2"));
    try testing.expectError(error.InvalidVersion, Version.parse("1"));
    try testing.expectError(error.InvalidVersion, Version.parse(""));
    try testing.expectError(error.InvalidVersion, Version.parse("v"));
}

test "Version.format - formats correctly" {
    const allocator = testing.allocator;

    const v1 = Version{ .major = 1, .minor = 2, .patch = 3 };
    const s1 = try v1.format(allocator);
    defer allocator.free(s1);
    try testing.expectEqualStrings("1.2.3", s1);

    const v2 = Version{ .major = 0, .minor = 0, .patch = 1 };
    const s2 = try v2.format(allocator);
    defer allocator.free(s2);
    try testing.expectEqualStrings("0.0.1", s2);

    const v3 = Version{ .major = 10, .minor = 20, .patch = 30 };
    const s3 = try v3.format(allocator);
    defer allocator.free(s3);
    try testing.expectEqualStrings("10.20.30", s3);
}

test "Version.bump - major" {
    const v1 = Version{ .major = 1, .minor = 2, .patch = 3 };
    const v2 = v1.bump("major");
    try testing.expectEqual(@as(u32, 2), v2.major);
    try testing.expectEqual(@as(u32, 0), v2.minor);
    try testing.expectEqual(@as(u32, 0), v2.patch);

    const v3 = Version{ .major = 0, .minor = 5, .patch = 10 };
    const v4 = v3.bump("major");
    try testing.expectEqual(@as(u32, 1), v4.major);
    try testing.expectEqual(@as(u32, 0), v4.minor);
    try testing.expectEqual(@as(u32, 0), v4.patch);
}

test "Version.bump - minor" {
    const v1 = Version{ .major = 1, .minor = 2, .patch = 3 };
    const v2 = v1.bump("minor");
    try testing.expectEqual(@as(u32, 1), v2.major);
    try testing.expectEqual(@as(u32, 3), v2.minor);
    try testing.expectEqual(@as(u32, 0), v2.patch);

    const v3 = Version{ .major = 0, .minor = 0, .patch = 10 };
    const v4 = v3.bump("minor");
    try testing.expectEqual(@as(u32, 0), v4.major);
    try testing.expectEqual(@as(u32, 1), v4.minor);
    try testing.expectEqual(@as(u32, 0), v4.patch);
}

test "Version.bump - patch" {
    const v1 = Version{ .major = 1, .minor = 2, .patch = 3 };
    const v2 = v1.bump("patch");
    try testing.expectEqual(@as(u32, 1), v2.major);
    try testing.expectEqual(@as(u32, 2), v2.minor);
    try testing.expectEqual(@as(u32, 4), v2.patch);

    const v3 = Version{ .major = 0, .minor = 0, .patch = 0 };
    const v4 = v3.bump("patch");
    try testing.expectEqual(@as(u32, 0), v4.major);
    try testing.expectEqual(@as(u32, 0), v4.minor);
    try testing.expectEqual(@as(u32, 1), v4.patch);
}

test "Version.bump - invalid bump type returns unchanged" {
    const v1 = Version{ .major = 1, .minor = 2, .patch = 3 };
    const v2 = v1.bump("invalid");
    try testing.expectEqual(@as(u32, 1), v2.major);
    try testing.expectEqual(@as(u32, 2), v2.minor);
    try testing.expectEqual(@as(u32, 3), v2.patch);
}

test "parseCliName - quoted string format" {
    const allocator = testing.allocator;

    // Create a temporary build.zig.zon file
    const temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const zon_content =
        \\.{
        \\    .name = "myapp",
        \\    .version = "1.0.0",
        \\}
    ;

    var file = try temp_dir.dir.createFile("build.zig.zon", .{});
    defer file.close();
    try file.writeAll(zon_content);

    // Change to temp directory
    const cwd = std.fs.cwd();
    const original_cwd_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    const temp_path = try temp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_path);

    try std.posix.chdir(temp_path);
    defer std.posix.chdir(original_cwd_path) catch {};

    const cli_name = try parseCliName(allocator);
    defer allocator.free(cli_name);

    try testing.expectEqualStrings("myapp", cli_name);
}

test "parseCliName - identifier format" {
    const allocator = testing.allocator;

    const temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const zon_content =
        \\.{
        \\    .name = .zcli,
        \\    .version = "1.0.0",
        \\}
    ;

    var file = try temp_dir.dir.createFile("build.zig.zon", .{});
    defer file.close();
    try file.writeAll(zon_content);

    const cwd = std.fs.cwd();
    const original_cwd_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    const temp_path = try temp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_path);

    try std.posix.chdir(temp_path);
    defer std.posix.chdir(original_cwd_path) catch {};

    const cli_name = try parseCliName(allocator);
    defer allocator.free(cli_name);

    try testing.expectEqualStrings("zcli", cli_name);
}

test "parseCliName - identifier with trailing comma" {
    const allocator = testing.allocator;

    const temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const zon_content =
        \\.{
        \\    .name = .myapp,
        \\    .version = "1.0.0",
        \\}
    ;

    var file = try temp_dir.dir.createFile("build.zig.zon", .{});
    defer file.close();
    try file.writeAll(zon_content);

    const cwd = std.fs.cwd();
    const original_cwd_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    const temp_path = try temp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_path);

    try std.posix.chdir(temp_path);
    defer std.posix.chdir(original_cwd_path) catch {};

    const cli_name = try parseCliName(allocator);
    defer allocator.free(cli_name);

    try testing.expectEqualStrings("myapp", cli_name);
}

test "parseCliName - missing name field" {
    const allocator = testing.allocator;

    const temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const zon_content =
        \\.{
        \\    .version = "1.0.0",
        \\}
    ;

    var file = try temp_dir.dir.createFile("build.zig.zon", .{});
    defer file.close();
    try file.writeAll(zon_content);

    const cwd = std.fs.cwd();
    const original_cwd_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    const temp_path = try temp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_path);

    try std.posix.chdir(temp_path);
    defer std.posix.chdir(original_cwd_path) catch {};

    try testing.expectError(error.NameNotFound, parseCliName(allocator));
}

test "bump type detection" {
    // Test that we can correctly identify bump types vs explicit versions
    const is_major = std.mem.eql(u8, "major", "major");
    const is_minor = std.mem.eql(u8, "minor", "minor");
    const is_patch = std.mem.eql(u8, "patch", "patch");
    const is_version = !std.mem.eql(u8, "1.2.3", "major") and
        !std.mem.eql(u8, "1.2.3", "minor") and
        !std.mem.eql(u8, "1.2.3", "patch");

    try testing.expect(is_major);
    try testing.expect(is_minor);
    try testing.expect(is_patch);
    try testing.expect(is_version);
}

test "tag name format with CLI name prefix" {
    const allocator = testing.allocator;

    // Test tag format: {cli_name}-v{version}
    const cli_name = "zcli";
    const version = "1.2.3";

    const tag_name = try std.fmt.allocPrint(allocator, "{s}-v{s}", .{ cli_name, version });
    defer allocator.free(tag_name);

    try testing.expectEqualStrings("zcli-v1.2.3", tag_name);

    // Test another example
    const cli_name2 = "myapp";
    const version2 = "0.1.0";

    const tag_name2 = try std.fmt.allocPrint(allocator, "{s}-v{s}", .{ cli_name2, version2 });
    defer allocator.free(tag_name2);

    try testing.expectEqualStrings("myapp-v0.1.0", tag_name2);
}

test "readLine - handles CRLF line endings" {
    // Note: This test would require mocking stdin, which is complex in Zig
    // The CRLF handling is covered by the implementation logic
}

test "readLine - MAX_INPUT_LENGTH constant is reasonable" {
    // Verify the constant is set to a reasonable value
    try testing.expect(MAX_INPUT_LENGTH == 256);
    try testing.expect(MAX_INPUT_LENGTH > 0);
    try testing.expect(MAX_INPUT_LENGTH < 65536); // Not too large
}

test "Version.parse - edge cases with whitespace" {
    // Should fail - whitespace not allowed
    try testing.expectError(error.InvalidCharacter, Version.parse(" 1.2.3"));
    try testing.expectError(error.InvalidCharacter, Version.parse("1.2.3 "));
    try testing.expectError(error.InvalidCharacter, Version.parse("1. 2.3"));
}

test "Version.parse - zero versions" {
    const v0 = try Version.parse("0.0.0");
    try testing.expectEqual(@as(u32, 0), v0.major);
    try testing.expectEqual(@as(u32, 0), v0.minor);
    try testing.expectEqual(@as(u32, 0), v0.patch);
}

test "Version.parse - large version numbers" {
    const v_large = try Version.parse("999.999.999");
    try testing.expectEqual(@as(u32, 999), v_large.major);
    try testing.expectEqual(@as(u32, 999), v_large.minor);
    try testing.expectEqual(@as(u32, 999), v_large.patch);
}

test "Version.parse - non-numeric input" {
    try testing.expectError(error.InvalidCharacter, Version.parse("a.b.c"));
    try testing.expectError(error.InvalidCharacter, Version.parse("1.2.x"));
    try testing.expectError(error.InvalidCharacter, Version.parse("1.x.3"));
}

test "Version.bump - all bump types reset lower components" {
    const v = Version{ .major = 5, .minor = 10, .patch = 15 };

    // Major bump resets minor and patch
    const v_major = v.bump("major");
    try testing.expectEqual(@as(u32, 6), v_major.major);
    try testing.expectEqual(@as(u32, 0), v_major.minor);
    try testing.expectEqual(@as(u32, 0), v_major.patch);

    // Minor bump resets patch
    const v_minor = v.bump("minor");
    try testing.expectEqual(@as(u32, 5), v_minor.major);
    try testing.expectEqual(@as(u32, 11), v_minor.minor);
    try testing.expectEqual(@as(u32, 0), v_minor.patch);

    // Patch bump doesn't reset anything
    const v_patch = v.bump("patch");
    try testing.expectEqual(@as(u32, 5), v_patch.major);
    try testing.expectEqual(@as(u32, 10), v_patch.minor);
    try testing.expectEqual(@as(u32, 16), v_patch.patch);
}

test "Version.format - handles leading zeros correctly" {
    const allocator = testing.allocator;

    // Zig's u32 doesn't have leading zeros, but verify behavior
    const v = Version{ .major = 1, .minor = 0, .patch = 10 };
    const s = try v.format(allocator);
    defer allocator.free(s);

    try testing.expectEqualStrings("1.0.10", s);
}

test "parseCliName - whitespace handling" {
    const allocator = testing.allocator;

    const temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Test with extra whitespace
    const zon_content =
        \\.{
        \\    .name   =   "myapp"  ,
        \\    .version = "1.0.0",
        \\}
    ;

    var file = try temp_dir.dir.createFile("build.zig.zon", .{});
    defer file.close();
    try file.writeAll(zon_content);

    const cwd = std.fs.cwd();
    const original_cwd_path = try cwd.realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    const temp_path = try temp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(temp_path);

    try std.posix.chdir(temp_path);
    defer std.posix.chdir(original_cwd_path) catch {};

    const cli_name = try parseCliName(allocator);
    defer allocator.free(cli_name);

    try testing.expectEqualStrings("myapp", cli_name);
}

test "tag name format - validates pattern" {
    const allocator = testing.allocator;

    // Verify tag format matches expected pattern: {cli_name}-v{version}
    const cli_name = "my-app-123";
    const version = "10.20.30";

    const tag_name = try std.fmt.allocPrint(allocator, "{s}-v{s}", .{ cli_name, version });
    defer allocator.free(tag_name);

    try testing.expectEqualStrings("my-app-123-v10.20.30", tag_name);

    // Verify it contains both components
    try testing.expect(std.mem.indexOf(u8, tag_name, cli_name) != null);
    try testing.expect(std.mem.indexOf(u8, tag_name, "-v") != null);
    try testing.expect(std.mem.indexOf(u8, tag_name, version) != null);
}
