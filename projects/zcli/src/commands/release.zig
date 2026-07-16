const std = @import("std");
const zcli = @import("zcli");
const scaffold = @import("scaffold");

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
        .@"dry-run" = .{ .description = "Preview changes without executing" },
        .@"skip-tests" = .{ .description = "Skip running tests before release" },
        .push = .{ .description = "Create the tag but don't push to remote" },
        .@"skip-checks" = .{ .description = "Skip safety checks (clean working tree, branch verification)" },
        .sign = .{ .description = "Sign the tag with GPG" },
        .message = .{ .description = "Release message (if not provided, editor will open)" },
        .branch = .{ .description = "Branch to release from" },
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
    /// Whether to push the commit and tag (default true; help surfaces `--no-push`)
    push: bool = true,
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

    const BumpType = enum { major, minor, patch };

    fn bump(self: Version, bump_type: BumpType) Version {
        return switch (bump_type) {
            .major => .{ .major = self.major + 1, .minor = 0, .patch = 0 },
            .minor => .{ .major = self.major, .minor = self.minor + 1, .patch = 0 },
            .patch => .{ .major = self.major, .minor = self.minor, .patch = self.patch + 1 },
        };
    }
};

// Convention: this command takes `context: anytype` (not `*Context`) so tests
// can pass a lightweight stub instead of a full app registry; commands that
// don't need that testability use `*Context` for the compile-time contract.
pub fn execute(args: Args, options: Options, context: anytype) !void {
    const allocator = context.allocator;
    var stdout = context.stdout();
    // Framework prompt instance: shares this command's stdout/stdin (Stdio-
    // injectable, so confirmations are testable) instead of a hand-rolled
    // stdin read.
    const prompts = context.prompts();

    const io = context.io;

    // "major"/"minor"/"patch" selects a bump; anything else is an explicit version.
    const bump_type = std.meta.stringToEnum(Version.BumpType, args.version);

    // 0. Validate this is a zcli-based project (not the zcli repo itself)
    try validateZcliProject(allocator, io, context);

    // 1. Parse CLI name from build.zig.zon
    try stdout.print("→ Reading build.zig.zon...\n", .{});
    const cli_name = parseCliName(allocator, io) catch |err| switch (err) {
        error.NameNotFound => return context.fail("Error: Could not find .name field in build.zig.zon\n  Expected format: .name = \"myapp\" or .name = .myapp", .{}),
        else => return err,
    };
    defer allocator.free(cli_name);
    try stdout.print("  CLI name: {s}\n", .{cli_name});

    // 2. Get current version from git tags (or create initial tag)
    try stdout.print("\n→ Detecting current version...\n", .{});

    // Track if this is an initial release
    var is_initial_release = false;

    const current_version = blk: {
        if (getCurrentVersion(allocator, io, cli_name)) |version| {
            break :blk version;
        } else |err| {
            if (err == error.NoTags) {
                // Offer to create initial tag interactively
                try stdout.print("  No tags found - this appears to be a new project.\n\n", .{});

                // Check if user provided an explicit version (not a bump type)
                const is_bump_type = bump_type != null;

                if (options.@"dry-run") {
                    try stdout.print("(dry-run: would prompt to create initial release tag)\n", .{});
                    is_initial_release = true;
                    const initial_version = if (is_bump_type)
                        Version{ .major = 0, .minor = 1, .patch = 0 }
                    else
                        Version.parse(args.version) catch return context.fail("✗ Invalid version format: {s}\n  Version must be in format: MAJOR.MINOR.PATCH (e.g., 0.1.0)", .{args.version});
                    break :blk initial_version;
                }

                const create_it = prompts.confirm(.{
                    .message = "Create initial release tag?",
                    .default = true,
                }) catch |perr| switch (perr) {
                    error.EndOfStream => return context.fail("✗ Release requires a terminal to confirm (stdin closed).", .{}),
                    else => return perr,
                };
                if (!create_it) {
                    return context.fail("\nTo create manually:\n  git tag -a {s}-v0.1.0 -m \"Initial release\"", .{cli_name});
                }

                // If user provided explicit version, use it; otherwise prompt
                const version_to_use = if (is_bump_type) blk2: {
                    const version_input = prompts.text(.{
                        .message = "  Initial version",
                        .default = "0.1.0",
                    }) catch |perr| switch (perr) {
                        error.EndOfStream => return context.fail("✗ Release requires a terminal to enter a version (stdin closed).", .{}),
                        else => return perr,
                    };
                    // Owned by the command arena; the trimmed slice escapes this
                    // block so it must not be freed here.
                    const initial_version_str = std.mem.trim(u8, version_input, " \t\r\n");
                    break :blk2 if (initial_version_str.len == 0) "0.1.0" else initial_version_str;
                } else args.version;

                const initial_version = Version.parse(version_to_use) catch {
                    return context.fail("✗ Invalid version format: {s}\n  Version must be in format: MAJOR.MINOR.PATCH (e.g., 0.1.0)", .{version_to_use});
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
            try stdout.print("  Initial version: {s}\n\n", .{current_version_str});
            break :blk current_version;
        }

        // For subsequent releases, show current and calculate new
        try stdout.print("  Current version: {s}\n", .{current_version_str});

        if (bump_type) |bt| {
            break :blk current_version.bump(bt);
        } else {
            break :blk Version.parse(args.version) catch return context.fail("✗ Invalid version format: {s}\n  Version must be in format: MAJOR.MINOR.PATCH (e.g., 0.1.0)", .{args.version});
        }
    };

    const new_version_str = try new_version.format(allocator);
    defer allocator.free(new_version_str);

    if (!is_initial_release) {
        try stdout.print("  New version: {s}\n\n", .{new_version_str});
    }

    // 4. Safety checks
    if (!options.@"skip-checks") {
        try stdout.print("→ Running safety checks...\n", .{});

        // Check working tree is clean
        const status_result = try captureOrFail(allocator, io, context, &.{ "git", "status", "--porcelain" });
        defer allocator.free(status_result);

        if (status_result.len > 0) {
            return context.fail("✗ Working tree is not clean. Commit or stash changes first.", .{});
        }
        try stdout.print("  ✓ Working tree is clean\n", .{});

        // Check current branch
        const branch_result = try captureOrFail(allocator, io, context, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });
        defer allocator.free(branch_result);

        const current_branch = std.mem.trim(u8, branch_result, "\n ");
        if (!std.mem.eql(u8, current_branch, options.branch)) {
            return context.fail("✗ Not on branch '{s}' (currently on '{s}')", .{ options.branch, current_branch });
        }
        try stdout.print("  ✓ On branch: {s}\n", .{current_branch});
    }

    // 4. Run tests
    if (!options.@"skip-tests") {
        try stdout.print("\n→ Running tests...\n", .{});
        if (options.@"dry-run") {
            try stdout.print("  (dry-run: would run 'zig build test')\n", .{});
        } else {
            const test_result = try runCommand(allocator, io, &.{ "zig", "build", "test" });
            defer test_result.deinit(allocator);
            if (!test_result.success) {
                const detail = std.mem.trim(u8, if (test_result.stderr.len > 0) test_result.stderr else test_result.stdout, " \t\r\n");
                return context.fail("✗ Tests failed:\n{s}", .{detail});
            }
            try stdout.print("  ✓ All tests passed\n", .{});
        }
    }

    // 5. Get release notes
    try stdout.print("\n→ Preparing release notes...\n", .{});
    const release_notes = if (options.message) |msg|
        try allocator.dupe(u8, msg)
    else if (options.@"dry-run")
        try allocator.dupe(u8, "(dry-run: would open editor for release notes)")
    else blk: {
        const template = if (is_initial_release)
            try initialNotesTemplate(allocator, new_version_str)
        else
            try changesNotesTemplate(allocator, io, cli_name, current_version_str, new_version_str);
        defer allocator.free(template);

        try stdout.flush(); // the editor inherits the terminal — our output must land first
        break :blk editReleaseNotes(allocator, io, context.environ, template) catch |err| switch (err) {
            error.EditorFailed => return context.fail("✗ Editor exited with non-zero status", .{}),
            else => return err,
        };
    };
    defer allocator.free(release_notes);

    try stdout.print("\nRelease notes:\n{s}\n", .{release_notes});

    // 5.5. Confirm release (unless using --message flag or dry-run)
    if (options.message == null and !options.@"dry-run") {
        const proceed = prompts.confirm(.{
            .message = try std.fmt.allocPrint(allocator, "Continue with release {s}-v{s}?", .{ cli_name, new_version_str }),
            .default = true,
        }) catch |perr| switch (perr) {
            error.EndOfStream => return context.fail("✗ Release requires a terminal to confirm (stdin closed).", .{}),
            else => return perr,
        };
        // Default to yes - only abort if the user explicitly declined.
        if (!proceed) {
            try stdout.print("Release aborted.\n", .{});
            return;
        }
    }

    // 6. Update build.zig.zon with new version
    try stdout.print("\n→ Updating build.zig.zon to v{s}...\n", .{new_version_str});
    if (options.@"dry-run") {
        try stdout.print("  (dry-run: would update build.zig.zon)\n", .{});
    } else {
        try updateBuildZonVersion(allocator, io, new_version_str);
        try stdout.print("  ✓ build.zig.zon updated\n", .{});

        // Commit the version bump. Idempotent: on a retry after a failed push
        // the bump is already written and committed, so nothing is staged —
        // treat that as success and resume instead of aborting on
        // "nothing to commit".
        try stdout.print("\n→ Committing version bump...\n", .{});
        try runOrFail(allocator, io, context, &.{ "git", "add", "build.zig.zon" });

        // `git diff --cached --quiet` exits 0 when nothing is staged.
        const staged = try runCommand(allocator, io, &.{ "git", "diff", "--cached", "--quiet" });
        defer staged.deinit(allocator);
        if (staged.success) {
            try stdout.print("  ✓ Version bump already committed (resuming)\n", .{});
        } else {
            const commit_msg = try std.fmt.allocPrint(allocator, "Bump version to {s}", .{new_version_str});
            defer allocator.free(commit_msg);
            try runOrFail(allocator, io, context, &.{ "git", "commit", "-m", commit_msg });
            try stdout.print("  ✓ Changes committed\n", .{});
        }
    }

    // 7. Create annotated tag
    const tag_name = try std.fmt.allocPrint(allocator, "{s}-v{s}", .{ cli_name, new_version_str });
    defer allocator.free(tag_name);

    // The tag is the last local step before the push, so a partial failure
    // never leaves a tag pointing at a commit that was not published.
    try stdout.print("\n→ Creating annotated tag {s}...\n", .{tag_name});
    if (options.@"dry-run") {
        try stdout.print("  (dry-run: would create tag)\n", .{});
    } else {
        // On a retry, a local tag from the prior failed attempt may already
        // exist (git would refuse to recreate it). Remove it so the tag is
        // recreated on the current commit with the current release notes.
        if (try localTagExists(allocator, io, tag_name)) {
            try stdout.print("  Local tag already exists — recreating\n", .{});
            try runOrFail(allocator, io, context, &.{ "git", "tag", "-d", tag_name });
        }

        var tag_cmd = std.ArrayList([]const u8).empty;
        defer tag_cmd.deinit(allocator);

        try tag_cmd.append(allocator, "git");
        try tag_cmd.append(allocator, "tag");
        try tag_cmd.append(allocator, "-a");
        if (options.sign) try tag_cmd.append(allocator, "-s");
        try tag_cmd.append(allocator, tag_name);
        try tag_cmd.append(allocator, "-m");
        try tag_cmd.append(allocator, release_notes);

        try runOrFail(allocator, io, context, tag_cmd.items);
        try stdout.print("  ✓ Tag created\n", .{});
    }

    // 8. Push commit and tag together. `--atomic` makes the remote accept both
    // refs or neither, so a failed push can never leave the branch pushed
    // without its tag (or vice-versa) — the state that previously stranded the
    // release half-done and blocked a clean re-run.
    if (options.push) {
        try stdout.print("\n→ Pushing to origin...\n", .{});
        if (options.@"dry-run") {
            try stdout.print("  (dry-run: would push commit and tag atomically)\n", .{});
        } else {
            try runOrFail(allocator, io, context, &.{ "git", "push", "--atomic", "origin", options.branch, tag_name });
            try stdout.print("  ✓ Commit and tag pushed successfully\n", .{});
        }
    }

    // 9. Success message
    try stdout.print("\n", .{});
    if (options.@"dry-run") {
        try stdout.print("✓ Dry-run complete! No changes were made.\n", .{});
    } else {
        try stdout.print("✓ Release {s} created! 🎉\n", .{tag_name});
        try stdout.print("\nNext steps:\n", .{});
        try stdout.print("  • GitHub Actions will build release binaries\n", .{});

        // Try to get repo URL
        if (runCommand(allocator, io, &.{ "git", "config", "--get", "remote.origin.url" })) |url_result| {
            defer url_result.deinit(allocator);
            const clean_url = std.mem.trim(u8, url_result.stdout, "\n ");
            // Convert git@github.com:user/repo.git to https://github.com/user/repo
            if (url_result.success and std.mem.indexOf(u8, clean_url, "github.com") != null) {
                var repo_url = std.ArrayList(u8).empty;
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

                try stdout.print("  • View release: {s}/releases/tag/{s}\n", .{ repo_url.items, tag_name });
            }
        } else |_| {}
    }
}

/// Validate that this is a zcli-based CLI project (not the zcli framework itself)
/// Checks that build.zig.zon has zcli as a dependency
fn validateZcliProject(allocator: std.mem.Allocator, io: std.Io, context: anytype) !void {
    const zon_path = "build.zig.zon";

    const content = std.Io.Dir.cwd().readFileAlloc(io, zon_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return context.fail("✗ Error: Could not open {s}\n  Make sure you're running this command from a project root directory.", .{zon_path}),
    };
    defer allocator.free(content);

    // Check if this has zcli as a dependency (indicating it's a zcli-based project)
    // Look for ".zcli = .{" pattern within the dependencies block
    var has_zcli_dependency = false;

    // Find the dependencies section
    if (std.mem.indexOf(u8, content, ".dependencies")) |deps_start| {
        // Find the closing brace for dependencies (rough heuristic)
        const after_deps = content[deps_start..];

        // Look for patterns like:
        //   .zcli = .{ .path = ... }
        //   .zcli = .{ .url = ... }
        // within the dependencies section
        if (std.mem.indexOf(u8, after_deps, ".zcli = .{")) |_| {
            has_zcli_dependency = true;
        }
    }

    if (!has_zcli_dependency) {
        return context.fail(
            \\✗ Error: This doesn't appear to be a zcli-based CLI project.
            \\
            \\  The 'release' command is for releasing zcli-based CLI applications.
            \\  It requires zcli as a dependency in build.zig.zon.
            \\
            \\  If you're working on the zcli framework itself, use the workflow:
            \\    cd projects/zcli
            \\    zcli release <version>
        , .{});
    }
}

/// Parse CLI name from build.zig.zon
fn parseCliName(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, "build.zig.zon", allocator, .limited(1024 * 1024));
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

    // The message is rendered by the caller via context.fail (see execute).
    return error.NameNotFound;
}

