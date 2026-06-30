//! End-to-end tests for the zcli meta-tool.
//!
//! These run the *built* `zcli` binary as a subprocess against throwaway temp
//! directories and assert on the files it generates and (for the slow tier) that
//! the generated project actually builds and runs.
//!
//! Run with `zig build e2e` (NOT part of `zig build test`, since the build-and-run
//! tier compiles zcli from source and is slow). See `.context/e2e-test-plan.md`.
//!
//! Build-time injected paths (see build.zig):
//!   - build_options.zcli_exe     absolute path to the built `zcli` binary
//!   - build_options.repo_root    absolute path to the zcli package (local dep override)
//!   - build_options.fixtures_dir absolute path to test/fixtures

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const io = testing.io;

const zcli_exe = build_options.zcli_exe;
const repo_root = build_options.repo_root;
const fixtures_dir = build_options.fixtures_dir;

// ============================================================================
// Harness
// ============================================================================

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: *RunResult) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

/// Run `argv` with `cwd` as the working directory, capturing stdout/stderr.
/// Mirrors packages/testing's runSubprocess but adds the cwd we need to drive
/// the generator inside temp projects.
fn run(cwd: std.Io.Dir, argv: []const []const u8) !RunResult {
    const a = testing.allocator;

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Drain pipes before waiting to avoid deadlock on large output.
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_reader = child.stdout.?.reader(io, &out_buf);
    var err_reader = child.stderr.?.reader(io, &err_buf);
    const stdout = try out_reader.interface.allocRemaining(a, .limited(10 * 1024 * 1024));
    errdefer a.free(stdout);
    const stderr = try err_reader.interface.allocRemaining(a, .limited(10 * 1024 * 1024));
    errdefer a.free(stderr);

    const term = try child.wait(io);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = switch (term) {
            .exited => |code| @intCast(code),
            else => 1,
        },
    };
}

fn fileExists(dir: std.Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

fn readFile(dir: std.Io.Dir, a: std.mem.Allocator, path: []const u8) ![]u8 {
    return dir.readFileAlloc(io, path, a, .limited(1 << 20));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print(
            "\nexpected to find:\n  \"{s}\"\nin:\n----\n{s}\n----\n",
            .{ needle, haystack },
        );
        return error.SubstringNotFound;
    }
}

/// Assert success, printing captured output on failure to make CI logs useful.
fn expectOk(r: RunResult) !void {
    if (r.exit_code != 0) {
        std.debug.print(
            "\ncommand exited {d}\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ r.exit_code, r.stdout, r.stderr },
        );
        return error.CommandFailed;
    }
}

fn makeProjectDirs(dir: std.Io.Dir) !void {
    try dir.createDir(io, "src", .default_dir);
    try dir.createDir(io, "src/commands", .default_dir);
}

// ============================================================================
// Layer 0 — file generation
// ============================================================================

test "init scaffolds a project with the expected files and wiring" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try run(tmp.dir, &.{ zcli_exe, "init", "myapp" });
    defer r.deinit();
    try expectOk(r);

    var proj = try tmp.dir.openDir(io, "myapp", .{});
    defer proj.close(io);

    try testing.expect(fileExists(proj, "build.zig"));
    try testing.expect(fileExists(proj, "build.zig.zon"));
    try testing.expect(fileExists(proj, "src/main.zig"));
    try testing.expect(fileExists(proj, "src/commands/hello.zig"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zon = try readFile(proj, a, "build.zig.zon");
    try expectContains(zon, ".name = .myapp");
    try expectContains(zon, ".zcli = .{");
    try expectContains(zon, "github.com/ryanhair/zcli");

    const build_zig = try readFile(proj, a, "build.zig");
    try expectContains(build_zig, "zcli.generate(");
    try expectContains(build_zig, "zcli.builtin(.help");
    try expectContains(build_zig, "zcli.builtin(.version");
    try expectContains(build_zig, "zcli.builtin(.not_found");
    try expectContains(build_zig, "zcli.builtin(.completions");

    const hello = try readFile(proj, a, "src/commands/hello.zig");
    try expectContains(hello, "pub fn execute(");
}

test "init . scaffolds into the current directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try run(tmp.dir, &.{ zcli_exe, "init", "." });
    defer r.deinit();
    try expectOk(r);

    try testing.expect(fileExists(tmp.dir, "build.zig"));
    try testing.expect(fileExists(tmp.dir, "src/commands/hello.zig"));
}

test "add command creates stubs at the right paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProjectDirs(tmp.dir);

    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "command", "deploy" });
        defer r.deinit();
        try expectOk(r);
    }
    try testing.expect(fileExists(tmp.dir, "src/commands/deploy.zig"));

    // Nested path creates intermediate directories.
    {
        var r = try run(tmp.dir, &.{ zcli_exe, "add", "command", "users/create", "--description", "Create a user" });
        defer r.deinit();
        try expectOk(r);
    }
    try testing.expect(fileExists(tmp.dir, "src/commands/users/create.zig"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const created = try readFile(tmp.dir, a, "src/commands/users/create.zig");
    try expectContains(created, ".description = \"Create a user\"");
    try expectContains(created, "pub fn execute(");
}

test "add command outside a project fails clearly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var r = try run(tmp.dir, &.{ zcli_exe, "add", "command", "deploy" });
    defer r.deinit();
    try testing.expect(r.exit_code != 0);
    try expectContains(r.stderr, "Not in a zcli project");
}

