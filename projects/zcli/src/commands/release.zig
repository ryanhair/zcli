const std = @import("std");
const zcli = @import("zcli");

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
    const stdout = context.stdout();
    const stderr = context.stderr();

    // 1. Get current version from git tags
    stdout.print("→ Detecting current version...\n", .{}) catch {};
    const current_version = getCurrentVersion(allocator) catch |err| {
        if (err == error.NoTags) {
            try stderr.print("✗ No tags found. Cannot determine current version.\n", .{});
            try stderr.print("  Create an initial tag first: git tag -a v0.1.0 -m \"Initial release\"\n", .{});
            return err;
        }
        return err;
    };

    const current_version_str = try current_version.format(allocator);
    defer allocator.free(current_version_str);
    stdout.print("  Current version: {s}\n", .{current_version_str}) catch {};

    // 2. Calculate new version
    const new_version = blk: {
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
    stdout.print("  New version: {s}\n\n", .{new_version_str}) catch {};

    // 3. Safety checks
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
    else
        try getReleaseNotes(allocator, current_version_str, new_version_str);
    defer allocator.free(release_notes);

    stdout.print("\nRelease notes:\n{s}\n", .{release_notes}) catch {};

    // 5.5. Confirm release (unless using --message flag or dry-run)
    if (options.message == null and !options.@"dry-run") {
        stdout.print("\nContinue with release v{s}? [Y/n]: ", .{new_version_str}) catch {};
        const stdin = std.io.getStdIn().reader();
        var buf: [10]u8 = undefined;
        const response = (try stdin.readUntilDelimiterOrEof(&buf, '\n')) orelse "";
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
    const tag_name = try std.fmt.allocPrint(allocator, "v{s}", .{new_version_str});
    defer allocator.free(tag_name);

    stdout.print("\n→ Creating annotated tag {s}...\n", .{tag_name}) catch {};
    if (options.@"dry-run") {
        stdout.print("  (dry-run: would create tag)\n", .{}) catch {};
    } else {
        var tag_cmd = std.ArrayList([]const u8).init(allocator);
        defer tag_cmd.deinit();

        try tag_cmd.append("git");
        try tag_cmd.append("tag");
        try tag_cmd.append("-a");
        if (options.sign) try tag_cmd.append("-s");
        try tag_cmd.append(tag_name);
        try tag_cmd.append("-m");
        try tag_cmd.append(release_notes);

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
                var repo_url = std.ArrayList(u8).init(allocator);
                defer repo_url.deinit();

                if (std.mem.startsWith(u8, clean_url, "git@")) {
                    // SSH format: git@github.com:user/repo.git
                    const colon_pos = std.mem.indexOf(u8, clean_url, ":") orelse return;
                    const path = clean_url[colon_pos + 1..];
                    const path_clean = if (std.mem.endsWith(u8, path, ".git"))
                        path[0..path.len - 4]
                    else
                        path;
                    try repo_url.appendSlice("https://github.com/");
                    try repo_url.appendSlice(path_clean);
                } else if (std.mem.startsWith(u8, clean_url, "https://")) {
                    // HTTPS format: https://github.com/user/repo.git
                    const path_clean = if (std.mem.endsWith(u8, clean_url, ".git"))
                        clean_url[0..clean_url.len - 4]
                    else
                        clean_url;
                    try repo_url.appendSlice(path_clean);
                }

                stdout.print("  • View release: {s}/releases/tag/{s}\n", .{ repo_url.items, tag_name }) catch {};
            }
        } else |_| {}
    }
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
    var new_content = std.ArrayList(u8).init(allocator);
    defer new_content.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, ".version")) |_| {
            // Replace the version value
            const indent = blk: {
                var i: usize = 0;
                while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
                break :blk line[0..i];
            };
            try new_content.writer().print("{s}.version = \"{s}\",\n", .{ indent, new_version });
        } else {
            try new_content.appendSlice(line);
            try new_content.append('\n');
        }
    }

    // Write back to file
    const out_file = try std.fs.cwd().createFile(zon_path, .{});
    defer out_file.close();
    try out_file.writeAll(new_content.items);
}

fn getCurrentVersion(allocator: std.mem.Allocator) !Version {
    const result = runCommand(allocator, &.{ "git", "describe", "--tags", "--abbrev=0" }) catch |err| {
        if (err == error.CommandFailed) return error.NoTags;
        return err;
    };
    defer allocator.free(result);

    const tag = std.mem.trim(u8, result, "\n ");
    return try Version.parse(tag);
}

fn getReleaseNotes(allocator: std.mem.Allocator, current_version: []const u8, new_version: []const u8) ![]const u8 {
    // Generate commit log since last tag
    const log_cmd = try std.fmt.allocPrint(
        allocator,
        "git log v{s}..HEAD --oneline --pretty=format:\"- %s\"",
        .{current_version},
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