/// Update the version in build.zig.zon
fn updateBuildZonVersion(allocator: std.mem.Allocator, io: std.Io, new_version: []const u8) !void {
    const zon_path = "build.zig.zon";

    const content = try std.Io.Dir.cwd().readFileAlloc(io, zon_path, allocator, .limited(1024 * 1024));
    defer allocator.free(content);

    const new_content = try rewriteZonVersion(allocator, content, new_version);
    defer allocator.free(new_content);

    // Write back atomically (temp + rename) so a crash/interrupt mid-write can
    // never leave build.zig.zon empty or truncated — the original stays intact
    // until the rename swaps in the fully-written replacement.
    try scaffold.fs.writeFileAtomic(std.Io.Dir.cwd(), io, allocator, zon_path, new_content);
}

/// Return a copy of `content` with the `.version` field rewritten to
/// `new_version`. The match is anchored to a line whose first non-whitespace
/// token is `.version`, so `.minimum_zig_version` (or any other field that
/// merely contains the substring) is left untouched. Pure — no I/O — so the
/// rewrite is unit-testable.
fn rewriteZonVersion(allocator: std.mem.Allocator, content: []const u8, new_version: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        // Re-insert the '\n' between lines (not after the last) so the file's
        // exact structure — including a trailing newline or lack thereof — is
        // preserved rather than gaining a spurious blank line.
        if (!first) try out.append(allocator, '\n');
        first = false;

        const indent = leadingWhitespace(line);
        if (std.mem.startsWith(u8, line[indent.len..], ".version")) {
            const s = try std.fmt.allocPrint(allocator, "{s}.version = \"{s}\",", .{ indent, new_version });
            defer allocator.free(s);
            try out.appendSlice(allocator, s);
        } else {
            try out.appendSlice(allocator, line);
        }
    }

    return out.toOwnedSlice(allocator);
}