test "gh add workflow release writes the workflow file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try makeProjectDirs(tmp.dir); // command requires a zcli project

    var r = try run(tmp.dir, &.{ zcli_exe, "gh", "add", "workflow", "release" });
    defer r.deinit();
    try expectOk(r);

    try testing.expect(fileExists(tmp.dir, ".github/workflows/release.yml"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const yml = try readFile(tmp.dir, a, ".github/workflows/release.yml");
    try expectContains(yml, "x86_64-linux");
    try expectContains(yml, "aarch64-macos");
}

// ============================================================================
// Layer 1 — read-only commands against a checked-in fixture
// ============================================================================

fn openSampleFixture() !std.Io.Dir {
    var fx = try std.Io.Dir.cwd().openDir(io, fixtures_dir, .{});
    defer fx.close(io);
    return fx.openDir(io, "sample", .{});
}

test "tree lists the discovered commands" {
    var sample = try openSampleFixture();
    defer sample.close(io);

    var r = try run(sample, &.{ zcli_exe, "tree" });
    defer r.deinit();
    try expectOk(r);

    try expectContains(r.stdout, "hello");
    try expectContains(r.stdout, "users");
    try expectContains(r.stdout, "create");
}

test "tree --show-options surfaces args and options" {
    var sample = try openSampleFixture();
    defer sample.close(io);

    var r = try run(sample, &.{ zcli_exe, "tree", "--show-options" });
    defer r.deinit();
    try expectOk(r);

    try expectContains(r.stdout, "name"); // hello's positional arg
    try expectContains(r.stdout, "loud"); // hello's option
}

// ============================================================================
// release — dry run must not mutate git
// ============================================================================

const release_zon =
    \\.{
    \\    .name = .myapp,
    \\    .version = "0.1.0",
    \\    .fingerprint = 0x927117ca2ae2cf80,
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{
    \\        .zcli = .{ .path = "/nonexistent" },
    \\    },
    \\    .paths = .{ "build.zig", "build.zig.zon", "src" },
    \\}
    \\
;

test "release --dry-run previews without creating a tag" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = release_zon });

    // A git repo with no tags drives the initial-release path.
    {
        var r = try run(tmp.dir, &.{ "git", "init" });
        defer r.deinit();
        try expectOk(r);
    }

    var r = try run(tmp.dir, &.{
        zcli_exe,        "release", "patch",
        "--dry-run",     "--skip-checks", "--skip-tests",
        "--message",     "test notes",
    });
    defer r.deinit();
    try expectOk(r);
    try expectContains(r.stdout, "would create tag");

    // The dry run must not have created any tag.
    var tags = try run(tmp.dir, &.{ "git", "tag", "-l" });
    defer tags.deinit();
    try testing.expectEqualStrings("", std.mem.trim(u8, tags.stdout, " \t\r\n"));
}

// ============================================================================
// Layer 2 — scaffolded project builds and runs (slow)
// ============================================================================

/// Rewrite the generated zon's dependency block to point zcli at the local
/// working tree, preserving everything else `init` wrote. Zig requires path
/// dependencies to be relative to the package root, so we compute the relative
/// path from `proj_abs` to the repo root.
fn pointDependencyAtLocalTree(proj: std.Io.Dir, proj_abs: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // from/to are absolute, so cwd/environ are unused.
    const rel = try std.fs.path.relative(a, "", null, proj_abs, repo_root);

    const orig = try readFile(proj, a, "build.zig.zon");
    const dep_start = std.mem.indexOf(u8, orig, ".dependencies") orelse return error.NoDependenciesBlock;
    const paths_start = std.mem.indexOf(u8, orig, ".paths") orelse return error.NoPathsBlock;

    const rewritten = try std.fmt.allocPrint(
        a,
        "{s}.dependencies = .{{\n        .zcli = .{{ .path = \"{s}\" }},\n    }},\n    {s}",
        .{ orig[0..dep_start], rel, orig[paths_start..] },
    );
    try proj.writeFile(io, .{ .sub_path = "build.zig.zon", .data = rewritten });
}

/// Absolute path of a sub-directory created in this test run's temp dir.
/// testing.tmpDir places dirs at `<cwd>/.zig-cache/tmp/<sub_path>`.
fn tmpSubdirAbs(a: std.mem.Allocator, tmp: testing.TmpDir, sub: []const u8) ![]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.join(a, &.{ cwd_buf[0..cwd_len], ".zig-cache", "tmp", tmp.sub_path[0..], sub });
}

test "scaffolded project builds, runs, and round-trips add command" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var r = try run(tmp.dir, &.{ zcli_exe, "init", "demo" });
        defer r.deinit();
        try expectOk(r);
    }

    var proj = try tmp.dir.openDir(io, "demo", .{});
    defer proj.close(io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const proj_abs = try tmpSubdirAbs(arena.allocator(), tmp, "demo");
    try pointDependencyAtLocalTree(proj, proj_abs);

    // Build the generated project against the local zcli.
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    try testing.expect(fileExists(proj, "zig-out/bin/demo"));

    // The example command runs as generated.
    {
        var r = try run(proj, &.{ "./zig-out/bin/demo", "hello", "World" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "Hello, World!");
    }

    // Help lists the discovered command (the help plugin writes to stderr).
    {
        var r = try run(proj, &.{ "./zig-out/bin/demo", "--help" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stderr, "hello");
    }

    // Round-trip: add a command, rebuild, and run it.
    {
        var r = try run(proj, &.{ zcli_exe, "add", "command", "ping" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ "zig", "build" });
        defer r.deinit();
        try expectOk(r);
    }
    {
        var r = try run(proj, &.{ "./zig-out/bin/demo", "ping" });
        defer r.deinit();
        try expectOk(r);
        try expectContains(r.stdout, "TODO: Implement this command");
    }
}