/// The leading run of spaces/tabs on `line` (its indentation).
fn leadingWhitespace(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line[0..i];
}

/// Whether a local git tag named `tag_name` currently exists. Used to detect a
/// tag left behind by a prior release attempt so a retry can clean it up.
fn localTagExists(allocator: std.mem.Allocator, io: std.Io, tag_name: []const u8) !bool {
    const ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{tag_name});
    defer allocator.free(ref);

    const result = try runCommand(allocator, io, &.{ "git", "rev-parse", "-q", "--verify", ref });
    defer result.deinit(allocator);
    return result.success;
}

fn getCurrentVersion(allocator: std.mem.Allocator, io: std.Io, cli_name: []const u8) !Version {
    // Look for tags matching {cli_name}-v*
    const tag_pattern = try std.fmt.allocPrint(allocator, "{s}-v*", .{cli_name});
    defer allocator.free(tag_pattern);

    const result = try runCommand(allocator, io, &.{ "git", "describe", "--tags", "--abbrev=0", "--match", tag_pattern });
    defer result.deinit(allocator);
    if (!result.success) return error.NoTags;

    const tag = std.mem.trim(u8, result.stdout, "\n ");

    // Strip the "{cli_name}-" prefix to get just the version
    const prefix = try std.fmt.allocPrint(allocator, "{s}-", .{cli_name});
    defer allocator.free(prefix);

    const version_str = if (std.mem.startsWith(u8, tag, prefix))
        tag[prefix.len..]
    else
        tag;

    return try Version.parse(version_str);
}

fn initialNotesTemplate(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(
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
}

fn changesNotesTemplate(allocator: std.mem.Allocator, io: std.Io, cli_name: []const u8, current_version: []const u8, new_version: []const u8) ![]u8 {
    // Generate commit log since last tag. Plain argv like every other git
    // call in this file — no shell, so a tag name is never interpreted (and
    // the pretty format needs no quoting gymnastics).
    const tag_range = try std.fmt.allocPrint(allocator, "{s}-v{s}..HEAD", .{ cli_name, current_version });
    defer allocator.free(tag_range);

    const commits: []const u8 = blk: {
        const result = runCommand(allocator, io, &.{ "git", "log", tag_range, "--oneline", "--pretty=format:- %s" }) catch
            break :blk try allocator.dupe(u8, "");
        if (!result.success) {
            result.deinit(allocator);
            break :blk try allocator.dupe(u8, "");
        }
        allocator.free(result.stderr);
        break :blk result.stdout;
    };
    defer allocator.free(commits);

    return std.fmt.allocPrint(
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
}

const notes_file_name = "RELEASE_NOTES.txt";
const scratch_dir_permissions: std.Io.Dir.Permissions = @enumFromInt(0o700);
const scratch_name_len = ".zcli-release-".len + 16;

fn randomScratchName(io: std.Io, buf: *[scratch_name_len]u8) []const u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const hex = std.fmt.bytesToHex(&random_bytes, .lower);
    return std.fmt.bufPrint(buf, ".zcli-release-{s}", .{hex}) catch unreachable;
}

/// Write `template` to a notes file, open $VISUAL/$EDITOR on it, and return
/// the edited content. The file feeds the (possibly signed) tag message, so
/// it lives in a randomly-named 0700 scratch directory in the project root —
/// never a predictable shared path like /tmp/zcli, which another local user
/// could pre-plant or tamper with between write and read.
fn editReleaseNotes(allocator: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map, template: []const u8) ![]u8 {
    const cwd_dir = std.Io.Dir.cwd();

    var scratch_name_buf: [scratch_name_len]u8 = undefined;
    const scratch_name = randomScratchName(io, &scratch_name_buf);
    try cwd_dir.createDir(io, scratch_name, scratch_dir_permissions);
    defer cwd_dir.deleteTree(io, scratch_name) catch {};
    var dir = try cwd_dir.openDir(io, scratch_name, .{});
    defer dir.close(io);

    {
        const file = try dir.createFile(io, notes_file_name, .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, template);
    }

    const editor = if (environ) |env| env.get("VISUAL") orelse env.get("EDITOR") orelse "vim" else "vim";
    var editor_child = try std.process.spawn(io, .{
        .argv = &.{ editor, notes_file_name },
        .cwd = .{ .dir = dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const editor_term = try editor_child.wait(io);
    if (editor_term != .exited or editor_term.exited != 0) return error.EditorFailed;

    return dir.readFileAlloc(io, notes_file_name, allocator, .limited(1024 * 1024));
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    success: bool,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const max_command_output = 1024 * 1024;
const stderr_capture_cap = 64 * 1024;

/// Read the child's stderr to EOF into `dest`, discarding overflow. Runs
/// concurrently with the stdout drain, so it must not allocate: the
/// per-command arena is not threadsafe. Truncation is fine — stderr is only
/// used for diagnostics.
fn drainStderr(io: std.Io, file: std.Io.File, dest: []u8) usize {
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const n = reader.interface.readSliceShort(dest) catch return 0;
    _ = reader.interface.discardRemaining() catch {};
    return n;
}

/// Spawn `argv` (no shell) and capture stdout and stderr. Errors only for
/// spawn/read failures; a non-zero exit is reported via `success` so callers
/// still get the child's stderr for diagnostics.
fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !RunResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Both pipes must drain simultaneously: a child that fills one while we
    // block reading the other to EOF deadlocks (`zig build test` easily
    // exceeds the pipe buffer on stderr). On a single-threaded blocking Io,
    // fall back to sequential drains — the pre-existing behavior.
    var stderr_capture: [stderr_capture_cap]u8 = undefined;
    var stderr_future: ?std.Io.Future(usize) =
        io.concurrent(drainStderr, .{ io, child.stderr.?, &stderr_capture }) catch null;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = stdout_reader.interface.allocRemaining(allocator, .limited(max_command_output)) catch |err| {
        // Keep both pipes draining so the child can exit and the concurrent
        // stderr drain reaches EOF, then reap before propagating.
        _ = stdout_reader.interface.discardRemaining() catch {};
        if (stderr_future) |*f| _ = f.await(io);
        child.kill(io);
        return err;
    };
    errdefer allocator.free(stdout_data);

    const stderr_len = if (stderr_future) |*f|
        f.await(io)
    else
        drainStderr(io, child.stderr.?, &stderr_capture);

    const stderr_data = try allocator.dupe(u8, stderr_capture[0..stderr_len]);
    errdefer allocator.free(stderr_data);

    const term = try child.wait(io);
    return .{
        .stdout = stdout_data,
        .stderr = stderr_data,
        .success = term == .exited and term.exited == 0,
    };
}

/// Run a command that must succeed, returning its stdout (caller frees). On
/// non-zero exit, renders the child's stderr through `context.fail`.
fn captureOrFail(allocator: std.mem.Allocator, io: std.Io, context: anytype, argv: []const []const u8) ![]u8 {
    const result = try runCommand(allocator, io, argv);
    if (result.success) {
        allocator.free(result.stderr);
        return result.stdout;
    }
    defer result.deinit(allocator);

    const command_line = try std.mem.join(allocator, " ", argv);
    defer allocator.free(command_line);
    const detail = std.mem.trim(u8, if (result.stderr.len > 0) result.stderr else result.stdout, " \t\r\n");
    return context.fail("✗ `{s}` failed:\n{s}", .{ command_line, detail });
}

/// `captureOrFail` for commands whose stdout is not needed.
fn runOrFail(allocator: std.mem.Allocator, io: std.Io, context: anytype, argv: []const []const u8) !void {
    allocator.free(try captureOrFail(allocator, io, context, argv));
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
    const v2 = v1.bump(.major);
    try testing.expectEqual(@as(u32, 2), v2.major);
    try testing.expectEqual(@as(u32, 0), v2.minor);
    try testing.expectEqual(@as(u32, 0), v2.patch);

    const v3 = Version{ .major = 0, .minor = 5, .patch = 10 };
    const v4 = v3.bump(.major);
    try testing.expectEqual(@as(u32, 1), v4.major);
    try testing.expectEqual(@as(u32, 0), v4.minor);
    try testing.expectEqual(@as(u32, 0), v4.patch);
}

test "Version.bump - minor" {
    const v1 = Version{ .major = 1, .minor = 2, .patch = 3 };
    const v2 = v1.bump(.minor);
    try testing.expectEqual(@as(u32, 1), v2.major);
    try testing.expectEqual(@as(u32, 3), v2.minor);
    try testing.expectEqual(@as(u32, 0), v2.patch);

    const v3 = Version{ .major = 0, .minor = 0, .patch = 10 };
    const v4 = v3.bump(.minor);
    try testing.expectEqual(@as(u32, 0), v4.major);
    try testing.expectEqual(@as(u32, 1), v4.minor);
    try testing.expectEqual(@as(u32, 0), v4.patch);
}

test "Version.bump - patch" {
    const v1 = Version{ .major = 1, .minor = 2, .patch = 3 };
    const v2 = v1.bump(.patch);
    try testing.expectEqual(@as(u32, 1), v2.major);
    try testing.expectEqual(@as(u32, 2), v2.minor);
    try testing.expectEqual(@as(u32, 4), v2.patch);

    const v3 = Version{ .major = 0, .minor = 0, .patch = 0 };
    const v4 = v3.bump(.patch);
    try testing.expectEqual(@as(u32, 0), v4.major);
    try testing.expectEqual(@as(u32, 0), v4.minor);
    try testing.expectEqual(@as(u32, 1), v4.patch);
}

test "parseCliName - quoted string format" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    // Create a temporary build.zig.zon file
    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const zon_content =
        \\.{
        \\    .name = "myapp",
        \\    .version = "1.0.0",
        \\}
    ;

    var file = try temp_dir.dir.createFile(io, "build.zig.zon", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, zon_content);

    // Change to temp directory
    var original_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_dir.close(io);
    try std.process.setCurrentDir(io, temp_dir.dir);
    defer std.process.setCurrentDir(io, original_dir) catch {};

    const cli_name = try parseCliName(allocator, io);
    defer allocator.free(cli_name);

    try testing.expectEqualStrings("myapp", cli_name);
}

test "parseCliName - identifier format" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const zon_content =
        \\.{
        \\    .name = .zcli,
        \\    .version = "1.0.0",
        \\}
    ;

    var file = try temp_dir.dir.createFile(io, "build.zig.zon", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, zon_content);

    var original_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_dir.close(io);
    try std.process.setCurrentDir(io, temp_dir.dir);
    defer std.process.setCurrentDir(io, original_dir) catch {};

    const cli_name = try parseCliName(allocator, io);
    defer allocator.free(cli_name);

    try testing.expectEqualStrings("zcli", cli_name);
}

test "parseCliName - identifier with trailing comma" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const zon_content =
        \\.{
        \\    .name = .myapp,
        \\    .version = "1.0.0",
        \\}
    ;

    var file = try temp_dir.dir.createFile(io, "build.zig.zon", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, zon_content);

    var original_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_dir.close(io);
    try std.process.setCurrentDir(io, temp_dir.dir);
    defer std.process.setCurrentDir(io, original_dir) catch {};

    const cli_name = try parseCliName(allocator, io);
    defer allocator.free(cli_name);

    try testing.expectEqualStrings("myapp", cli_name);
}

test "parseCliName - missing name field" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const zon_content =
        \\.{
        \\    .version = "1.0.0",
        \\}
    ;

    var file = try temp_dir.dir.createFile(io, "build.zig.zon", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, zon_content);

    var original_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_dir.close(io);
    try std.process.setCurrentDir(io, temp_dir.dir);
    defer std.process.setCurrentDir(io, original_dir) catch {};

    try testing.expectError(error.NameNotFound, parseCliName(allocator, io));
}

test "bump type detection" {
    // Bump keywords map to BumpType; anything else is an explicit version.
    try testing.expectEqual(Version.BumpType.major, std.meta.stringToEnum(Version.BumpType, "major").?);
    try testing.expectEqual(Version.BumpType.minor, std.meta.stringToEnum(Version.BumpType, "minor").?);
    try testing.expectEqual(Version.BumpType.patch, std.meta.stringToEnum(Version.BumpType, "patch").?);
    try testing.expect(std.meta.stringToEnum(Version.BumpType, "1.2.3") == null);
    try testing.expect(std.meta.stringToEnum(Version.BumpType, "Major") == null);
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
    const v_major = v.bump(.major);
    try testing.expectEqual(@as(u32, 6), v_major.major);
    try testing.expectEqual(@as(u32, 0), v_major.minor);
    try testing.expectEqual(@as(u32, 0), v_major.patch);

    // Minor bump resets patch
    const v_minor = v.bump(.minor);
    try testing.expectEqual(@as(u32, 5), v_minor.major);
    try testing.expectEqual(@as(u32, 11), v_minor.minor);
    try testing.expectEqual(@as(u32, 0), v_minor.patch);

    // Patch bump doesn't reset anything
    const v_patch = v.bump(.patch);
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
    const io = std.testing.io;

    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    // Test with extra whitespace
    const zon_content =
        \\.{
        \\    .name   =   "myapp"  ,
        \\    .version = "1.0.0",
        \\}
    ;

    var file = try temp_dir.dir.createFile(io, "build.zig.zon", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, zon_content);

    var original_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_dir.close(io);
    try std.process.setCurrentDir(io, temp_dir.dir);
    defer std.process.setCurrentDir(io, original_dir) catch {};

    const cli_name = try parseCliName(allocator, io);
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

test "randomScratchName - hidden, fixed-length, unpredictable" {
    var buf_a: [scratch_name_len]u8 = undefined;
    var buf_b: [scratch_name_len]u8 = undefined;
    const a = randomScratchName(std.testing.io, &buf_a);
    const b = randomScratchName(std.testing.io, &buf_b);

    try testing.expectEqual(scratch_name_len, a.len);
    try testing.expect(std.mem.startsWith(u8, a, ".zcli-release-"));
    try testing.expect(!std.mem.eql(u8, a, b));
}

/// Run a git command in a test repo and assert it succeeded.
fn expectGitOk(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const r = try runCommand(allocator, io, argv);
    defer r.deinit(allocator);
    try testing.expect(r.success);
}

test "release retry idempotency: tag detection + empty-commit resume" {
    // Reproduces the half-released state from a prior failed push and asserts
    // the recovery mechanics: (1) a leftover local tag is detectable, and
    // (2) re-staging an already-committed version bump leaves nothing staged,
    // so the retry resumes instead of failing on "nothing to commit".
    const allocator = testing.allocator;
    const io = std.testing.io;

    var temp_dir = testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var original_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_dir.close(io);
    try std.process.setCurrentDir(io, temp_dir.dir);
    defer std.process.setCurrentDir(io, original_dir) catch {};

    // Fresh, isolated repo with a committer identity.
    try expectGitOk(allocator, io, &.{ "git", "init", "-q" });
    try expectGitOk(allocator, io, &.{ "git", "config", "user.email", "t@example.com" });
    try expectGitOk(allocator, io, &.{ "git", "config", "user.name", "Test" });

    // Simulate the version bump already written and committed.
    {
        var f = try temp_dir.dir.createFile(io, "build.zig.zon", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, ".{ .version = \"1.0.0\" }\n");
    }
    try expectGitOk(allocator, io, &.{ "git", "add", "build.zig.zon" });
    try expectGitOk(allocator, io, &.{ "git", "commit", "-q", "-m", "Bump version to 1.0.0" });

    const tag = "app-v1.0.0";

    // Before the prior attempt created a tag, none exists.
    try testing.expect(!try localTagExists(allocator, io, tag));

    // Prior attempt created the tag but failed to push it.
    try expectGitOk(allocator, io, &.{ "git", "tag", "-a", tag, "-m", "notes" });
    try testing.expect(try localTagExists(allocator, io, tag));

    // Retry: staging the already-committed bump stages nothing, so
    // `git diff --cached --quiet` succeeds (exit 0) and the commit is skipped.
    try expectGitOk(allocator, io, &.{ "git", "add", "build.zig.zon" });
    const staged = try runCommand(allocator, io, &.{ "git", "diff", "--cached", "--quiet" });
    defer staged.deinit(allocator);
    try testing.expect(staged.success);

    // Retry: the leftover tag is cleaned so it can be recreated without error.
    try expectGitOk(allocator, io, &.{ "git", "tag", "-d", tag });
    try testing.expect(!try localTagExists(allocator, io, tag));
}

test "runCommand - captures stdout and surfaces failure stderr" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    const ok = try runCommand(allocator, io, &.{ "git", "--version" });
    defer ok.deinit(allocator);
    try testing.expect(ok.success);
    try testing.expect(std.mem.startsWith(u8, ok.stdout, "git version"));

    const bad = try runCommand(allocator, io, &.{ "git", "cat-file", "-p", "not-a-real-object" });
    defer bad.deinit(allocator);
    try testing.expect(!bad.success);
    try testing.expect(bad.stderr.len > 0);
}

test "rewriteZonVersion - rewrites .version and leaves .minimum_zig_version alone" {
    const allocator = testing.allocator;

    const manifest =
        \\.{
        \\    .name = .myapp,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x1234,
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{},
        \\}
        \\
    ;
    const expected =
        \\.{
        \\    .name = .myapp,
        \\    .version = "2.0.0",
        \\    .fingerprint = 0x1234,
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{},
        \\}
        \\
    ;

    const got = try rewriteZonVersion(allocator, manifest, "2.0.0");
    defer allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}
